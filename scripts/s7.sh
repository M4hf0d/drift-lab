#!/usr/bin/env bash
# S7: add an annotation to a managed resource that Git never set. Tests
# whether Argo's diff treats "field present live but absent in Git" as
# drift, or ignores it (many controllers/webhooks inject annotations
# Argo is configured to ignore by default).
# Usage: scripts/s7.sh <off|on>
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
source scripts/lib.sh
require_variant "${1:-}"
ns="$(variant_to_ns "$1")"

echo "+ kubectl -n ${ns} annotate deployment/driftapp drift-lab.test/injected=true"
kubectl -n "${ns}" annotate deployment/driftapp drift-lab.test/injected=true
