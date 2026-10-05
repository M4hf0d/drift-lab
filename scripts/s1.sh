#!/usr/bin/env bash
# S1: scale replicas 1 -> 3 (baseline: a tracked spec field drifts).
# Usage: scripts/s1.sh <off|on>
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
source scripts/lib.sh
require_variant "${1:-}"
ns="$(variant_to_ns "$1")"

echo "+ kubectl -n ${ns} scale deployment/driftapp --replicas=3"
kubectl -n "${ns}" scale deployment/driftapp --replicas=3
