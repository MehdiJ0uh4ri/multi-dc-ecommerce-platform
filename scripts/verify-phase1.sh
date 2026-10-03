#!/usr/bin/env bash
# Non-interactive Phase 1 checks: node taints, DC pinning, NetworkPolicy isolation.
# Creates short-lived pods labelled test=phase1 and removes them on exit.
set -uo pipefail

CTX=${KUBE_CONTEXT:-k3d-multidc}
DC1_NODE=${DC1_NODE:-k3d-multidc-agent-0}
DC2_NODE=${DC2_NODE:-k3d-multidc-agent-1}
IMAGE=busybox:1.37

k() { kubectl --context "$CTX" "$@"; }
fail=0
check() { # desc expected actual
  if [ "$2" = "$3" ]; then echo "PASS  $1"; else echo "FAIL  $1 (expected '$2', got '$3')"; fail=1; fi
}
cleanup() {
  k -n dc1-core delete pod,svc -l test=phase1 --ignore-not-found --wait=false >/dev/null 2>&1
  k -n dc2-analytics delete pod -l test=phase1 --ignore-not-found --wait=false >/dev/null 2>&1
}
wait_done() { # ns pod -> prints Succeeded | Failed | Timeout
  for _ in $(seq 1 60); do
    p=$(k -n "$1" get pod "$2" -o jsonpath='{.status.phase}' 2>/dev/null)
    case $p in Succeeded|Failed) echo "$p"; return ;; esac
    sleep 2
  done
  echo Timeout
}
probe() { # ns name role(-|value) url -> prints Succeeded (reached) | Failed (blocked)
  local labels="test=phase1"
  [ "$3" != "-" ] && labels="$labels,platform.local/role=$3"
  k -n "$1" run "$2" --image="$IMAGE" --restart=Never --labels="$labels" \
    -- wget -q -O /dev/null -T 3 "$4" >/dev/null
  wait_done "$1" "$2"
}

trap cleanup EXIT
cleanup
k -n dc1-core wait --for=delete pod -l test=phase1 --timeout=60s >/dev/null 2>&1
k -n dc2-analytics wait --for=delete pod -l test=phase1 --timeout=60s >/dev/null 2>&1

echo "== Node taints"
check "$DC1_NODE tainted dc1" dc1 "$(k get node "$DC1_NODE" -o jsonpath='{.spec.taints[?(@.key=="platform.local/dc")].value}')"
check "$DC2_NODE tainted dc2" dc2 "$(k get node "$DC2_NODE" -o jsonpath='{.spec.taints[?(@.key=="platform.local/dc")].value}')"

echo "== Pinning (PodNodeSelector + PodTolerationRestriction)"
k -n dc1-core run listener --image="$IMAGE" --restart=Never --labels=test=phase1,platform.local/role=keycloak \
  -- sh -c 'mkdir -p /www && echo ok > /www/index.html && httpd -f -p 8080 -h /www' >/dev/null
k -n dc1-core expose pod listener --port=8080 --labels=test=phase1 >/dev/null
k -n dc1-core wait --for=condition=Ready pod/listener --timeout=120s >/dev/null
check "dc1 pod scheduled on $DC1_NODE" "$DC1_NODE" "$(k -n dc1-core get pod listener -o jsonpath='{.spec.nodeName}')"
check "dc1 pod got default toleration" dc1 "$(k -n dc1-core get pod listener -o jsonpath='{.spec.tolerations[?(@.key=="platform.local/dc")].value}')"

URL=http://listener.dc1-core.svc.cluster.local:8080/
echo "== Isolation (target: dc1-core pod with role=keycloak, port 8080)"
check "dc1 same-namespace unlabelled -> reached" Succeeded "$(probe dc1-core same-ns - "$URL")"
r=$(probe dc2-analytics no-role - "$URL")
check "dc2 unlabelled -> blocked" Failed "$r"
check "dc2 probe scheduled on $DC2_NODE" "$DC2_NODE" "$(k -n dc2-analytics get pod no-role -o jsonpath='{.spec.nodeName}')"
check "dc2 role=kafka-replicator -> blocked" Failed "$(probe dc2-analytics wrong-role kafka-replicator "$URL")"
check "dc2 role=api-service -> reached" Succeeded "$(probe dc2-analytics api-service api-service "$URL")"

[ "$fail" -eq 0 ] && echo "All Phase 1 checks passed." || echo "Some Phase 1 checks FAILED."
exit "$fail"
