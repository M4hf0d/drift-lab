#!/usr/bin/env bash
# Returns a variant (off|on) to a clean, Synced, Healthy state and
# verifies it with a real curl against the running app -- not just
# Argo's own status fields.
#
# Usage: scripts/reset.sh <off|on>
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
source scripts/lib.sh

require_variant "${1:-}"
variant="$1"
app="$(variant_to_app "${variant}")"
ns="$(variant_to_ns "${variant}")"

echo "== hard refresh + sync ${app} =="
argocd app sync "${app}" --prune --force
argocd app wait "${app}" --sync --health --timeout 180

echo "== verifying sync/health status =="
status="$(argocd app get "${app}" -o json | jq -r '.status.sync.status')"
health="$(argocd app get "${app}" -o json | jq -r '.status.health.status')"
echo "sync=${status} health=${health}"
if [[ "${status}" != "Synced" || "${health}" != "Healthy" ]]; then
  echo "reset FAILED: expected Synced/Healthy, got ${status}/${health}" >&2
  exit 1
fi

echo "== verifying app response =="
body="$(curl_app "${ns}")"
echo "${body}"
greeting="$(echo "${body}" | jq -r '.greeting_env')"
if [[ "${greeting}" != "hello from git" ]]; then
  # A prior scenario (e.g. S4) may have restarted the pod while a
  # ConfigMap was drifted, baking the drifted value into greeting_env.
  # `argocd app sync` only reverts the ConfigMap object -- it does not
  # restart pods just because their mounted ConfigMap changed, so the
  # stale env var can survive a sync that otherwise reports Synced/
  # Healthy. One rollout restart clears it.
  echo "greeting_env='${greeting}' != 'hello from git' -- forcing a rollout restart to clear a stale env var from a previous scenario" >&2
  kubectl -n "${ns}" rollout restart deployment/driftapp
  kubectl -n "${ns}" rollout status deployment/driftapp --timeout=120s

  body="$(curl_app "${ns}")"
  echo "${body}"
  greeting="$(echo "${body}" | jq -r '.greeting_env')"
  if [[ "${greeting}" != "hello from git" ]]; then
    echo "reset FAILED even after rollout restart: expected greeting_env='hello from git', got '${greeting}'" >&2
    exit 1
  fi
fi

echo "== reset OK: ${app} is Synced, Healthy, and serving Git's declared state =="
