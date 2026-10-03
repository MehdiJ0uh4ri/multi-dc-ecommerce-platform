#!/usr/bin/env bash
# Phase 7 — run one chaos experiment against live traffic and report what happened.
#   scripts/chaos-demo.sh <kafka-broker-kill|postgres-primary-kill|dc-partition|cross-dc-latency>
#
# 1. Starts a traffic pod in DC1: every 2 s, token -> POST /api/carts -> POST /api/orders
#    through APISIX, each order tagged with this run's id.
# 2. Baseline, then applies chaos/experiments/<scenario>.yaml, waits for recovery.
# 3. Reports: request success before/during/after, longest error window, recovery time,
#    Kafka lag / MirrorMaker 2 latency peaks (Prometheus), and whether every order written
#    during the run reached DC1 PostgreSQL, the DC1 CDC topic and DC2 MongoDB.
# See docs/chaos-runbook.md for hypotheses and what to watch in Grafana.
set -uo pipefail

SCENARIO=${1:-}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
EXP="$ROOT/chaos/experiments/$SCENARIO.yaml"
[ -n "$SCENARIO" ] && [ -f "$EXP" ] || { echo "usage: $0 <$(ls "$ROOT/chaos/experiments" | sed 's/\.yaml$//' | tr '\n' '|' | sed 's/|$//')>"; exit 2; }

CTX=${KUBE_CONTEXT:-k3d-multidc}
DC1=dc1-core
DC2=dc2-analytics
BASELINE=${BASELINE:-30}      # seconds of traffic before the fault
OBSERVE=${OBSERVE:-240}       # seconds of traffic after the fault is injected
RUN="chaos-${SCENARIO}-$(date +%s)"
CURL_IMAGE=curlimages/curl:8.22.0

k() { kubectl --context "$CTX" "$@"; }
log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
PF_PID=""
cleanup() {
  k delete -f "$EXP" --ignore-not-found >/dev/null 2>&1
  k -n "$DC1" delete pod -l "chaos-run=$RUN" --ignore-not-found --wait=false >/dev/null 2>&1
  [ -n "$PF_PID" ] && kill "$PF_PID" 2>/dev/null
}
trap cleanup EXIT

# ---- 1. traffic ---------------------------------------------------------------------
read -r -d '' TRAFFIC <<'EOF'
end=$(( $(date +%s) + DURATION )); i=0; tok_at=0; TOKEN=""
token() {
  curl -sf --max-time 10 --retry 5 --retry-all-errors --retry-delay 1 \
    -d grant_type=password -d client_id=ecommerce-client -d username=testuser -d password=testpass \
    http://keycloak:8080/realms/ecommerce/protocol/openid-connect/token | sed -n 's/.*"access_token":"\([^"]*\)".*/\1/p'
}
while [ "$(date +%s)" -lt "$end" ]; do
  now=$(date +%s)
  if [ $((now - tok_at)) -ge 240 ] || [ -z "$TOKEN" ]; then TOKEN=$(token); tok_at=$now; fi
  i=$((i + 1))
  cart=$(curl -s --max-time 5 -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
    -d '{"userId":1}' http://apisix-gateway/api/carts | sed -n 's/.*"cartId":\([0-9]*\).*/\1/p')
  code=$(curl -s --max-time 5 -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $TOKEN" \
    -H 'Content-Type: application/json' \
    -d "{\"orderDesc\":\"$RUN-$i\",\"orderFee\":1.5,\"productId\":1,\"cart\":{\"cartId\":${cart:-0}}}" \
    http://apisix-gateway/api/orders)
  echo "T $now $i $code"
  sleep 2
done
echo "DONE"
EOF
log "run id: $RUN"
k -n "$DC1" run "traffic-$(date +%s)" --image="$CURL_IMAGE" --restart=Never \
  --labels="chaos-run=$RUN" --env="RUN=$RUN" --env="DURATION=$((BASELINE + OBSERVE))" \
  --command -- sh -c "$TRAFFIC" >/dev/null
TPOD=$(k -n "$DC1" get pod -l "chaos-run=$RUN" -o jsonpath='{.items[0].metadata.name}')
k -n "$DC1" wait --for=condition=Ready "pod/$TPOD" --timeout=120s >/dev/null
log "traffic running in $DC1/$TPOD; baseline ${BASELINE}s"
sleep "$BASELINE"

# ---- 2. inject ----------------------------------------------------------------------
primary_before=$(k -n "$DC1" get cluster.postgresql.cnpg.io pg-dc1 -o jsonpath='{.status.currentPrimary}' 2>/dev/null)
T0=$(date +%s)
log "injecting $SCENARIO ($EXP)"
k apply -f "$EXP" >/dev/null
case "$SCENARIO" in
  kafka-broker-kill)
    sleep 10
    k -n "$DC1" wait --for=condition=Ready kafka.kafka.strimzi.io/kafka-dc1 --timeout=600s >/dev/null
    k -n "$DC1" wait --for=condition=Ready pod -l strimzi.io/cluster=kafka-dc1,strimzi.io/pool-name=dual-role --timeout=600s >/dev/null
    ;;
  postgres-primary-kill)
    sleep 5
    k -n "$DC1" wait --for=condition=Ready cluster.postgresql.cnpg.io/pg-dc1 --timeout=600s >/dev/null
    ;;
  dc-partition|cross-dc-latency)
    dur=$(grep -E '^\s*duration:' "$EXP" | head -1 | sed -E 's/.*"?([0-9]+)m"?.*/\1/')
    sleep $(( ${dur:-3} * 60 ))
    ;;
esac
T_REC=$(date +%s)
primary_after=$(k -n "$DC1" get cluster.postgresql.cnpg.io pg-dc1 -o jsonpath='{.status.currentPrimary}' 2>/dev/null)
k delete -f "$EXP" --ignore-not-found >/dev/null 2>&1
log "fault cleared / recovered after $((T_REC - T0))s; letting traffic finish"
k -n "$DC1" wait --for=jsonpath='{.status.phase}'=Succeeded "pod/$TPOD" --timeout=$((OBSERVE + 180))s >/dev/null 2>&1
T_END=$(date +%s)

# ---- 3. analyse ---------------------------------------------------------------------
LOGS=$(k -n "$DC1" logs "$TPOD" 2>/dev/null | grep '^T ')
summary=$(echo "$LOGS" | awk -v t0="$T0" -v tr="$T_REC" '
  { ph = ($2 < t0) ? "before" : (($2 <= tr) ? "during" : "after"); n[ph]++; if ($4 == 200) ok[ph]++;
    if ($4 != 200) { if (!run) start = $2; run++; if (run > maxrun) { maxrun = run; ws = start; we = $2 } } else run = 0 }
  END {
    for (p in n) printf "%s %d/%d\n", p, ok[p], n[p];
    printf "maxerr %d %d %d\n", maxrun, ws, we }')
succ() { echo "$summary" | awk -v p="$1" '$1==p{print $2}'; }
maxerr=$(echo "$summary" | awk '$1=="maxerr"{print $2}')
errwin=$(echo "$summary" | awk '$1=="maxerr"{ if ($2>0) print $4-$3+2; else print 0 }')
total_ok=$(echo "$LOGS" | awk '$4==200' | wc -l | tr -d ' ')

# Eventual consistency: every accepted order of this run must show up downstream.
PG_PRIMARY=$(k -n "$DC1" get cluster.postgresql.cnpg.io pg-dc1 -o jsonpath='{.status.currentPrimary}')
in_pg=$(k -n "$DC1" exec "$PG_PRIMARY" -c postgres -- psql -d orderservice -tAc \
  "select count(*) from orders where order_desc like '$RUN-%'" 2>/dev/null | tr -d ' ')
in_topic=$(k -n "$DC1" exec kafka-dc1-dual-role-0 -c kafka -- /opt/kafka/bin/kafka-console-consumer.sh \
  --bootstrap-server kafka-dc1-kafka-bootstrap:9092 --topic dborder.public.orders --from-beginning \
  --timeout-ms 30000 2>/dev/null | grep -o "\"order_desc\":\"$RUN-[0-9]*\"" | sort -u | wc -l | tr -d ' ')
in_mongo="n/a"
if k -n "$DC2" get mongodbcommunity mongo-dc2 >/dev/null 2>&1; then
  MPW=$(k -n "$DC2" get secret mongo-dc2-analytics-password -o jsonpath='{.data.password}' | base64 -d)
  for _ in $(seq 1 36); do   # up to 3 min for MirrorMaker 2 + sink to catch up
    in_mongo=$(k -n "$DC2" exec mongo-dc2-0 -c mongod -- mongosh --quiet \
      "mongodb://analytics:$MPW@localhost:27017/admin?directConnection=true" \
      --eval "db.getSiblingDB('analytics').orders.countDocuments({order_desc: {\$regex: '^$RUN-'}})" 2>/dev/null | tr -d ' ')
    [ "${in_mongo:-0}" -ge "${in_pg:-0}" ] 2>/dev/null && break
    sleep 5
  done
fi

# Kafka lag / MirrorMaker 2 latency peaks during the run (if Prometheus is installed).
lag_peak="n/a"; mm2_peak="n/a"
if k -n monitoring get svc kps-prometheus >/dev/null 2>&1; then
  k -n monitoring port-forward svc/kps-prometheus 19091:9090 >/dev/null 2>&1 & PF_PID=$!
  sleep 3
  win=$((T_END - T0 + 60))
  q() { curl -s http://localhost:19091/api/v1/query --data-urlencode "query=$1" \
        | python3 -c 'import sys,json;r=json.load(sys.stdin)["data"]["result"];print(round(float(r[0]["value"][1]),1) if r else "n/a")'; }
  lag_peak=$(q "max_over_time(sum(kafka_consumergroup_lag{namespace=~\"$DC1|$DC2\"})[${win}s:15s])")
  mm2_peak=$(q "max_over_time(max(kafka_connect_mirror_source_connector_replication_latency_ms_max)[${win}s:15s])")
fi

cat <<REPORT

==================== chaos report: $SCENARIO ====================
run id                         $RUN
fault injected -> recovered    $((T_REC - T0)) s
order requests OK  before      $(succ before)
                   during      $(succ during)
                   after       $(succ after)
longest error streak           ${maxerr:-0} requests (~${errwin:-0} s)
PostgreSQL primary             ${primary_before:-?} -> ${primary_after:-?}
accepted orders (HTTP 200)     $total_ok
  rows in DC1 PostgreSQL       ${in_pg:-?}
  events on dborder.public.orders ${in_topic:-?}
  documents in DC2 MongoDB     ${in_mongo}
peak Kafka consumer lag        $lag_peak messages
peak MirrorMaker 2 latency     $mm2_peak ms
================================================================
Grafana: "Platform: services, databases, Kafka", "Strimzi Kafka Exporter",
"Strimzi Kafka Mirror Maker 2", "CloudNativePG" (time range covering this run).
REPORT
