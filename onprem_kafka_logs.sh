#!/bin/zsh
# On-Prem / Hybrid Kafka Ingest - Professional Demo Version
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

[[ "$MODE" == "failure" ]] && STATE="CRITICAL"

# Comprehensive Enterprise Team Mapping
typeset -A TEAM_MAP
TEAM_MAP=(
  "onprem-f5-loadbalancer"      "Network-Ops"
  "onprem-cisco-nexus-core"     "Network-Ops"
  "onprem-mainframe-db2"        "Mainframe-Core"
  "onprem-oracle-financials"    "Data-Platform"
  "onprem-active-directory"     "Identity-Sec"
  "onprem-vmware-vcenter"       "Infra-Cloud"
  "onprem-websphere-mq"         "App-Middleware"
  "onprem-linux-jumphost"       "Security-Ops"
)

# Kafka topic IDs per team (each team may have many topics)
typeset -A TEAM_TOPIC_IDS
TEAM_TOPIC_IDS=(
  "Network-Ops"       "lb-metrics lb-health ingress-events"
  "Mainframe-Core"    "db2-audit cics-transactions ims-logs"
  "Data-Platform"    "erp-payments erp-ledger oracle-alerts"
  "Identity-Sec"     "ad-auth ad-audit kerberos-events"
  "Infra-Cloud"      "vcenter-events vm-metrics cluster-state"
  "App-Middleware"   "mq-payments mq-inventory mq-sync"
  "Security-Ops"     "ssh-audit firewall-events jumphost-logs"
)

SERVICES=("${(k)TEAM_MAP[@]}")
typeset -A SAMPLES
typeset -A SAMPLES_TOPIC

while true; do
  PAYLOAD=""
  TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  
  # Loop for the number of logs requested per API call
  for ((i=1; i<=$LOGS_PER_REQUEST; i++)); do
    SVC=$SERVICES[$((RANDOM % ${#SERVICES[@]} + 1))]
    TEAM=$TEAM_MAP[$SVC]
    TX_ID=$(openssl rand -hex 3 | tr '[:lower:]' '[:upper:]')
    
    case $SVC in
      *mainframe*) 
        if [[ "$STATE" == "CRITICAL" ]]; then
          MSG="[DB2-ZOS] LOCK CONFLICT: LPAR-PRI-01 Resource DSNDB01.SYSUSER unavailable"
        else
          MSG="[DB2-ZOS] LPAR-SEC-04 Commit successful for plan DSNTEP2 (TX=$TX_ID)"
        fi ;;
      *oracle*) 
        if [[ "$STATE" == "CRITICAL" ]]; then
          MSG="[ORA-PROD] TNS-12170: Connect timeout occurred from client 10.0.1.5"
        else
          MSG="[ORA-PROD] Session established for user APP_PAYMENT_SVC (SID=$((RANDOM%999)))"
        fi ;;
      *f5*) 
        if [[ "$STATE" == "CRITICAL" ]]; then
          MSG="[F5-LB] Pool /Common/Oracle_ERP_1521 has no active members"
        else
          MSG="[F5-LB] Forwarding connection to member 10.50.1.20:1521 (SNAT enabled)"
        fi ;;
      *websphere*)
        if [[ "$STATE" == "CRITICAL" ]]; then
          MSG="[MQ] WARNING: Queue Depth for 'PAY_SYNC_Q' exceeded threshold (98%)"
        else
          MSG="[MQ] Message TX-$TX_ID successfully delivered to listener"
        fi ;;
      *active-directory*) 
        MSG="[AD-DC-01] Kerberos TGT issued for user: svc_aws_lambda" ;;
      *cisco*)
        MSG="[NEXUS] %LINEPROTO-5-UPDOWN: Line protocol on Interface Vlan10, changed state to up" ;;
      *) 
        MSG="[DC1] $SVC status: GREEN (Operational)" ;;
    esac

    SAMPLES[$SVC]=$MSG

    # Kafka topic IDs for this team (pick one for this log)
    TOPIC_LIST_STR="${TEAM_TOPIC_IDS[$TEAM]:-default-topic}"
    topics=("${(s: :)TOPIC_LIST_STR}")
    TOPIC_ID=$topics[$((RANDOM % ${#topics[@]} + 1))]
    SAMPLES_TOPIC[$SVC]=$TOPIC_ID

    ESCAPED_MSG=$(python3 -c "import json, sys; print(json.dumps(sys.argv[1]))" "$MSG")
    PAYLOAD+="{\"create\": {}}"$'\n'
    PAYLOAD+="{\"@timestamp\": \"$TS\", \"source\": \"logs team\", \"team-name\": \"$TEAM\", \"service.name\": \"$SVC\", \"kafka.topic.id\": \"$TOPIC_ID\", \"body.text\": $ESCAPED_MSG}"$'\n'
  done

  RESPONSE=$(curl -s -w "\n%{http_code}" -X POST "$BULK_URL" \
    -H "Authorization: ApiKey $API_KEY" \
    -H "Content-Type: application/x-ndjson" \
    --data-binary "$PAYLOAD")

  HTTP_STATUS=$(echo "$RESPONSE" | tail -n 1)
  BODY=$(echo "$RESPONSE" | sed '$d')
  HAS_ERRORS=$(echo "$BODY" | python3 -c "import sys,json; d=json.load(sys.stdin); print('yes' if d.get('errors') else 'no')" 2>/dev/null)

  clear
  STATE_COLOR=$T_GREEN
  [[ "$STATE" == "CRITICAL" ]] && STATE_COLOR=$T_RED
  HTTP_COLOR=$T_GREEN
  [[ "$HTTP_STATUS" != "200" ]] && HTTP_COLOR=$T_RED
  echo "${T_BOLD}${T_MAGENTA}🏢 ON-PREM KAFKA INGEST${T_RESET} ${T_DIM}│${T_RESET} MODE ${T_BOLD}$MODE${T_RESET} ${T_DIM}│${T_RESET} STATE ${STATE_COLOR}${T_BOLD}$STATE${T_RESET} ${T_DIM}│${T_RESET} BATCH ${T_MAGENTA}$LOGS_PER_REQUEST${T_RESET} ${T_DIM}│${T_RESET} HTTP ${HTTP_COLOR}${T_BOLD}$HTTP_STATUS${T_RESET}"
  echo "${T_DIM}API${T_RESET}  ${T_BLUE}POST${T_RESET} ${T_CYAN}$BULK_URL${T_RESET}"
  term_hr
  printf "${T_BOLD}%-28s${T_RESET} ${T_DIM}│${T_RESET} ${T_BOLD}%-15s${T_RESET} ${T_DIM}│${T_RESET} ${T_BOLD}%-18s${T_RESET} ${T_DIM}│${T_RESET} ${T_BOLD}%-40s${T_RESET}\n" "SERVICE" "TEAM" "KAFKA.TOPIC.ID" "LATEST LOG MESSAGE"
  term_hr
  for s in "${SERVICES[@]}"; do
    printf "${T_DIM}%-28s${T_RESET} ${T_DIM}│${T_RESET} ${T_CYAN}%-15s${T_RESET} ${T_DIM}│${T_RESET} ${T_YELLOW}%-18s${T_RESET} ${T_DIM}│${T_RESET} %s\n" "$s" "$TEAM_MAP[$s]" "${SAMPLES_TOPIC[$s]:--}" "${SAMPLES[$s]}"
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