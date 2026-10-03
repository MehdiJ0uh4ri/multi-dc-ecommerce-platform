#!/usr/bin/env bash
# Phase 3 checks: DC1 app layer up, gateway reachable from the host, and one order
# end to end: token (Keycloak) -> APISIX -> order-service -> PostgreSQL -> Debezium -> Kafka.
# Creates short-lived pods labelled test=phase3 and removes them on exit.
set -uo pipefail

CTX=${KUBE_CONTEXT:-k3d-multidc}
NS=dc1-core
DC1_NODE=${DC1_NODE:-k3d-multidc-agent-0}
GATEWAY_URL=${GATEWAY_URL:-http://localhost:8080}
CURL_IMAGE=curlimages/curl:8.22.0

k() { kubectl --context "$CTX" "$@"; }
fail=0
check() { if [ "$2" = "$3" ]; then echo "PASS  $1"; else echo "FAIL  $1 (expected '$2', got '$3')"; fail=1; fi; }
ok() { local d=$1; shift; if "$@" >/dev/null 2>&1; then echo "PASS  $d"; else echo "FAIL  $d"; fail=1; fi; }
cleanup() { k -n "$NS" delete pod -l test=phase3 --ignore-not-found --wait=false >/dev/null 2>&1; }
wait_done() {
  for _ in $(seq 1 90); do
    p=$(k -n "$1" get pod "$2" -o jsonpath='{.status.phase}' 2>/dev/null)
    case $p in Succeeded|Failed) echo "$p"; return ;; esac
    sleep 2
  done
  echo Timeout
}

trap cleanup EXIT
cleanup
k -n "$NS" wait --for=delete pod -l test=phase3 --timeout=60s >/dev/null 2>&1

echo "== Workloads ($NS)"
ok "keycloak ready" k -n "$NS" rollout status statefulset/keycloak --timeout=600s
# Only the services this profile deployed (charts/spring-service labels them part-of=ecommerce).
SERVICES=$(k -n "$NS" get deploy -l app.kubernetes.io/part-of=ecommerce -o jsonpath='{.items[*].metadata.name}')
for s in $SERVICES; do ok "$s ready" k -n "$NS" rollout status "deploy/$s" --timeout=600s; done
ok "apisix ready" k -n "$NS" rollout status deploy/apisix --timeout=300s
cdc=$(k -n "$NS" get kafkaconnect connect-dc1 -o name 2>/dev/null)
if [ -n "$cdc" ]; then
  ok "KafkaConnect connect-dc1 Ready (first build pushes to registry.localhost:5000)" \
    k -n "$NS" wait --for=condition=Ready kafkaconnect/connect-dc1 --timeout=900s
  ok "KafkaConnector orders-cdc Ready" k -n "$NS" wait --for=condition=Ready kafkaconnector/orders-cdc --timeout=300s
else
  echo "SKIP  Kafka Connect disabled (enable_cdc=false)"
fi

echo "== Pinning"
check "all running dc1-core pods on $DC1_NODE" "$DC1_NODE" \
  "$(k -n "$NS" get pods --field-selector=status.phase=Running -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' | sort -u | tr '\n' ' ' | sed 's/ $//')"

echo "== Gateway from the host ($GATEWAY_URL: k3d LB -> DC1 node -> kube-proxy (Local) -> NetworkPolicy ipBlock -> APISIX)"
check "GET /api/orders without token is 401" 401 "$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "$GATEWAY_URL/api/orders")"

echo "== End-to-end order"
TAG="phase3-smoke-$(date +%s)"
read -r -d '' E2E <<'EOF'
# kube-router programs NetworkPolicy for a new pod asynchronously: its first connection
# can fail (HTTP 000) before the pod is admitted by allow-same-namespace. Retry it.
TOKEN=$(curl -sf --max-time 60 --retry 5 --retry-all-errors --retry-delay 2 \
  -d grant_type=password -d client_id=ecommerce-client -d username=testuser -d password=testpass \
  http://keycloak:8080/realms/ecommerce/protocol/openid-connect/token \
  | sed -n 's/.*"access_token":"\([^"]*\)".*/\1/p')
[ -n "$TOKEN" ] || { echo "TOKEN_FAILED"; exit 1; }
echo "TOKEN_OK"
# order-service dereferences cart.cartId, so an order needs an existing cart.
CART_ID=$(curl -s --max-time 60 -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"userId":1}' http://apisix-gateway/api/carts | sed -n 's/.*"cartId":\([0-9]*\).*/\1/p')
echo "CART_ID=$CART_ID"
curl -s --max-time 60 -o /tmp/body -w 'HTTP_STATUS=%{http_code}\n' \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d "{\"orderDesc\":\"$TAG\",\"orderFee\":42.5,\"productId\":1,\"cart\":{\"cartId\":$CART_ID}}" \
  http://apisix-gateway/api/orders
echo "BODY=$(cat /tmp/body)"
EOF
k -n "$NS" run e2e-order --image="$CURL_IMAGE" --restart=Never --labels=test=phase3 --env="TAG=$TAG" \
  --command -- sh -c "$E2E" >/dev/null
wait_done "$NS" e2e-order >/dev/null
OUT=$(k -n "$NS" logs e2e-order 2>/dev/null)
check "password grant for testuser returns a token" TOKEN_OK "$(echo "$OUT" | grep -m1 -oE 'TOKEN_OK|TOKEN_FAILED')"
check "POST /api/carts via APISIX returns a cartId" yes "$(echo "$OUT" | grep -qE '^CART_ID=[0-9]+$' && echo yes || echo no)"
check "POST /api/orders via APISIX returns 200" "HTTP_STATUS=200" "$(echo "$OUT" | grep -m1 -oE 'HTTP_STATUS=[0-9]+')"
echo "      $(echo "$OUT" | grep -m1 '^BODY=' | cut -c1-200)"

check "order row in orderservice.orders" 1 \
  "$(k -n "$NS" exec pg-dc1-1 -c postgres -- psql -d orderservice -tAc "select count(*) from orders where order_desc='$TAG'" 2>/dev/null)"

if [ -n "$cdc" ]; then
  EVENT=$(k -n "$NS" exec kafka-dc1-dual-role-0 -c kafka -- /opt/kafka/bin/kafka-console-consumer.sh \
    --bootstrap-server kafka-dc1-kafka-bootstrap:9092 --topic dborder.public.orders \
    --from-beginning --timeout-ms 30000 2>/dev/null | grep -m1 "$TAG")
  check "Debezium create event on dborder.public.orders" '"op":"c"' "$(echo "$EVENT" | grep -oE '"op":"c"' | head -1)"
fi

[ "$fail" -eq 0 ] && echo "All Phase 3 checks passed." || echo "Some Phase 3 checks FAILED."
exit "$fail"
