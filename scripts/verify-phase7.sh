#!/usr/bin/env bash
# Phase 7 readiness: Chaos Mesh installed and able to act on the DC nodes, DC namespaces
# opted in, and every experiment manifest accepted by the API server (server dry-run).
set -uo pipefail

CTX=${KUBE_CONTEXT:-k3d-multidc}
ROOT=$(cd "$(dirname "$0")/.." && pwd)

k() { kubectl --context "$CTX" "$@"; }
fail=0
check() { if [ "$2" = "$3" ]; then echo "PASS  $1"; else echo "FAIL  $1 (expected '$2', got '$3')"; fail=1; fi; }
ok() { local d=$1; shift; if "$@" >/dev/null 2>&1; then echo "PASS  $d"; else echo "FAIL  $d"; fail=1; fi; }

nodes=$(k get nodes --no-headers | wc -l | tr -d ' ')
echo "== Chaos Mesh"
ok "controller-manager and dashboard Available" k -n chaos-mesh wait --for=condition=Available deploy --all --timeout=300s
check "chaos-daemon on every node (incl. tainted DC nodes)" "$nodes/$nodes" \
  "$(k -n chaos-mesh get ds chaos-daemon -o jsonpath='{.status.numberReady}/{.status.desiredNumberScheduled}')"
for ns in dc1-core dc2-analytics; do
  check "$ns opted in (chaos-mesh.org/inject)" enabled \
    "$(k get ns "$ns" -o jsonpath='{.metadata.annotations.chaos-mesh\.org/inject}')"
done

echo "== Experiments (server dry-run)"
for f in "$ROOT"/chaos/experiments/*.yaml; do
  ok "$(basename "$f") accepted" k apply --dry-run=server -f "$f"
done

[ "$fail" -eq 0 ] && echo "All Phase 7 readiness checks passed. Run: make chaos-kafka | chaos-postgres | chaos-partition | chaos-latency" \
  || echo "Some Phase 7 checks FAILED."
exit "$fail"
