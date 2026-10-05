#!/usr/bin/env bash
# S4 (the strongest candidate for silent divergence): edit the ConfigMap
# live, then delete the pod so it restarts with the DRIFTED env var baked
# in. If/when Argo heals the ConfigMap back to Git afterward, Argo may
# report Synced while the already-running pod still serves the drifted
# greeting_env value until it restarts again.
# Usage: scripts/s4.sh <off|on>
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
source scripts/lib.sh
require_variant "${1:-}"
ns="$(variant_to_ns "$1")"

echo "+ kubectl -n ${ns} patch configmap driftapp-config --type merge -p '{\"data\":{\"greeting\":\"DRIFTED\"}}'"
kubectl -n "${ns}" patch configmap driftapp-config --type merge -p '{"data":{"greeting":"DRIFTED"}}'

echo "+ kubectl -n ${ns} delete pod -l app=driftapp"
kubectl -n "${ns}" delete pod -l app=driftapp
