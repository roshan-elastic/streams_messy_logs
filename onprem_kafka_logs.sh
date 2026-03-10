#!/bin/zsh
# On-Prem / Hybrid Kafka Ingest - Professional Demo Version
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
PREFERRED_SCHEMA=otel

# Parse command line flags
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --mode) MODE="$2"; shift ;;
        --logs-per-request) LOGS_PER_REQUEST="$2"; shift ;;
        --preferred-schema) PREFERRED_SCHEMA="$2"; shift ;;
        *) echo "Unknown parameter: $1"; exit 1 ;;
    esac
    shift
done

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

    # Kafka topic IDs for this team (pick one for this log, keep full list for context) (pick one for this log, keep full list for context)
    TOPIC_LIST_STR="${TEAM_TOPIC_IDS[$TEAM]:-default-topic}"
    topics=("${(s: :)TOPIC_LIST_STR}")
    TOPIC_ID=$topics[$((RANDOM % ${#topics[@]} + 1))]
    SAMPLES_TOPIC[$SVC]=$TOPIC_ID

    ESCAPED_MSG=$(python3 -c "import json, sys; print(json.dumps(sys.argv[1]))" "$MSG")
    PAYLOAD+="{\"create\": {}}"$'\n'
    PAYLOAD+="{\"@timestamp\": \"$TS\", \"source\": \"logs team\", \"team-name\": \"$TEAM\", \"service.name\": \"$SVC\", \"kafka.topic.id\": \"$TOPIC_ID\", \"body.text\": $ESCAPED_MSG}"$'\n'
  done

  # Sending to /logs/_bulk
  BULK_URL="$ELASTIC_URL/logs.$PREFERRED_SCHEMA/_bulk"
  RESPONSE=$(curl -s -w "\n%{http_code}" -X POST "$BULK_URL" \
    -H "Authorization: ApiKey $API_KEY" \
    -H "Content-Type: application/x-ndjson" \
    --data-binary "$PAYLOAD")

  HTTP_STATUS=$(echo "$RESPONSE" | tail -n 1)

  clear
  echo "🏢 ON-PREM KAFKA INGEST | MODE: $MODE | STATE: $STATE | BATCH SIZE: $LOGS_PER_REQUEST | HTTP: $HTTP_STATUS"
  echo "API: POST $BULK_URL"
  echo "--------------------------------------------------------------------------------"
  printf "%-28s | %-15s | %-18s | %-40s\n" "SERVICE" "TEAM" "KAFKA.TOPIC.ID" "LATEST LOG MESSAGE"
  echo "--------------------------------------------------------------------------------"
  for s in "${SERVICES[@]}"; do
    printf "%-28s | %-15s | %-18s | %-40s\n" "$s" "$TEAM_MAP[$s]" "${SAMPLES_TOPIC[$s]:--}" "${SAMPLES[$s]}"
  done
  
  [[ "$HTTP_STATUS" != "200" ]] && echo "\n❌ API ERROR: $(echo "$RESPONSE" | sed '$d')"
  
  sleep 1
done