#!/usr/bin/env bash
# S8: change the out-of-Git Secret's value. Declared state ("app is
# healthy and correctly configured") partly depends on something Argo
# does not manage at all, since the Secret is never in deploy/.
# Usage: scripts/s8.sh <off|on>
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
source scripts/lib.sh
require_variant "${1:-}"
ns="$(variant_to_ns "$1")"

echo "+ kubectl -n ${ns} create secret generic driftapp-secret --from-literal=value=DRIFTED-SECRET --dry-run=client -o yaml | kubectl apply -f -"
kubectl -n "${ns}" create secret generic driftapp-secret \
  --from-literal=value=DRIFTED-SECRET \
  --dry-run=client -o yaml | kubectl apply -f -
