#!/usr/bin/env bash
# Non-interactive Phase 2 checks: operators, DC1 data stores, pinning, network access.
# Creates short-lived probe pods labelled test=phase2 and removes them on exit.
set -uo pipefail

CTX=${KUBE_CONTEXT:-k3d-multidc}
NS=dc1-core
OPS=platform-operators
DC1_NODE=${DC1_NODE:-k3d-multidc-agent-0}
IMAGE=busybox:1.37

k() { kubectl --context "$CTX" "$@"; }
fail=0
check() { # desc expected actual
  if [ "$2" = "$3" ]; then echo "PASS  $1"; else echo "FAIL  $1 (expected '$2', got '$3')"; fail=1; fi
}
ok() { # desc command...
  local desc=$1; shift
  if "$@" >/dev/null 2>&1; then echo "PASS  $desc"; else echo "FAIL  $desc"; fail=1; fi
}
cleanup() {
  k -n "$NS" delete pod -l test=phase2 --ignore-not-found --wait=false >/dev/null 2>&1
  k -n dc2-analytics delete pod -l test=phase2 --ignore-not-found --wait=false >/dev/null 2>&1
}
wait_done() {
  for _ in $(seq 1 60); do
    p=$(k -n "$1" get pod "$2" -o jsonpath='{.status.phase}' 2>/dev/null)
    case $p in Succeeded|Failed) echo "$p"; return ;; esac
    sleep 2
  done
  echo Timeout
}
probe() { # ns name role(-|value) host port -> Succeeded (reached) | Failed (blocked)
  local labels="test=phase2"
  [ "$3" != "-" ] && labels="$labels,platform.local/role=$3"
  k -n "$1" run "$2" --image="$IMAGE" --restart=Never --labels="$labels" -- nc -z -w 3 "$4" "$5" >/dev/null
  wait_done "$1" "$2"
}

trap cleanup EXIT
cleanup
k -n "$NS" wait --for=delete pod -l test=phase2 --timeout=60s >/dev/null 2>&1
k -n dc2-analytics wait --for=delete pod -l test=phase2 --timeout=60s >/dev/null 2>&1

echo "== Operators ($OPS)"
ok "all operator deployments Available" k -n "$OPS" wait --for=condition=Available deploy --all --timeout=300s
k -n "$OPS" get deploy --no-headers | awk '{print "      " $1 " " $2}'

echo "== Data stores ready (this can take several minutes on first apply)"
ok "PostgreSQL cluster pg-dc1 Ready" k -n "$NS" wait --for=condition=Ready cluster.postgresql.cnpg.io/pg-dc1 --timeout=600s
ok "Kafka kafka-dc1 Ready" k -n "$NS" wait --for=condition=Ready kafka.kafka.strimzi.io/kafka-dc1 --timeout=600s
cassandra=$(k -n "$NS" get cassandradatacenter dc1 -o name 2>/dev/null)
if [ -n "$cassandra" ]; then
  ok "CassandraDatacenter dc1 Ready" k -n "$NS" wait --for=condition=Ready cassandradatacenter/dc1 --timeout=900s
else
  echo "SKIP  Cassandra disabled (enable_cassandra=false)"
fi

echo "== Pinning"
check "all dc1-core pods on $DC1_NODE" "$DC1_NODE" \
  "$(k -n "$NS" get pods --field-selector=status.phase=Running -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' | sort -u | tr '\n' ' ' | sed 's/ $//')"

echo "== PostgreSQL"
check "service databases exist" \
  "authservice,ecommerce,inventoryservice,keycloak,orderservice,paymentservice,productservice,shippingservice,taxservice" \
  "$(k -n "$NS" exec pg-dc1-1 -c postgres -- psql -tAc "select string_agg(datname, ',' order by datname) from pg_database where datname not in ('postgres','template0','template1')" 2>/dev/null)"
check "role label on postgres pod" postgres "$(k -n "$NS" get pod pg-dc1-1 -o jsonpath='{.metadata.labels.platform\.local/role}')"

echo "== Kafka"
KPOD=kafka-dc1-dual-role-0
BOOT=kafka-dc1-kafka-bootstrap:9092
MSG="phase2-$(date +%s)"
k -n "$NS" exec "$KPOD" -c kafka -- /opt/kafka/bin/kafka-topics.sh --bootstrap-server "$BOOT" \
  --create --if-not-exists --topic phase2-smoke --partitions 1 --replication-factor 1 >/dev/null 2>&1
k -n "$NS" exec "$KPOD" -c kafka -- sh -c "echo $MSG | /opt/kafka/bin/kafka-console-producer.sh --bootstrap-server $BOOT --topic phase2-smoke" >/dev/null 2>&1
check "produce + consume round trip" "$MSG" \
  "$(k -n "$NS" exec "$KPOD" -c kafka -- /opt/kafka/bin/kafka-console-consumer.sh --bootstrap-server "$BOOT" \
      --topic phase2-smoke --from-beginning --timeout-ms 15000 2>/dev/null | grep -x "$MSG")"
check "role label on kafka pod" kafka-broker "$(k -n "$NS" get pod "$KPOD" -o jsonpath='{.metadata.labels.platform\.local/role}')"

if [ -n "$cassandra" ]; then
  echo "== Cassandra"
  CPOD=$(k -n "$NS" get pod -l cassandra.datastax.com/datacenter=dc1 -o jsonpath='{.items[0].metadata.name}')
  CU=$(k -n "$NS" get secret cassandra-dc1-superuser -o jsonpath='{.data.username}' | base64 -d)
  CP=$(k -n "$NS" get secret cassandra-dc1-superuser -o jsonpath='{.data.password}' | base64 -d)
  check "cqlsh as superuser returns 4.1.9" 4.1.9 \
    "$(k -n "$NS" exec "$CPOD" -c cassandra -- cqlsh -u "$CU" -p "$CP" -e 'SELECT release_version FROM system.local' 2>/dev/null | grep -oE '4\.1\.[0-9]+' | head -1)"
  check "role label on cassandra pod" cassandra "$(k -n "$NS" get pod "$CPOD" -o jsonpath='{.metadata.labels.platform\.local/role}')"
fi

echo "== Network access into dc1-core"
check "dc1 same-namespace -> postgres 5432 reached" Succeeded "$(probe "$NS" same-ns-pg - pg-dc1-rw 5432)"
check "dc2 unlabelled -> kafka 9092 blocked" Failed "$(probe dc2-analytics no-role-kafka - kafka-dc1-kafka-bootstrap.dc1-core 9092)"
check "dc2 role=kafka-replicator -> kafka 9092 reached" Succeeded "$(probe dc2-analytics replicator-kafka kafka-replicator kafka-dc1-kafka-bootstrap.dc1-core 9092)"
check "dc2 role=kafka-replicator -> postgres 5432 blocked" Failed "$(probe dc2-analytics replicator-pg kafka-replicator pg-dc1-rw.dc1-core 5432)"

[ "$fail" -eq 0 ] && echo "All Phase 2 checks passed." || echo "Some Phase 2 checks FAILED."
exit "$fail"
