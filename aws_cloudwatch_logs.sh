#!/bin/zsh
# E-Commerce Cloud Ingest - Multi-Service & Scalable Volume Version
SCRIPT_DIR="${0:A:h}"
[[ -f "$SCRIPT_DIR/term_theme.sh" ]] && source "$SCRIPT_DIR/term_theme.sh"
if [[ -f "$SCRIPT_DIR/elastic.env" ]]; then
  source "$SCRIPT_DIR/elastic.env"
else
  echo "${T_RED}Missing elastic.env. Copy elastic.env.template to elastic.env and set ELASTIC_URL and API_KEY.${T_RESET}" >&2
  exit 1
fi
[[ -z "$ELASTIC_URL" || -z "$API_KEY" ]] && { echo "${T_RED}ELASTIC_URL and API_KEY must be set in elastic.env.${T_RESET}" >&2; exit 1; }

# Default Values
MODE="normal"
STATE="HEALTHY"
LOGS_PER_REQUEST=100
PREFERRED_SCHEMA=""

# Parse command line flags
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --mode) MODE="$2"; shift ;;
        --logs-per-request) LOGS_PER_REQUEST="$2"; shift ;;
        --preferred-schema) PREFERRED_SCHEMA="$2"; shift ;;
        *) echo "${T_RED}Unknown parameter: $1${T_RESET}" >&2; exit 1 ;;
    esac
    shift
done

if [[ -z "$PREFERRED_SCHEMA" ]]; then
  BULK_URL="$ELASTIC_URL/logs/_bulk"
  term_logs_deprecation_info
elif [[ "$PREFERRED_SCHEMA" == "otel" || "$PREFERRED_SCHEMA" == "ecs" ]]; then
  BULK_URL="$ELASTIC_URL/logs.$PREFERRED_SCHEMA/_bulk"
  term_wired_stream_info "$PREFERRED_SCHEMA" "$BULK_URL"
else
  echo "${T_RED}Unknown --preferred-schema:${T_RESET} ${T_YELLOW}$PREFERRED_SCHEMA${T_RESET} ${T_DIM}(use otel or ecs, or omit for POST /logs/_bulk).${T_RESET}" >&2
  exit 1
fi

[[ "$MODE" == "failure" ]] && STATE="FAILING"

GROUPS=(
  "/aws/waf/edge-firewall"
  "/aws/cloudfront/static-assets"
  "/aws/apigateway/public-api"
  "/aws/eks/checkout-microservice"
  "/aws/lambda/payment-gateway"
  "/aws/sqs/order-queue"
  "/aws/dynamodb/session-store"
  "/aws/vpc/flow-logs"
)

typeset -A SAMPLES
ENDPOINTS=("/v1/checkout" "/v1/payment" "/v1/auth/login" "/v1/inventory/search" "/v1/user/profile")

while true; do
  PAYLOAD=""
  TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  
  # Generate a batch of requests based on the logs-per-request argument
  for ((i=1; i<=$LOGS_PER_REQUEST; i++)); do
    # Pick a random log group and endpoint for this specific log entry
    LG=$GROUPS[$((RANDOM % ${#GROUPS[@]} + 1))]
    EP=$ENDPOINTS[$((RANDOM % ${#ENDPOINTS[@]} + 1))]
    REQ_ID=$(openssl rand -hex 4 | tr '[:lower:]' '[:upper:]')
    MESSAGES=()

    case $LG in
      *apigateway*)
        if [[ "$STATE" == "FAILING" ]]; then
          if [[ "$EP" == *checkout* || "$EP" == *payment* ]]; then
            MESSAGES=("[API-GW] REQ=$REQ_ID - POST $EP - 504 Gateway Timeout (29001ms)")
          else
            MESSAGES=("[API-GW] REQ=$REQ_ID - GET $EP - 200 OK (45ms)")
          fi
        else
          MESSAGES=("[API-GW] REQ=$REQ_ID - POST $EP - 200 OK ($((RANDOM%100+20))ms)")
        fi ;;
      *lambda*)
        if [[ "$STATE" == "FAILING" ]]; then
          MESSAGES=("[LAMBDA] START req=$REQ_ID" "[LAMBDA] FATAL: ConnectionTimeout to 10.50.1.20:1521")
        else
          MESSAGES=("[LAMBDA] START req=$REQ_ID" "[LAMBDA] SUCCESS: Payment Processed")
        fi ;;
      *eks*)
        MESSAGES=("[EKS] pod/svc-$(echo $EP | cut -d'/' -f3)-$(openssl rand -hex 2) - Processing request") ;;
      *waf*)
        MESSAGES=("[WAF] ACTION: ALLOWED SOURCE_IP: $((RANDOM%255)).$((RANDOM%255)).1.10") ;;
      *cloudfront*)
        MESSAGES=("[CDN] GET /assets/logo.png 200 OK (Hit from Edge: SFO-$((RANDOM%50)))") ;;
      *)
        MESSAGES=("[AWS] $LG nominal heartbeat") ;;
    esac

    SAMPLES[$LG]=$MESSAGES[1]

    for M in "${MESSAGES[@]}"; do
      ESCAPED_MSG=$(python3 -c "import json, sys; print(json.dumps(sys.argv[1]))" "$M")
      PAYLOAD+="{\"create\": {}}"$'\n'
      PAYLOAD+="{\"@timestamp\": \"$TS\", \"source\": \"aws_cloudwatch\", \"log.group\": \"$LG\", \"message\": $ESCAPED_MSG}"$'\n'
    done
  done

  RESPONSE=$(curl -s -w "\n%{http_code}" -X POST "$BULK_URL" \
    -H "Authorization: ApiKey $API_KEY" \
    -H "Content-Type: application/x-ndjson" \
    --data-binary "$PAYLOAD")

  HTTP_STATUS=$(echo "$RESPONSE" | tail -n 1)
  BODY=$(echo "$RESPONSE" | sed '$d')
  HAS_ERRORS=$(echo "$BODY" | python3 -c "import sys,json; d=json.load(sys.stdin); print('yes' if d.get('errors') else 'no')" 2>/dev/null)

  # Live Scoreboard UI
  clear
  STATE_COLOR=$T_GREEN
  [[ "$STATE" == "FAILING" ]] && STATE_COLOR=$T_RED
  HTTP_COLOR=$T_GREEN
  [[ "$HTTP_STATUS" != "200" ]] && HTTP_COLOR=$T_RED
  echo "${T_BOLD}${T_CYAN}☁️  AWS CLOUD INGEST${T_RESET} ${T_DIM}│${T_RESET} MODE ${T_BOLD}$MODE${T_RESET} ${T_DIM}│${T_RESET} STATE ${STATE_COLOR}${T_BOLD}$STATE${T_RESET} ${T_DIM}│${T_RESET} BATCH ${T_MAGENTA}$LOGS_PER_REQUEST${T_RESET} ${T_DIM}│${T_RESET} HTTP ${HTTP_COLOR}${T_BOLD}$HTTP_STATUS${T_RESET}"
  echo "${T_DIM}API${T_RESET}  ${T_BLUE}POST${T_RESET} ${T_CYAN}$BULK_URL${T_RESET}"
  term_hr
  printf "${T_BOLD}%-32s${T_RESET} ${T_DIM}│${T_RESET} ${T_BOLD}%-45s${T_RESET}\n" "LOG GROUP" "SAMPLE MESSAGE"
  term_hr
  for group in "${GROUPS[@]}"; do
    printf "${T_DIM}%-32s${T_RESET} ${T_DIM}│${T_RESET} %s\n" "$group" "${SAMPLES[$group]}"
  done

  if [[ "$HTTP_STATUS" != "200" ]]; then
    echo ""
    echo "${T_RED}${T_BOLD}✗ HTTP $HTTP_STATUS${T_RESET}"
    echo "${T_DIM}$BODY${T_RESET}"
  elif [[ "$HAS_ERRORS" == "yes" ]]; then
    FIRST_ERR=$(echo "$BODY" | python3 -c "
import sys,json
d=json.load(sys.stdin)
for item in d.get('items',[]):
  for op in item.values():
    if op.get('error'):
      print(json.dumps(op['error'], indent=2))
      sys.exit()
")
    echo ""
    echo "${T_RED}${T_BOLD}✗ Bulk errors (first item)${T_RESET}"
    echo "${T_YELLOW}$FIRST_ERR${T_RESET}"
  fi
  
  sleep 1
done