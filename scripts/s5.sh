#!/usr/bin/env bash
# S5: delete the Service entirely (a managed resource goes missing).
# Usage: scripts/s5.sh <off|on>
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
source scripts/lib.sh
require_variant "${1:-}"
ns="$(variant_to_ns "$1")"

echo "+ kubectl -n ${ns} delete svc driftapp"
kubectl -n "${ns}" delete svc driftapp
