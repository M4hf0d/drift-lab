#!/usr/bin/env bash
# S3: edit the ConfigMap's data directly. The volume-mounted copy
# (greeting_file) should update in place within ~1min; the env-var copy
# (greeting_env) will NOT change until the pod restarts.
# Usage: scripts/s3.sh <off|on>
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
source scripts/lib.sh
require_variant "${1:-}"
ns="$(variant_to_ns "$1")"

echo "+ kubectl -n ${ns} patch configmap driftapp-config --type merge -p '{\"data\":{\"greeting\":\"DRIFTED\"}}'"
kubectl -n "${ns}" patch configmap driftapp-config --type merge -p '{"data":{"greeting":"DRIFTED"}}'
