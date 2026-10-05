#!/usr/bin/env bash
# S9: modify a file inside the running container's writable layer. This
# is pure runtime state -- it never touches the Kubernetes API, so Argo
# has no possible way to see or heal it. Included as a negative control.
# Usage: scripts/s9.sh <off|on>
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
source scripts/lib.sh
require_variant "${1:-}"
ns="$(variant_to_ns "$1")"

pod="$(kubectl -n "${ns}" get pod -l app=driftapp -o jsonpath='{.items[0].metadata.name}')"
echo "+ kubectl -n ${ns} exec ${pod} -- sh -c 'echo DRIFTED-IN-CONTAINER > /tmp/runtime-drift.txt'"
kubectl -n "${ns}" exec "${pod}" -- sh -c 'echo DRIFTED-IN-CONTAINER > /tmp/runtime-drift.txt'

echo "verify (not part of the drift action, just confirming it landed):"
kubectl -n "${ns}" exec "${pod}" -- cat /tmp/runtime-drift.txt
