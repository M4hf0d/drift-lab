#!/usr/bin/env bash
# S2: change the image tag live (baseline: another tracked spec field).
# Usage: scripts/s2.sh <off|on>
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
source scripts/lib.sh
require_variant "${1:-}"
ns="$(variant_to_ns "$1")"

echo "+ kubectl -n ${ns} set image deployment/driftapp driftapp=driftapp:drifted"
kubectl -n "${ns}" set image deployment/driftapp driftapp=driftapp:drifted
