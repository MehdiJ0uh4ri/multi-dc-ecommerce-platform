#!/usr/bin/env bash
# Phase 4.5 checks: data-tools image, seed-products, seed-orders (Olist replay), loadgen
# traffic with its fraud patterns, the order-context and SUCCESSFUL topics in DC1 and,
# when DC2 is deployed, their mirrors and the seeded catalogue in MongoDB.
#
# Tunables: VERIFY_MIN_PRODUCTS (194), VERIFY_WAIT_SEED_ORDERS=1 waits for the whole
# replay (tens of minutes), VERIFY_FRAUD_WAIT_S (600) to observe every fraud pattern.
set -uo pipefail

CTX=${KUBE_CONTEXT:-k3d-multidc}
DC1=dc1-core
DC2=dc2-analytics
DC1_NODE=${DC1_NODE:-k3d-multidc-agent-0}
GATEWAY_URL=${GATEWAY_URL:-http://localhost:8080}
REGISTRY_URL=${REGISTRY_URL:-http://localhost:5000}
MIN_PRODUCTS=${VERIFY_MIN_PRODUCTS:-194}
FRAUD_WAIT_S=${VERIFY_FRAUD_WAIT_S:-600}
VERSION=$(cat "$(dirname "$0")/../data-tools/VERSION")
KAFKA1="kafka-dc1-dual-role-0"
KAFKA2="kafka-dc2-dual-role-0"

k() { kubectl --context "$CTX" "$@"; }
fail=0
check() { if [ "$2" = "$3" ]; then echo "PASS  $1"; else echo "FAIL  $1 (expected '$2', got '$3')"; fail=1; fi; }
ok() { local d=$1; shift; if "$@" >/dev/null 2>&1; then echo "PASS  $d"; else echo "FAIL  $d"; fail=1; fi; }
# at_least <description> <minimum> <value>
at_least() {
  if awk -v v="$3" -v m="$2" 'BEGIN{exit !(v+0 >= m+0)}' 2>/dev/null; then echo "PASS  $1 ($3 >= $2)"
  else echo "FAIL  $1 (got '$3', need >= $2)"; fail=1; fi
}
# newest Job with a given app name
job_of() { k -n "$DC1" get job -l "app.kubernetes.io/name=$1" --sort-by=.metadata.creationTimestamp -o name 2>/dev/null | tail -1; }
summary_field() { sed -n "s/.*SUMMARY.*[ ]$1=\([0-9]*\).*/\1/p" | tail -1; }
count_json_list() { python3 -c 'import json,sys; print(len(json.load(sys.stdin)))' 2>/dev/null || echo 0; }
# metric <regex>: sum of matching loadgen samples, read inside the loadgen pod
metric() {
  k -n "$DC1" exec deploy/loadgen -c loadgen -- python -c '
import re, sys, urllib.request
text = urllib.request.urlopen("http://localhost:9000/metrics", timeout=10).read().decode()
print(sum(float(l.rsplit(" ", 1)[1]) for l in text.splitlines()
          if not l.startswith("#") and re.search(sys.argv[1], l)))' "$1" 2>/dev/null || echo 0
}
# topic_count <ns> <pod> <topic> [max]: messages readable from the beginning (capped).
# Bootstrap Service = pod name minus "-dual-role-0" plus "-kafka-bootstrap" (as in verify-phase4).
topic_count() {
  k -n "$1" exec "$2" -c kafka -- /opt/kafka/bin/kafka-console-consumer.sh \
    --bootstrap-server "${2%-dual-role-0}-kafka-bootstrap:9092" --topic "$3" --from-beginning --max-messages "${4:-50}" \
    --timeout-ms 20000 2>/dev/null | wc -l | tr -d ' '
}
dc2_deployed() { k -n "$DC2" get pod "$KAFKA2" >/dev/null 2>&1; }

echo "== Image"
check "registry has platform/data-tools:$VERSION (make data-tools-image)" yes \
  "$(curl -s --max-time 10 "$REGISTRY_URL/v2/platform/data-tools/tags/list" | grep -q "\"$VERSION\"" && echo yes || echo no)"

echo "== seed-products (DummyJSON -> APISIX -> product-service)"
SP=$(job_of seed-products)
if [ -z "$SP" ]; then
  echo "FAIL  no seed-products Job (enable_data_tools=false?)"; fail=1
else
  ok "$SP complete" k -n "$DC1" wait --for=condition=complete "$SP" --timeout=1200s
  SP_LOG=$(k -n "$DC1" logs "$SP" -c seed-products 2>/dev/null)
  check "seed-products reported no failed product" 0 "$(echo "$SP_LOG" | summary_field products_failed)"
  at_least "products in product-service (Job summary)" "$MIN_PRODUCTS" "$(echo "$SP_LOG" | summary_field products_total)"
fi
at_least "GET $GATEWAY_URL/api/products (external path through APISIX)" "$MIN_PRODUCTS" \
  "$(curl -s --max-time 30 "$GATEWAY_URL/api/products" | count_json_list)"
check "root category 'All' exists (init container, upstream finding #11)" yes \
  "$(curl -s --max-time 30 "$GATEWAY_URL/api/categories" | grep -q '"categoryTitle":"All"' && echo yes || echo no)"

if dc2_deployed; then
  MONGO_PW=$(k -n "$DC2" get secret mongo-dc2-analytics-password -o jsonpath='{.data.password}' | base64 -d)
  mongo_count() {
    k -n "$DC2" exec mongo-dc2-0 -c mongod -- mongosh --quiet \
      "mongodb://analytics:$MONGO_PW@localhost:27017/admin?directConnection=true" \
      --eval "db.getSiblingDB('analytics').$1.countDocuments($2)" 2>/dev/null | tr -d '[:space:]'
  }
  at_least "seeded products reached DC2 MongoDB analytics.products (CDC -> MirrorMaker 2 -> sink)" \
    "$MIN_PRODUCTS" "$(mongo_count products '{}')"
else
  echo "SKIP  DC2 checks (dc2-analytics not deployed)"
fi

echo "== seed-orders (Olist replay)"
SO=$(job_of seed-orders)
if [ -z "$SO" ]; then
  echo "SKIP  no seed-orders Job (no data-tools/data/olist-replay.jsonl.gz, or enable_seed_orders=false)"
else
  if [ "${VERIFY_WAIT_SEED_ORDERS:-0}" = 1 ]; then
    ok "$SO complete" k -n "$DC1" wait --for=condition=complete "$SO" --timeout=10800s
  fi
  check "$SO has not failed" "" "$(k -n "$DC1" get "$SO" -o jsonpath='{.status.conditions[?(@.type=="Failed")].status}')"
  SO_LOG=$(k -n "$DC1" logs "$SO" -c seed-orders --tail=200 2>/dev/null)
  replayed=$(echo "$SO_LOG" | sed -n 's/.*replayed=\([0-9]*\).*/\1/p' | tail -1)
  if [ -z "$replayed" ]; then replayed=$(echo "$SO_LOG" | summary_field orders_replayed); fi
  at_least "Olist orders replayed so far (PROGRESS every 100 submissions)" 1 "${replayed:-0}"
  if dc2_deployed; then
    at_least "replayed orders in DC2 MongoDB analytics.orders (order_desc olist:*)" 1 \
      "$(mongo_count orders "{order_desc: /^olist:/}")"
  fi
fi

echo "== loadgen"
if ! k -n "$DC1" get deploy/loadgen >/dev/null 2>&1; then
  echo "SKIP  no loadgen Deployment (enable_loadgen=false or auth/order/payment-service not deployed)"
else
  ok "loadgen rollout complete" k -n "$DC1" rollout status deploy/loadgen --timeout=300s
  first=$(metric 'loadgen_orders_total\{.*result="ok"')
  sleep 60
  second=$(metric 'loadgen_orders_total\{.*result="ok"')
  check "successful orders keep increasing over 60 s ($first -> $second)" yes \
    "$(awk -v a="$first" -v b="$second" 'BEGIN{print (b > a) ? "yes" : "no"}')"
  for pattern in rapid_repeat geo_mismatch high_value_new_account; do
    seen=0
    for _ in $(seq 1 $((FRAUD_WAIT_S / 15))); do
      seen=$(metric "loadgen_orders_total\\{.*result=\"ok\".*scenario=\"$pattern\"|loadgen_orders_total\\{.*scenario=\"$pattern\".*result=\"ok\"")
      awk -v v="$seen" 'BEGIN{exit !(v > 0)}' && break
      sleep 15
    done
    at_least "fraud pattern $pattern produced orders" 1 "$seen"
  done
  total=$(metric 'loadgen_http_requests_total\{')
  limited=$(metric 'loadgen_http_requests_total\{.*code="429"')
  errors=$(metric 'loadgen_orders_total\{.*result="error"')
  orders=$(metric 'loadgen_orders_total\{')
  check "APISIX rate limit (429) < 1% of loadgen requests ($limited / $total)" yes \
    "$(awk -v l="$limited" -v t="$total" 'BEGIN{print (t > 0 && l / t < 0.01) ? "yes" : "no"}')"
  check "failed orders < 5% ($errors / $orders)" yes \
    "$(awk -v e="$errors" -v o="$orders" 'BEGIN{print (o > 0 && e / o < 0.05) ? "yes" : "no"}')"
fi

echo "== Kafka (DC1)"
if k -n "$DC1" get pod "$KAFKA1" >/dev/null 2>&1; then
  at_least "payment events on SUCCESSFUL" 1 "$(topic_count "$DC1" "$KAFKA1" SUCCESSFUL 5)"
  CTX_SAMPLE=$(k -n "$DC1" exec "$KAFKA1" -c kafka -- /opt/kafka/bin/kafka-console-consumer.sh \
    --bootstrap-server kafka-dc1-kafka-bootstrap:9092 --topic order-context --from-beginning --max-messages 2000 \
    --timeout-ms 20000 --property print.headers=true 2>/dev/null)
  at_least "order-context events" 1 "$(echo "$CTX_SAMPLE" | grep -c '"orderId"')"
  mismatches=$(echo "$CTX_SAMPLE" | grep 'scenario:geo_mismatch' | python3 -c '
import json, sys
rows = [json.loads(l[l.index("{"):]) for l in sys.stdin if "{" in l]
print(sum(r["shippingCountry"] != r["billingCountry"] for r in rows) if rows else 0)')
  if k -n "$DC1" get deploy/loadgen >/dev/null 2>&1; then
    at_least "geo_mismatch events carry different shipping/billing countries" 1 "${mismatches:-0}"
  fi
else
  echo "SKIP  Kafka checks (enable_kafka=false)"
fi

if dc2_deployed; then
  echo "== MirrorMaker 2 (DC1 -> DC2)"
  at_least "order-context mirrored to kafka-dc2" 1 "$(topic_count "$DC2" "$KAFKA2" order-context 5)"
  at_least "SUCCESSFUL mirrored to kafka-dc2" 1 "$(topic_count "$DC2" "$KAFKA2" SUCCESSFUL 5)"
fi

echo "== Pinning"
nodes=$(k -n "$DC1" get pods -l app.kubernetes.io/part-of=data-tools -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' | sort -u | tr '\n' ' ' | sed 's/ $//')
check "data-tools pods on $DC1_NODE" "$DC1_NODE" "$nodes"

[ "$fail" -eq 0 ] && echo "All Phase 4.5 checks passed." || echo "Some Phase 4.5 checks FAILED."
exit "$fail"
