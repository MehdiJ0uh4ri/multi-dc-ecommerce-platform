#!/usr/bin/env bash
# Report which CLI tools this project needs are present. Exit 1 if any are missing.
set -uo pipefail

missing=0
check() {
  local name=$1; shift
  if command -v "$name" >/dev/null 2>&1; then
    printf '  %-10s %s\n' "$name" "$("$@" 2>/dev/null | head -1)"
  else
    printf '  %-10s MISSING\n' "$name"
    missing=1
  fi
}

echo "Tooling:"
check git       git --version
check docker    docker --version
check ansible   ansible --version
check terraform terraform version
check helm      helm version --short
check kubectl   kubectl version --client
check k3d       k3d version

if [ "$missing" -ne 0 ]; then
  echo "Missing tools: run 'make tools' (ansible/playbooks/bootstrap-tools.yml)."
  exit 1
fi
