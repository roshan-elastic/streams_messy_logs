#!/bin/zsh
# GKE EDOT Collector + Cloud Run Application Log Ingest
#
# Consolidated application log generator for all e-commerce services running
# on GCP. Two log sources are simulated in a single script:
#
#   1. GKE workloads collected by the Elastic EDOT OpenTelemetry Collector
#      (opentelemetry-kube-stack DaemonSet) on a 3-node GKE cluster. Each
#      document carries the resource attributes the EDOT k8sattributes +
#      resourcedetection processors add (k8s.*, service.*, host.*, cloud.*).
#
#      Services (2 replicas each = 12 pods total):
#        - frontend          (Node.js SSR)
#        - product-catalog   (PostgreSQL-backed)
#        - checkout          (order orchestration)
#        - inventory         (Cloud Spanner-backed)
#        - auth              (JWT / KMS / Redis sessions)
#        - user              (Cloud SQL-backed profiles)
#
#   2. Cloud Run function 'payment-gateway' — application logs only.
#      These documents have NO k8s.* attributes. They carry Cloud Run / FaaS
#      resource attributes (cloud.platform=gcp_cloud_run, faas.name, etc.)
#      and use source=gcp_cloud_logging to clearly distinguish them from the
#      GKE docs. System/platform events for Cloud Run are NOT emitted here —
#      those live in gcp-services-logs.py.
#
# Ships to the same Elastic bulk API as the other GCP log scripts — NOT OTLP.
#
# Cluster:  checkout-prod (3 × n2-standard-4 nodes, us-west1-a)

SCRIPT_DIR="${0:A:h}"
if [[ -f "$SCRIPT_DIR/elastic.env" ]]; then
  source "$SCRIPT_DIR/elastic.env"
elif [[ -f "$SCRIPT_DIR/../elastic.env" ]]; then
  source "$SCRIPT_DIR/../elastic.env"
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

[[ "$MODE" == "failure" ]] && STATE="FAILING"

# Cluster / cloud metadata
CLUSTER_NAME="checkout-prod"
NAMESPACE="ecommerce"
CLOUD_REGION="us-west1"
CLOUD_ZONE="us-west1-a"
CLOUD_ACCOUNT="ecommerce-prod"
GKE_PLATFORM="gcp_kubernetes_engine"
CLOUD_RUN_PLATFORM="gcp_cloud_run"

# 3 GKE worker nodes (n2-standard-4)
NODES=(
  "gke-checkout-prod-default-pool-a1b2c3d4-xz1q"
  "gke-checkout-prod-default-pool-a1b2c3d4-xz2r"
  "gke-checkout-prod-default-pool-a1b2c3d4-xz3s"
)

# ---- GKE pod topology ----
#   pod_name -> "deployment|replicaset|container|node|pod_ip|pod_uid|service_version"
typeset -A PODS
PODS=(
  "frontend-7d9f6b8c4-abcde"        "frontend|frontend-7d9f6b8c4|frontend|${NODES[1]}|10.24.1.11|6f2a7f1a-1111-4a01-9a11-aaaaaaaaaaaa|1.14.2"
  "frontend-7d9f6b8c4-fghij"        "frontend|frontend-7d9f6b8c4|frontend|${NODES[2]}|10.24.2.12|6f2a7f1a-2222-4a01-9a11-bbbbbbbbbbbb|1.14.2"
  "product-catalog-5f7c9d6b8-klmno" "product-catalog|product-catalog-5f7c9d6b8|product-catalog|${NODES[1]}|10.24.1.21|7e3b8f2b-3333-4b02-8b22-cccccccccccc|2.8.0"
  "product-catalog-5f7c9d6b8-pqrst" "product-catalog|product-catalog-5f7c9d6b8|product-catalog|${NODES[3]}|10.24.3.22|7e3b8f2b-4444-4b02-8b22-dddddddddddd|2.8.0"
  "checkout-6b8d9f7c5-uvwxy"        "checkout|checkout-6b8d9f7c5|checkout|${NODES[2]}|10.24.2.31|8f4c9a3c-5555-4c03-7c33-eeeeeeeeeeee|3.5.1"
  "checkout-6b8d9f7c5-zabcd"        "checkout|checkout-6b8d9f7c5|checkout|${NODES[3]}|10.24.3.32|8f4c9a3c-6666-4c03-7c33-ffffffffffff|3.5.1"
  "inventory-7a9e2b4d6-hijkl"       "inventory|inventory-7a9e2b4d6|inventory|${NODES[1]}|10.24.1.41|9a5d0b4d-7777-4d04-6d44-111111111111|4.2.0"
  "inventory-7a9e2b4d6-mnopq"       "inventory|inventory-7a9e2b4d6|inventory|${NODES[3]}|10.24.3.42|9a5d0b4d-8888-4d04-6d44-222222222222|4.2.0"
  "auth-8c1f3a5b7-rstuv"            "auth|auth-8c1f3a5b7|auth|${NODES[2]}|10.24.2.51|ab6e1c5e-9999-4e05-5e55-333333333333|2.1.5"
  "auth-8c1f3a5b7-wxyza"            "auth|auth-8c1f3a5b7|auth|${NODES[3]}|10.24.3.52|ab6e1c5e-aaaa-4e05-5e55-444444444444|2.1.5"
  "user-9d2e4c6f8-bcdef"            "user|user-9d2e4c6f8|user|${NODES[1]}|10.24.1.61|bc7f2d6f-bbbb-4f06-4f66-555555555555|1.6.3"
  "user-9d2e4c6f8-ghijk"            "user|user-9d2e4c6f8|user|${NODES[2]}|10.24.2.62|bc7f2d6f-cccc-4f06-4f66-666666666666|1.6.3"
)
POD_NAMES=("${(k)PODS[@]}")

# ---- Cloud Run function 'payment-gateway' instance topology ----
#   instance_id -> "service|revision|configuration|version"
typeset -A CR_INSTANCES
CR_INSTANCES=(
  "payment-gateway-00042-abc-i1" "payment-gateway|payment-gateway-00042-abc|payment-gateway|1.8.3"
  "payment-gateway-00042-abc-i2" "payment-gateway|payment-gateway-00042-abc|payment-gateway|1.8.3"
)
CR_NAMES=("${(k)CR_INSTANCES[@]}")

# Combined workload roster — pods heavily outnumber CR instances so GKE
# dominates naturally (12 pods vs 2 CR instances ≈ 86% / 14% traffic split).
WORKLOADS=("${POD_NAMES[@]}" "${CR_NAMES[@]}")

# Service display order for the scoreboard
SERVICE_ORDER=("frontend" "product-catalog" "checkout" "inventory" "auth" "user" "payment-gateway")
typeset -A SERVICE_KIND
SERVICE_KIND=(
  "frontend" "gke"
  "product-catalog" "gke"
  "checkout" "gke"
  "inventory" "gke"
  "auth" "gke"
  "user" "gke"
  "payment-gateway" "cloud-run"
)

typeset -A SAMPLES
typeset -A SAMPLE_SEV

while true; do
  PAYLOAD=""
  TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  for ((i=1; i<=$LOGS_PER_REQUEST; i++)); do
    WID=$WORKLOADS[$((RANDOM % ${#WORKLOADS[@]} + 1))]
    TRACE_ID=$(openssl rand -hex 16)
    SPAN_ID=$(openssl rand -hex 8)
    REQ_ID=$(openssl rand -hex 4 | tr '[:lower:]' '[:upper:]')
    SEVERITY="INFO"
    BODY=""
    KIND=""

    if [[ -n "${PODS[$WID]}" ]]; then
      KIND="gke"
      META="${PODS[$WID]}"
      DEPLOY="${META%%|*}";       REST="${META#*|}"
      RS="${REST%%|*}";           REST="${REST#*|}"
      CONTAINER="${REST%%|*}";    REST="${REST#*|}"
      NODE="${REST%%|*}";         REST="${REST#*|}"
      POD_IP="${REST%%|*}";       REST="${REST#*|}"
      POD_UID="${REST%%|*}";      REST="${REST#*|}"
      VERSION="${REST}"

      case $DEPLOY in
        frontend)
          if [[ "$STATE" == "FAILING" ]]; then
            CHOICE=$((RANDOM % 3))
            if [[ $CHOICE -eq 0 ]]; then
              BODY="GET /cart 502 Bad Gateway upstream=checkout.ecommerce.svc.cluster.local:8080 err=\"context deadline exceeded\" req=$REQ_ID"
              SEVERITY="ERROR"
            elif [[ $CHOICE -eq 1 ]]; then
              BODY="circuit-breaker OPEN for service=product-catalog failures=27/30 window=10s req=$REQ_ID"
              SEVERITY="WARN"
            else
              BODY="GET /products 200 OK rendered=ssr duration_ms=$((RANDOM%60+15)) req=$REQ_ID"
            fi
          else
            PATHS=("/" "/products" "/cart" "/account" "/search?q=shoes")
            PP=$PATHS[$((RANDOM % ${#PATHS[@]} + 1))]
            BODY="GET $PP 200 OK rendered=ssr duration_ms=$((RANDOM%60+15)) req=$REQ_ID"
          fi ;;
        product-catalog)
          if [[ "$STATE" == "FAILING" ]]; then
            CHOICE=$((RANDOM % 2))
            if [[ $CHOICE -eq 0 ]]; then
              BODY="postgres connection pool exhausted waiting=12 max=10 db=catalog err=\"timeout acquiring connection\" req=$REQ_ID"
              SEVERITY="ERROR"
            else
              BODY="slow query SELECT products WHERE category=? duration_ms=2184 rows=0 req=$REQ_ID"
              SEVERITY="WARN"
            fi
          else
            ACTIONS=(
              "listed 24 products category=electronics duration_ms=$((RANDOM%25+5))"
              "search q=\"running shoes\" hits=57 duration_ms=$((RANDOM%30+8))"
              "cache HIT key=product:SKU-$((RANDOM%9999))"
              "listed 18 products category=apparel duration_ms=$((RANDOM%25+5))"
            )
            BODY="${ACTIONS[$((RANDOM % ${#ACTIONS[@]} + 1))]} req=$REQ_ID"
          fi ;;
        checkout)
          if [[ "$STATE" == "FAILING" ]]; then
            CHOICE=$((RANDOM % 2))
            if [[ $CHOICE -eq 0 ]]; then
              BODY="payment-gateway call FAILED status=503 upstream=cloudrun/payment-gateway latency_ms=28991 req=$REQ_ID"
              SEVERITY="ERROR"
            else
              BODY="order $REQ_ID rolled back reason=\"payment upstream timeout\" items=$((RANDOM%5+1))"
              SEVERITY="ERROR"
            fi
          else
            ACTIONS=(
              "cart validated items=$((RANDOM%5+1)) total_cents=$((RANDOM%20000+500)) req=$REQ_ID"
              "inventory reserved orderId=$REQ_ID duration_ms=$((RANDOM%30+10))"
              "order $REQ_ID created status=CONFIRMED"
              "session token refreshed userId=u$((RANDOM%9999)) req=$REQ_ID"
            )
            BODY="${ACTIONS[$((RANDOM % ${#ACTIONS[@]} + 1))]}"
          fi ;;
        inventory)
          if [[ "$STATE" == "FAILING" ]]; then
            CHOICE=$((RANDOM % 3))
            if [[ $CHOICE -eq 0 ]]; then
              BODY="spanner read timeout table=stock session_exhausted=true duration_ms=5012 req=$REQ_ID"
              SEVERITY="ERROR"
            elif [[ $CHOICE -eq 1 ]]; then
              BODY="inventory lock contention SKU=SKU-$((RANDOM%9999)) retries=3 req=$REQ_ID"
              SEVERITY="WARN"
            else
              BODY="reservation failed orderId=$REQ_ID reason=insufficient_stock SKU=SKU-$((RANDOM%9999))"
              SEVERITY="WARN"
            fi
          else
            ACTIONS=(
              "stock check SKU=SKU-$((RANDOM%9999)) available=true qty=$((RANDOM%200+10))"
              "reserved orderId=$REQ_ID items=$((RANDOM%4+1)) duration_ms=$((RANDOM%20+5))"
              "restock event SKU=SKU-$((RANDOM%9999)) added=100 new_qty=$((RANDOM%500+100))"
              "inventory sync with product-catalog completed items=$((RANDOM%50+10))"
            )
            BODY="${ACTIONS[$((RANDOM % ${#ACTIONS[@]} + 1))]} req=$REQ_ID"
          fi ;;
        auth)
          if [[ "$STATE" == "FAILING" ]]; then
            CHOICE=$((RANDOM % 3))
            if [[ $CHOICE -eq 0 ]]; then
              BODY="KMS sign failed key=projects/ecommerce-prod/locations/us-west1/keyRings/auth/cryptoKeys/jwt-signer err=\"permission_denied\" req=$REQ_ID"
              SEVERITY="ERROR"
            elif [[ $CHOICE -eq 1 ]]; then
              BODY="redis session store timeout addr=redis-auth.ecommerce.svc.cluster.local:6379 req=$REQ_ID"
              SEVERITY="ERROR"
            else
              BODY="login rate-limited ip=203.0.113.$((RANDOM%255)) attempts=10 req=$REQ_ID"
              SEVERITY="WARN"
            fi
          else
            ACTIONS=(
              "JWT issued userId=u$((RANDOM%9999)) method=password duration_ms=$((RANDOM%15+3))"
              "refresh token rotated userId=u$((RANDOM%9999))"
              "mfa challenge passed userId=u$((RANDOM%9999)) factor=totp"
              "session created userId=u$((RANDOM%9999)) expires_in=3600"
              "logout successful userId=u$((RANDOM%9999))"
            )
            BODY="${ACTIONS[$((RANDOM % ${#ACTIONS[@]} + 1))]} req=$REQ_ID"
          fi ;;
        user)
          if [[ "$STATE" == "FAILING" ]]; then
            CHOICE=$((RANDOM % 2))
            if [[ $CHOICE -eq 0 ]]; then
              BODY="Cloud SQL connection refused db=user-db host=10.24.0.5:5432 err=\"connection_timeout\" req=$REQ_ID"
              SEVERITY="ERROR"
            else
              BODY="slow query SELECT user_prefs WHERE user_id=? duration_ms=2341 req=$REQ_ID"
              SEVERITY="WARN"
            fi
          else
            ACTIONS=(
              "profile fetched userId=u$((RANDOM%9999)) cache=HIT duration_ms=$((RANDOM%15+2))"
              "profile updated userId=u$((RANDOM%9999)) fields=[email,phone]"
              "preferences saved userId=u$((RANDOM%9999)) keys=$((RANDOM%6+1))"
              "address book loaded userId=u$((RANDOM%9999)) entries=$((RANDOM%5+1))"
            )
            BODY="${ACTIONS[$((RANDOM % ${#ACTIONS[@]} + 1))]} req=$REQ_ID"
          fi ;;
      esac

      SAMPLES[$DEPLOY]="$BODY"
      SAMPLE_SEV[$DEPLOY]="$SEVERITY"

      ESCAPED_BODY=$(python3 -c "import json, sys; print(json.dumps(sys.argv[1]))" "$BODY")
      PAYLOAD+="{\"create\": {}}"$'\n'
      PAYLOAD+="{\"@timestamp\": \"$TS\", \"observed_timestamp\": \"$TS\", \"source\": \"edot_kube_stack\", \"body.text\": $ESCAPED_BODY, \"severity_text\": \"$SEVERITY\", \"trace.id\": \"$TRACE_ID\", \"span.id\": \"$SPAN_ID\", \"scope.name\": \"otelcol/filelogreceiver\", \"resource.attributes.elasticsearch.index\": \"logs.otel\", \"resource.attributes.k8s.cluster.name\": \"$CLUSTER_NAME\", \"resource.attributes.k8s.namespace.name\": \"$NAMESPACE\", \"resource.attributes.k8s.node.name\": \"$NODE\", \"resource.attributes.k8s.pod.name\": \"$WID\", \"resource.attributes.k8s.pod.uid\": \"$POD_UID\", \"resource.attributes.k8s.pod.ip\": \"$POD_IP\", \"resource.attributes.k8s.deployment.name\": \"$DEPLOY\", \"resource.attributes.k8s.replicaset.name\": \"$RS\", \"resource.attributes.k8s.container.name\": \"$CONTAINER\", \"resource.attributes.service.name\": \"$DEPLOY\", \"resource.attributes.service.instance.id\": \"$POD_UID\", \"resource.attributes.service.version\": \"$VERSION\", \"resource.attributes.host.name\": \"$NODE\", \"resource.attributes.host.arch\": \"amd64\", \"resource.attributes.os.type\": \"linux\", \"resource.attributes.cloud.provider\": \"gcp\", \"resource.attributes.cloud.platform\": \"$GKE_PLATFORM\", \"resource.attributes.cloud.region\": \"$CLOUD_REGION\", \"resource.attributes.cloud.availability_zone\": \"$CLOUD_ZONE\", \"resource.attributes.cloud.account.id\": \"$CLOUD_ACCOUNT\"}"$'\n'

    else
      # ---- Cloud Run function path ----
      KIND="cloud-run"
      META="${CR_INSTANCES[$WID]}"
      CR_SERVICE="${META%%|*}";   REST="${META#*|}"
      CR_REVISION="${REST%%|*}";  REST="${REST#*|}"
      CR_CONFIG="${REST%%|*}";    REST="${REST#*|}"
      CR_VERSION="${REST}"

      if [[ "$STATE" == "FAILING" ]]; then
        CHOICE=$((RANDOM % 3))
        if [[ $CHOICE -eq 0 ]]; then
          BODY="oracle connection timeout via cloud interconnect 10.50.1.20:1521 err=\"context_deadline_exceeded\" duration_ms=29012 req=$REQ_ID"
          SEVERITY="ERROR"
        elif [[ $CHOICE -eq 1 ]]; then
          BODY="gateway timeout upstream=api.stripe.com duration_ms=29001 txId=$REQ_ID"
          SEVERITY="ERROR"
        else
          BODY="KMS sign error key=projects/ecommerce-prod/locations/us-west1/keyRings/payment/cryptoKeys/card-token err=\"unavailable\" req=$REQ_ID"
          SEVERITY="ERROR"
        fi
      else
        CHOICE=$((RANDOM % 5))
        case $CHOICE in
          0) BODY="payment authorized txId=$REQ_ID amount_cents=$((RANDOM%10000+500)) card_network=visa duration_ms=$((RANDOM%200+80))" ;;
          1) BODY="3DS challenge completed result=PASS txId=$REQ_ID duration_ms=$((RANDOM%800+200))" ;;
          2) BODY="payment captured txId=$REQ_ID gateway=stripe status=SUCCEEDED amount_cents=$((RANDOM%10000+500))" ;;
          3) BODY="refund processed txId=$REQ_ID amount_cents=$((RANDOM%5000+100)) status=REFUNDED" ;;
          4) BODY="token vault lookup cardId=card_$(openssl rand -hex 4) cache=HIT duration_ms=$((RANDOM%15+2))" ;;
        esac
      fi

      SAMPLES[$CR_SERVICE]="$BODY"
      SAMPLE_SEV[$CR_SERVICE]="$SEVERITY"

      ESCAPED_BODY=$(python3 -c "import json, sys; print(json.dumps(sys.argv[1]))" "$BODY")
      PAYLOAD+="{\"create\": {}}"$'\n'
      PAYLOAD+="{\"@timestamp\": \"$TS\", \"observed_timestamp\": \"$TS\", \"source\": \"gcp_cloud_logging\", \"body.text\": $ESCAPED_BODY, \"severity_text\": \"$SEVERITY\", \"trace.id\": \"$TRACE_ID\", \"span.id\": \"$SPAN_ID\", \"scope.name\": \"gcp/cloud_run\", \"resource.attributes.elasticsearch.index\": \"logs.otel\", \"resource.attributes.service.name\": \"$CR_SERVICE\", \"resource.attributes.service.instance.id\": \"$WID\", \"resource.attributes.service.version\": \"$CR_VERSION\", \"resource.attributes.faas.name\": \"$CR_SERVICE\", \"resource.attributes.faas.version\": \"$CR_REVISION\", \"resource.attributes.faas.instance\": \"$WID\", \"resource.attributes.gcp.cloud_run.revision_name\": \"$CR_REVISION\", \"resource.attributes.gcp.cloud_run.configuration_name\": \"$CR_CONFIG\", \"resource.attributes.cloud.provider\": \"gcp\", \"resource.attributes.cloud.platform\": \"$CLOUD_RUN_PLATFORM\", \"resource.attributes.cloud.region\": \"$CLOUD_REGION\", \"resource.attributes.cloud.account.id\": \"$CLOUD_ACCOUNT\"}"$'\n'
    fi
  done

  BULK_URL="$ELASTIC_URL/logs.$PREFERRED_SCHEMA/_bulk"
  RESPONSE=$(curl -s -w "\n%{http_code}" -X POST "$BULK_URL" \
    -H "Authorization: ApiKey $API_KEY" \
    -H "Content-Type: application/x-ndjson" \
    --data-binary "$PAYLOAD")

  HTTP_STATUS=$(echo "$RESPONSE" | tail -n 1)

  # Live scoreboard — one row per service (across all replicas/instances)
  clear
  echo "⎈  GCP APPLICATION LOG INGEST | CLUSTER: $CLUSTER_NAME | MODE: $MODE | STATE: $STATE | BATCH: $LOGS_PER_REQUEST | HTTP: $HTTP_STATUS"
  echo "NODES: ${NODES[1]##*-}  ${NODES[2]##*-}  ${NODES[3]##*-}   (namespace=$NAMESPACE, region=$CLOUD_REGION)"
  echo "API: POST $BULK_URL"
  echo "--------------------------------------------------------------------------------------------"
  printf "%-18s | %-10s | %-5s | %-55s\n" "SERVICE" "RUNTIME" "SEV" "LATEST MESSAGE"
  echo "--------------------------------------------------------------------------------------------"
  for s in "${SERVICE_ORDER[@]}"; do
    printf "%-18s | %-10s | %-5s | %-55s\n" "$s" "${SERVICE_KIND[$s]}" "${SAMPLE_SEV[$s]:-INFO}" "${SAMPLES[$s]:-(no traffic yet)}"
  done

  [[ "$HTTP_STATUS" != "200" ]] && echo "\n❌ API ERROR: $(echo "$RESPONSE" | sed '$d')"

  sleep 1
done
