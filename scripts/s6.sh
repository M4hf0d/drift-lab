#!/usr/bin/env bash
# S6: create an extra resource that was never in Git. Argo's default
# diff is "does every Git-declared resource match live state" -- it does
# not scan the namespace for unmanaged extras, so this should be
# invisible to Argo regardless of selfHeal.
# Usage: scripts/s6.sh <off|on>
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
source scripts/lib.sh
require_variant "${1:-}"
ns="$(variant_to_ns "$1")"

echo "+ kubectl -n ${ns} create configmap extra-not-in-git --from-literal=note=unmanaged"
kubectl -n "${ns}" create configmap extra-not-in-git --from-literal=note=unmanaged
