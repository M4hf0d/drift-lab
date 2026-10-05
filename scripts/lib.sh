#!/usr/bin/env bash
# Shared by every script in scripts/. Source it, don't run it directly.
#
# Usage in callers: pass "off" or "on" as the variant argument -- this
# maps to the matching Argo Application / namespace pair so the same
# scenario script works for both self-heal runs.

set -euo pipefail

# Consumed by callers that source this file (setup.sh); shellcheck can't see
# cross-file usage through `source`, hence the disables below.
# shellcheck disable=SC2034
CLUSTER_NAME="drift-lab"
# shellcheck disable=SC2034
IMAGE_NAME="driftapp:dev"
# shellcheck disable=SC2034
SECRET_VALUE="drift-lab-shared-secret"

variant_to_app() {
  case "$1" in
    off) echo "driftapp-selfheal-off" ;;
    on)  echo "driftapp-selfheal-on" ;;
    *) echo "unknown variant '$1' (expected 'off' or 'on')" >&2; exit 1 ;;
  esac
}

variant_to_ns() {
  case "$1" in
    off) echo "driftapp-off" ;;
    on)  echo "driftapp-on" ;;
    *) echo "unknown variant '$1' (expected 'off' or 'on')" >&2; exit 1 ;;
  esac
}

require_variant() {
  if [[ "${1:-}" != "off" && "${1:-}" != "on" ]]; then
    echo "usage: $0 <off|on> [...]" >&2
    exit 1
  fi
}

# Hits the app's ClusterIP Service from inside the cluster via a
# throwaway pod, since nothing is exposed outside kind by default.
# Prints the response body (or curl's error) and nothing else.
curl_app() {
  local ns="$1"
  kubectl run "curlprobe-$$" -n "${ns}" --rm -i --restart=Never \
    --image=curlimages/curl:8.10.1 --quiet -- \
    curl -s -m 5 "http://driftapp.${ns}.svc.cluster.local" 2>/dev/null || true
}

