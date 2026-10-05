#!/usr/bin/env bash
# Captures a timestamped snapshot of evidence into results/raw/<id>/<label>/:
#   argocd app get (JSON), argocd app diff, kubectl get of the managed
#   resources (YAML), recent namespace events, and a curl of the app.
#
# Usage: scripts/observe.sh <scenario-id> <off|on> <label>
#   e.g.: scripts/observe.sh S4 on t0
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
source scripts/lib.sh

if [[ $# -lt 3 ]]; then
  echo "usage: $0 <scenario-id> <off|on> <label>" >&2
  exit 1
fi
scenario="$1"
require_variant "$2"
variant="$2"
label="$3"
app="$(variant_to_app "${variant}")"
ns="$(variant_to_ns "${variant}")"

outdir="results/raw/${scenario}/${variant}/${label}"
mkdir -p "${outdir}"

date -u +"%Y-%m-%dT%H:%M:%SZ" > "${outdir}/timestamp.txt"

argocd app get "${app}" -o json > "${outdir}/app-get.json" 2>&1 || true
argocd app diff "${app}" > "${outdir}/app-diff.txt" 2>&1 || true

kubectl -n "${ns}" get deploy,svc,cm,secret -o yaml > "${outdir}/k8s-resources.yaml" 2>&1 || true
kubectl -n "${ns}" get events --sort-by=.lastTimestamp > "${outdir}/events.txt" 2>&1 || true

curl_app "${ns}" > "${outdir}/curl.json" 2>&1 || true

sync_status="$(jq -r '.status.sync.status // "unknown"' "${outdir}/app-get.json" 2>/dev/null || echo unknown)"
health_status="$(jq -r '.status.health.status // "unknown"' "${outdir}/app-get.json" 2>/dev/null || echo unknown)"
echo "[${scenario}/${variant}/${label}] sync=${sync_status} health=${health_status}"
echo "  curl: $(cat "${outdir}/curl.json")"
echo "  saved to ${outdir}/"
