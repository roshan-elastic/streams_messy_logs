#!/bin/zsh
# E-Commerce Cloud Ingest - Multi-Service & Scalable Volume Version
SCRIPT_DIR="${0:A:h}"
if [[ -f "$SCRIPT_DIR/elastic.env" ]]; then
  source "$SCRIPT_DIR/elastic.env"
else
  echo "Missing elastic.env. Copy elastic.env.template to elastic.env and set ELASTIC_URL and API_KEY." >&2
  exit 1
fi
[[ -z "$ELASTIC_URL" || -z "$API_KEY" ]] && { echo "ELASTIC_URL and API_KEY must be set in elastic.env." >&2; exit 1; }

# Default Values
MODE="normal"
STATE="HEALTHY"
LOGS_PER_REQUEST=100
INDEX=logs.otel

# Parse command line flags
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --mode) MODE="$2"; shift ;;
        --logs-per-request) LOGS_PER_REQUEST="$2"; shift ;;
        *) echo "Unknown parameter: $1"; exit 1 ;;
    esac
    shift
done

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

  # Send to the logs endpoint
  BULK_URL="$ELASTIC_URL/$INDEX/_bulk"
  RESPONSE=$(curl -s -w "\n%{http_code}" -X POST "$BULK_URL" \
    -H "Authorization: ApiKey $API_KEY" \
    -H "Content-Type: application/x-ndjson" \
    --data-binary "$PAYLOAD")

  HTTP_STATUS=$(echo "$RESPONSE" | tail -n 1)

  # Live Scoreboard UI
  clear
  echo "☁️  AWS CLOUD INGEST | MODE: $MODE | STATE: $STATE | BATCH: $LOGS_PER_REQUEST | HTTP: $HTTP_STATUS"
  echo "API: POST $BULK_URL"
  echo "--------------------------------------------------------------------------------"
  printf "%-32s | %-45s\n" "LOG GROUP" "SAMPLE MESSAGE"
  echo "--------------------------------------------------------------------------------"
  for group in "${GROUPS[@]}"; do
    printf "%-32s | %-45s\n" "$group" "${SAMPLES[$group]}"
  done
  
  [[ "$HTTP_STATUS" != "200" ]] && echo "\n❌ API ERROR: $(echo "$RESPONSE" | sed '$d')"
  
  sleep 1
done