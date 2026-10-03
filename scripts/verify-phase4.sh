#!/usr/bin/env bash
# Phase 4 checks: DC2 operators and stores, MirrorMaker 2, sink connectors, DC2 services,
# one order followed from DC1 into the DC2 stores, and the cross-DC network paths.
# Creates short-lived pods labelled test=phase4 and removes them on exit.
set -uo pipefail

CTX=${KUBE_CONTEXT:-k3d-multidc}
DC1=dc1-core
DC2=dc2-analytics
OPS=platform-operators
DC2_NODE=${DC2_NODE:-k3d-multidc-agent-1}
GATEWAY_URL=${GATEWAY_URL:-http://localhost:8080}
BUSYBOX=busybox:1.37
CURL_IMAGE=curlimages/curl:8.22.0

k() { kubectl --context "$CTX" "$@"; }
fail=0
check() { if [ "$2" = "$3" ]; then echo "PASS  $1"; else echo "FAIL  $1 (expected '$2', got '$3')"; fail=1; fi; }
ok() { local d=$1; shift; if "$@" >/dev/null 2>&1; then echo "PASS  $d"; else echo "FAIL  $d"; fail=1; fi; }
cleanup() {
  for ns in "$DC1" "$DC2"; do k -n "$ns" delete pod -l test=phase4 --ignore-not-found --wait=false >/dev/null 2>&1; done
}
wait_done() {
  for _ in $(seq 1 90); do
    p=$(k -n "$1" get pod "$2" -o jsonpath='{.status.phase}' 2>/dev/null)
    case $p in Succeeded|Failed) echo "$p"; return ;; esac
    sleep 2
  done
  echo Timeout
}
# probe <ns> <name> <labels|-> <host> <port> -> Succeeded (reached) | Failed (blocked)
probe() {
  local labels="test=phase4"
  [ "$3" != "-" ] && labels="$labels,$3"
  k -n "$1" run "$2" --image="$BUSYBOX" --restart=Never --labels="$labels" -- \
    sh -c "sleep 3; nc -z -w 3 $4 $5" >/dev/null
  wait_done "$1" "$2"
}
# poll <seconds> <command...>: retry until the command prints a non-empty, non-zero value
poll() {
  local end=$((SECONDS + $1)); shift; local out=""
  while [ $SECONDS -lt $end ]; do
    out=$("$@" 2>/dev/null | tr -d '[:space:]')
    [ -n "$out" ] && [ "$out" != "0" ] && { echo "$out"; return; }
    sleep 5
  done
  echo "${out:-none}"
}

trap cleanup EXIT
cleanup
for ns in "$DC1" "$DC2"; do k -n "$ns" wait --for=delete pod -l test=phase4 --timeout=60s >/dev/null 2>&1; done

echo "== Operators"
ok "cert-manager Available" k -n cert-manager wait --for=condition=Available deploy --all --timeout=300s
ok "platform-operators Deployments Available" k -n "$OPS" wait --for=condition=Available deploy --all --timeout=300s
ok "ECK operator ready" k -n "$OPS" rollout status statefulset/elastic-operator --timeout=300s
ok "RabbitMQ Cluster + Topology Operators Available" k -n rabbitmq-system wait --for=condition=Available deploy --all --timeout=300s

echo "== DC2 data stores ($DC2)"
ok "PostgreSQL pg-dc2 Ready" k -n "$DC2" wait --for=condition=Ready cluster.postgresql.cnpg.io/pg-dc2 --timeout=600s
ok "Kafka kafka-dc2 Ready" k -n "$DC2" wait --for=condition=Ready kafka.kafka.strimzi.io/kafka-dc2 --timeout=600s
ok "MirrorMaker 2 mm2-dc1-to-dc2 Ready" k -n "$DC2" wait --for=condition=Ready kafkamirrormaker2/mm2-dc1-to-dc2 --timeout=600s
ok "KafkaConnect connect-dc2 Ready (first build pushes to registry.localhost:5000)" \
  k -n "$DC2" wait --for=condition=Ready kafkaconnect/connect-dc2 --timeout=1800s
for c in mongo-sink-orders mongo-sink-products rabbitmq-sink-payments; do
  ok "KafkaConnector $c Ready" k -n "$DC2" wait --for=condition=Ready "kafkaconnector/$c" --timeout=300s
done
ok "Elasticsearch es-dc2 health green" k -n "$DC2" wait --for=jsonpath='{.status.health}'=green elasticsearch/es-dc2 --timeout=600s
ok "MongoDB mongo-dc2 Running" k -n "$DC2" wait --for=jsonpath='{.status.phase}'=Running mongodbcommunity/mongo-dc2 --timeout=900s
ok "RabbitMQ rabbitmq-dc2 AllReplicasReady" k -n "$DC2" wait --for=condition=AllReplicasReady rabbitmqcluster/rabbitmq-dc2 --timeout=600s
for kind in exchanges.rabbitmq.com queues.rabbitmq.com bindings.rabbitmq.com; do
  ok "RabbitMQ topology $kind Ready" k -n "$DC2" wait --for=condition=Ready "$kind" --all --timeout=300s
done
ok "RustFS ready" k -n "$DC2" rollout status deploy/rustfs --timeout=300s
ok "Mailpit ready" k -n "$DC2" rollout status deploy/mailpit --timeout=300s

echo "== DC2 services"
for s in $(k -n "$DC2" get deploy -l app.kubernetes.io/part-of=ecommerce -o jsonpath='{.items[*].metadata.name}'); do
  ok "$s ready" k -n "$DC2" rollout status "deploy/$s" --timeout=900s
done

echo "== Pinning"
check "all running $DC2 pods on $DC2_NODE" "$DC2_NODE" \
  "$(k -n "$DC2" get pods --field-selector=status.phase=Running -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' | sort -u | tr '\n' ' ' | sed 's/ $//')"

echo "== DC1 change-data-capture"
for c in orders-cdc products-cdc; do
  ok "KafkaConnector $c Ready" k -n "$DC1" wait --for=condition=Ready "kafkaconnector/$c" --timeout=300s
done
cassandra_sink=$(k -n "$DC1" get kafkaconnector cassandra-sink-orders -o name 2>/dev/null)
[ -n "$cassandra_sink" ] && ok "KafkaConnector cassandra-sink-orders Ready" \
  k -n "$DC1" wait --for=condition=Ready kafkaconnector/cassandra-sink-orders --timeout=300s

echo "== One order: DC1 (APISIX -> order-service -> PostgreSQL -> Debezium) -> MirrorMaker 2 -> DC2 sinks"
TAG="phase4-$(date +%s)"
read -r -d '' E2E <<'EOF'
TOKEN=$(curl -sf --max-time 60 --retry 5 --retry-all-errors --retry-delay 2 \
  -d grant_type=password -d client_id=ecommerce-client -d username=testuser -d password=testpass \
  http://keycloak:8080/realms/ecommerce/protocol/openid-connect/token \
  | sed -n 's/.*"access_token":"\([^"]*\)".*/\1/p')
[ -n "$TOKEN" ] || { echo "TOKEN_FAILED"; exit 1; }
CART_ID=$(curl -s --max-time 60 -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"userId":1}' http://apisix-gateway/api/carts | sed -n 's/.*"cartId":\([0-9]*\).*/\1/p')
curl -s --max-time 60 -o /dev/null -w 'HTTP_STATUS=%{http_code}\n' \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d "{\"orderDesc\":\"$TAG\",\"orderFee\":42.5,\"productId\":1,\"cart\":{\"cartId\":$CART_ID}}" \
  http://apisix-gateway/api/orders
EOF
k -n "$DC1" run e2e-order-p4 --image="$CURL_IMAGE" --restart=Never --labels=test=phase4 --env="TAG=$TAG" \
  --command -- sh -c "$E2E" >/dev/null
wait_done "$DC1" e2e-order-p4 >/dev/null
check "POST /api/orders via APISIX returns 200" "HTTP_STATUS=200" \
  "$(k -n "$DC1" logs e2e-order-p4 2>/dev/null | grep -m1 -oE 'HTTP_STATUS=[0-9]+')"

consume() { # <ns> <kafka-pod> <bootstrap> <topic> -> first line containing $TAG
  k -n "$1" exec "$2" -c kafka -- /opt/kafka/bin/kafka-console-consumer.sh --bootstrap-server "$3" \
    --topic "$4" --from-beginning --timeout-ms 20000 2>/dev/null | grep -m1 "$TAG"
}
check "Debezium event on DC1 dborder.public.orders" yes \
  "$(consume "$DC1" kafka-dc1-dual-role-0 kafka-dc1-kafka-bootstrap:9092 dborder.public.orders | grep -q '"op":"c"' && echo yes || echo no)"
check "event mirrored to DC2 dborder.public.orders (MirrorMaker 2)" yes \
  "$(for _ in 1 2 3 4 5 6; do consume "$DC2" kafka-dc2-dual-role-0 kafka-dc2-kafka-bootstrap:9092 dborder.public.orders | grep -q "$TAG" && { echo yes; break; }; sleep 10; done || true)"

MONGO_PW=$(k -n "$DC2" get secret mongo-dc2-analytics-password -o jsonpath='{.data.password}' | base64 -d)
check "order document in MongoDB analytics.orders" 1 \
  "$(poll 90 k -n "$DC2" exec mongo-dc2-0 -c mongod -- mongosh --quiet \
      "mongodb://analytics:$MONGO_PW@localhost:27017/admin?directConnection=true" \
      --eval "db.getSiblingDB('analytics').orders.countDocuments({order_desc: '$TAG'})")"

if [ -n "$cassandra_sink" ]; then
  CPOD=$(k -n "$DC1" get pod -l cassandra.datastax.com/datacenter=dc1 -o jsonpath='{.items[0].metadata.name}')
  CU=$(k -n "$DC1" get secret cassandra-dc1-superuser -o jsonpath='{.data.username}' | base64 -d)
  CP=$(k -n "$DC1" get secret cassandra-dc1-superuser -o jsonpath='{.data.password}' | base64 -d)
  check "order row in Cassandra ecommerce.orders_by_id" 1 \
    "$(poll 90 sh -c "kubectl --context $CTX -n $DC1 exec $CPOD -c cassandra -- cqlsh -u '$CU' -p '$CP' -e \"SELECT count(*) FROM ecommerce.orders_by_id WHERE order_desc='$TAG' ALLOW FILTERING\" | grep -E '^ +[0-9]+' | tr -d ' '")"
else
  echo "SKIP  Cassandra sink (enable_cassandra=false)"
fi

echo "== Payment event: DC1 topic -> MirrorMaker 2 -> RabbitMQ exchange 'payments' -> queue payments.audit"
queue_depth() {
  k -n "$DC2" exec rabbitmq-dc2-server-0 -c rabbitmq -- rabbitmqctl list_queues -q name messages 2>/dev/null \
    | awk '$1=="payments.audit"{print $2}'
}
before=$(queue_depth); before=${before:-0}
k -n "$DC1" exec kafka-dc1-dual-role-0 -c kafka -- sh -c \
  "echo '{\"verify\":\"$TAG\"}' | /opt/kafka/bin/kafka-console-producer.sh --bootstrap-server kafka-dc1-kafka-bootstrap:9092 --topic SUCCESSFUL" >/dev/null 2>&1
after=$(poll 120 sh -c "d=\$(kubectl --context $CTX -n $DC2 exec rabbitmq-dc2-server-0 -c rabbitmq -- rabbitmqctl list_queues -q name messages 2>/dev/null | awk '\$1==\"payments.audit\"{print \$2}'); [ \"\${d:-0}\" -gt $before ] && echo \$d || echo 0")
check "payments.audit queue depth grew (was $before)" yes "$([ "${after:-0}" != none ] && [ "${after:-0}" -gt "$before" ] 2>/dev/null && echo yes || echo no)"

echo "== Elasticsearch and search"
ES_PW=$(k -n "$DC2" get secret es-dc2-es-elastic-user -o jsonpath='{.data.elastic}' | base64 -d)
check "Elasticsearch cluster health (elastic user)" green \
  "$(k -n "$DC2" exec es-dc2-es-default-0 -c elasticsearch -- curl -s -u "elastic:$ES_PW" localhost:9200/_cluster/health | grep -oE '"status":"[a-z]+"' | cut -d'"' -f4)"
echo "INFO  search indexing stops at search-service: it calls product-service /storefront/products-es/{id},"
echo "      which does not exist upstream (docs/upstream-app-findings.md #7)."

echo "== Cross-DC network paths"
check "dc2 search-service -> DC1 product-service :8086 reached" Succeeded \
  "$(probe "$DC2" p-search app.kubernetes.io/name=search-service product-service.dc1-core 8086)"
check "dc2 rating-service -> DC1 product-service :8086 blocked" Failed \
  "$(probe "$DC2" p-rating app.kubernetes.io/name=rating-service product-service.dc1-core 8086)"
check "dc2 api-service -> DC1 Keycloak :8080 reached" Succeeded \
  "$(probe "$DC2" p-kc platform.local/role=api-service keycloak.dc1-core 8080)"
check "dc2 unlabelled -> DC1 Kafka :9092 blocked" Failed \
  "$(probe "$DC2" p-kafka - kafka-dc1-kafka-bootstrap.dc1-core 9092)"
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 "$GATEWAY_URL/storefront/ratings/product/1")
check "APISIX (DC1) routes /storefront/ratings to rating-service in DC2 (no 502/503/504)" yes \
  "$(case $code in 502|503|504|000) echo "no ($code)";; *) echo yes;; esac)"

[ "$fail" -eq 0 ] && echo "All Phase 4 checks passed." || echo "Some Phase 4 checks FAILED."
exit "$fail"
