#!/usr/bin/env bash
# Phase 6 checks: metrics (Prometheus targets and key series), dashboards (Grafana),
# logs (Fluent Bit -> Elasticsearch), uptime/alerting (Icinga, Prometheus rules).
set -uo pipefail

CTX=${KUBE_CONTEXT:-k3d-multidc}
MON=monitoring
LOG=logging
DC1=dc1-core
DC2=dc2-analytics
SECRETS_DIR=${SECRETS_DIR:-$(cd "$(dirname "$0")/.." && pwd)/ansible/.secrets}

k() { kubectl --context "$CTX" "$@"; }
fail=0
check() { if [ "$2" = "$3" ]; then echo "PASS  $1"; else echo "FAIL  $1 (expected '$2', got '$3')"; fail=1; fi; }
ok() { local d=$1; shift; if "$@" >/dev/null 2>&1; then echo "PASS  $d"; else echo "FAIL  $d"; fail=1; fi; }
PF_PIDS=()
cleanup() { for p in "${PF_PIDS[@]:-}"; do [ -n "$p" ] && kill "$p" 2>/dev/null; done; }
trap cleanup EXIT
port_forward() { # <ns> <svc> <local:remote>
  k -n "$1" port-forward "svc/$2" "$3" >/dev/null 2>&1 & PF_PIDS+=($!)
  for _ in $(seq 1 20); do curl -s -o /dev/null "http://localhost:${3%%:*}" && return; sleep 1; done
}
ds_complete() { # <ns> <daemonset> -> "N/N" when every scheduled pod is ready
  k -n "$1" get ds "$2" -o jsonpath='{.status.numberReady}/{.status.desiredNumberScheduled}'
}
nodes=$(k get nodes --no-headers | wc -l | tr -d ' ')
dc2=$(k get ns "$DC2" -o name 2>/dev/null && k -n "$DC2" get cluster.postgresql.cnpg.io pg-dc2 -o name 2>/dev/null)

echo "== Workloads"
ok "monitoring Deployments Available (operator, Grafana, kube-state-metrics)" \
  k -n "$MON" wait --for=condition=Available deploy --all --timeout=600s
ok "Prometheus ready" k -n "$MON" rollout status statefulset/prometheus-kps-prometheus --timeout=600s
ok "Alertmanager ready" k -n "$MON" rollout status statefulset/alertmanager-kps-alertmanager --timeout=300s
check "node-exporter on every node" "$nodes/$nodes" "$(ds_complete "$MON" kps-prometheus-node-exporter)"
check "Fluent Bit on every node" "$nodes/$nodes" "$(ds_complete "$LOG" fluent-bit)"
ok "logging Elasticsearch es-logs green" k -n "$LOG" wait --for=jsonpath='{.status.health}'=green elasticsearch/es-logs --timeout=600s
ok "Kibana green" k -n "$LOG" wait --for=jsonpath='{.status.health}'=green kibana/kibana --timeout=600s
ok "pg-monitoring Ready" k -n "$MON" wait --for=condition=Ready cluster.postgresql.cnpg.io/pg-monitoring --timeout=600s
ok "Icinga 2 ready" k -n "$MON" rollout status statefulset/icinga-icinga2 --timeout=600s
for d in icinga-valkey icinga-icingadb icinga-icingaweb2; do ok "$d ready" k -n "$MON" rollout status "deploy/$d" --timeout=300s; done

echo "== Prometheus targets and series"
port_forward "$MON" kps-prometheus 19090:9090
targets=$(curl -s "http://localhost:19090/api/v1/targets?state=active")
pool_up() { # <scrape pool substring> -> "up/total"
  echo "$targets" | python3 -c '
import sys,json
t=[x for x in json.load(sys.stdin)["data"]["activeTargets"] if sys.argv[1] in x["scrapePool"]]
print("%d/%d" % (sum(x["health"]=="up" for x in t), len(t)))' "$1"
}
expect_pools="spring-services strimzi-kafka-resources strimzi-cluster-operator cnpg-clusters keycloak apisix node-exporter kube-state-metrics"
[ -n "$(k -n "$DC1" get cassandradatacenter -o name 2>/dev/null)" ] && expect_pools="$expect_pools cassandra"
[ -n "$dc2" ] && expect_pools="$expect_pools rabbitmq elasticsearch-exporter mongodb-exporter"
for p in $expect_pools; do
  r=$(pool_up "$p")
  check "scrape pool *$p* has targets, all up" yes "$( [ "${r%%/*}" = "${r##*/}" ] && [ "${r##*/}" -gt 0 ] && echo yes || echo "no ($r)")"
done
series() { curl -s "http://localhost:19090/api/v1/query" --data-urlencode "query=count($1)" | python3 -c 'import sys,json;r=json.load(sys.stdin)["data"]["result"];print(r[0]["value"][1] if r else 0)'; }
for m in http_server_requests_seconds_bucket hikaricp_connections_active cnpg_backends_total kafka_consumergroup_lag apisix_http_latency_bucket; do
  check "series present: $m" yes "$( [ "$(series "$m")" != 0 ] && echo yes || echo no)"
done
check "platform alert rules loaded" yes \
  "$(curl -s http://localhost:19090/api/v1/rules | grep -q '"name":"platform.kafka"' && echo yes || echo no)"

echo "== Grafana dashboards"
port_forward "$MON" kps-grafana 13000:80
GPW=$(cat "$SECRETS_DIR/grafana_admin" 2>/dev/null)
n=$(curl -s -u "admin:$GPW" "http://localhost:13000/api/search?type=dash-db&folderTitle=Platform" | python3 -c 'import sys,json;print(len(json.load(sys.stdin)))' 2>/dev/null)
check "Platform folder holds the 8 provisioned dashboards" yes "$( [ "${n:-0}" -ge 8 ] && echo yes || echo "no (${n:-0})")"

echo "== Logs (Fluent Bit -> es-logs)"
ES_PW=$(k -n "$LOG" get secret es-logs-es-elastic-user -o jsonpath='{.data.elastic}' | base64 -d)
count_logs() {
  k -n "$LOG" exec es-logs-es-default-0 -c elasticsearch -- curl -s -u "elastic:$ES_PW" \
    "localhost:9200/k8s-*/_count?q=kubernetes.namespace_name:$1" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("count",0))'
}
check "log documents from $DC1" yes "$( [ "$(count_logs "$DC1")" -gt 0 ] && echo yes || echo no)"
[ -n "$dc2" ] && check "log documents from $DC2" yes "$( [ "$(count_logs "$DC2")" -gt 0 ] && echo yes || echo no)"

echo "== Icinga (API on the master)"
IPW=$(k -n "$MON" get secret icinga-api -o jsonpath='{.data.root}' | base64 -d)
icinga() { k -n "$MON" exec icinga-icinga2-0 -c icinga2 -- curl -sk -u "root:$IPW" -H 'Accept: application/json' "https://localhost:5665/v1/objects/$1?attrs=name&attrs=state&attrs=last_check_result"; }
hosts=$(icinga hosts | python3 -c '
import sys,json
r=json.load(sys.stdin)["results"]; up=[h["attrs"]["name"] for h in r if h["attrs"]["state"]==0]
print("%d/%d %s" % (len(up), len(r), ",".join(sorted(h["attrs"]["name"] for h in r if h["attrs"]["state"]!=0))))')
echo "      hosts up: $hosts"
check "all Icinga hosts UP" yes "$( [ "$(echo "$hosts" | cut -d' ' -f1 | cut -d/ -f1)" = "$(echo "$hosts" | cut -d' ' -f1 | cut -d/ -f2)" ] && echo yes || echo no)"
svcs=$(icinga services | python3 -c '
import sys,json
r=json.load(sys.stdin)["results"]; print("%d/%d" % (sum(s["attrs"]["state"]==0 for s in r), len(r)))')
check "all Icinga services OK" yes "$( [ "${svcs%%/*}" = "${svcs##*/}" ] && echo yes || echo "no ($svcs)")"

[ "$fail" -eq 0 ] && echo "All Phase 6 checks passed." || echo "Some Phase 6 checks FAILED."
exit "$fail"
