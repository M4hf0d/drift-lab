#!/usr/bin/env bash
# Runs every scenario (S1-S9) against both variants (off, on), end to end:
# reset -> write prediction -> cause drift -> observe at t0/30s/3min/5min ->
# compute the results.csv row from the saved evidence.
#

set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
source scripts/lib.sh

CSV="results/results.csv"
BASELINE_SECRET_SHA="36eb4988c3c0eba31c361c7c7850a3f3469f253b5d02e283c85d1c2ab382153d"

declare -A PRED
PRED[S1]="Argo flags OutOfSync quickly (live diff on replica count). OFF: extra replica persists -- automated sync without selfHeal does not proactively revert live drift. ON: Argo auto-reverts replicas back to 1 within its reconcile loop. App stays Healthy and serves correct content throughout either way."
PRED[S2]="Argo flags OutOfSync (image tag differs). The nonexistent tag should cause ImagePullBackOff on the new pod; the old pod likely survives (default maxUnavailable), so curl may keep working even while Health shows Degraded/Progressing. OFF: stuck until manual fix. ON: Argo reverts the image tag back to git automatically."
PRED[S3]="Argo flags OutOfSync (ConfigMap data differs from git). greeting_file (volume-mounted) should update in place within about a minute; greeting_env (baked in at pod start) should stay stale. OFF: stays drifted. ON: Argo reverts ConfigMap data back to git; greeting_file flips back after the next kubelet sync."
PRED[S4]="Centerpiece scenario. ConfigMap is edited then the pod is deleted, so the replacement pod restarts with the DRIFTED env var baked in. OFF: Argo shows OutOfSync and curl shows DRIFTED -- consistent and visible, not silent. ON: Argo should heal the ConfigMap back to git (Synced/Healthy) but the already-restarted pod's greeting_env was captured at startup and won't re-read it -- predicting curl keeps returning DRIFTED greeting_env even while Argo reports everything Synced and Healthy. This is the candidate silent divergence the whole lab is built to catch."
PRED[S5]="Argo should flag the Service as Missing/OutOfSync; curl against the ClusterIP DNS name should fail immediately since the Service object is gone. OFF: stays missing until manual sync. ON: Argo recreates it automatically and curl recovers."
PRED[S6]="The extra ConfigMap is never tracked by this Application (no argocd.argoproj.io/instance label). Predicting Argo never notices it in either variant: stays Synced/Healthy throughout, since prune only removes tracked resources that left git, not arbitrary untracked extras."
PRED[S7]="Uncertain call: does Argo's default diff flag a hand-added annotation git never declared? Predicting yes in both variants initially (OutOfSync). OFF: annotation persists, no selfHeal to strip it. ON: Argo reverts the stray annotation back to Synced. curl should be unaffected regardless, since the pod template never changed."
PRED[S8]="The Secret was created directly by kubectl and is never referenced in deploy/, so Argo should have zero knowledge of it in either variant -- predicting Sync/Health stay Synced/Healthy throughout even as secret_sha256 changes live (secret volumes update in place, no restart needed). Expected to be the cleanest demonstration that 'Synced' says nothing about resources outside the tracked source."
PRED[S9]="Writing into the container's writable layer via exec never touches the Kubernetes API. Predicting zero visibility for Argo in either variant (stays Synced/Healthy); the app's own HTTP endpoint doesn't expose this file either, so curl is unaffected too. Pure negative control."

declare -A DRIFT_CMD
DRIFT_CMD[S1]='kubectl scale deployment/driftapp --replicas=3'
DRIFT_CMD[S2]='kubectl set image deployment/driftapp driftapp=driftapp:drifted'
DRIFT_CMD[S3]='kubectl patch configmap driftapp-config --type merge -p "{\"data\":{\"greeting\":\"DRIFTED\"}}"'
DRIFT_CMD[S4]='kubectl patch configmap driftapp-config ...; kubectl delete pod -l app=driftapp'
DRIFT_CMD[S5]='kubectl delete svc driftapp'
DRIFT_CMD[S6]='kubectl create configmap extra-not-in-git --from-literal=note=unmanaged'
DRIFT_CMD[S7]='kubectl annotate deployment/driftapp drift-lab.test/injected=true'
DRIFT_CMD[S8]='kubectl create secret generic driftapp-secret --from-literal=value=DRIFTED-SECRET ... | kubectl apply -f -'
DRIFT_CMD[S9]='kubectl exec <pod> -- sh -c "echo DRIFTED-IN-CONTAINER > /tmp/runtime-drift.txt"'

csv_escape() {
  # wrap in double quotes, escape embedded quotes
  local s="$1"
  s="${s//\"/\"\"}"
  printf '"%s"' "${s}"
}

run_one() {
  local sid="$1" variant="$2"
  local n="${sid#S}"
  echo
  echo "##### ${sid} / ${variant} #####"

  echo "-- reset --"
  bash scripts/reset.sh "${variant}" || { echo "reset FAILED for ${sid}/${variant}, skipping" >&2; return 1; }

  echo "-- drift --"
  bash "scripts/s${n}.sh" "${variant}"

  echo "-- observe t0 --"
  bash scripts/observe.sh "${sid}" "${variant}" t0
  sleep 30
  echo "-- observe t30s --"
  bash scripts/observe.sh "${sid}" "${variant}" t30s
  sleep 150
  echo "-- observe t3min --"
  bash scripts/observe.sh "${sid}" "${variant}" t3min
  sleep 120
  echo "-- observe t5min --"
  bash scripts/observe.sh "${sid}" "${variant}" t5min

  local base="results/raw/${sid}/${variant}"
  local sync0 sync30 sync3 sync5 health5 curl5

  sync0="$(jq -r '.status.sync.status // "unknown"' "${base}/t0/app-get.json" 2>/dev/null)"
  sync30="$(jq -r '.status.sync.status // "unknown"' "${base}/t30s/app-get.json" 2>/dev/null)"
  sync3="$(jq -r '.status.sync.status // "unknown"' "${base}/t3min/app-get.json" 2>/dev/null)"
  sync5="$(jq -r '.status.sync.status // "unknown"' "${base}/t5min/app-get.json" 2>/dev/null)"
  health5="$(jq -r '.status.health.status // "unknown"' "${base}/t5min/app-get.json" 2>/dev/null)"

  local detected="n" time_to_detect="n/a"
  if [[ "${sync0}" == "OutOfSync" ]]; then detected="y"; time_to_detect="t0"
  elif [[ "${sync30}" == "OutOfSync" ]]; then detected="y"; time_to_detect="30s"
  elif [[ "${sync3}" == "OutOfSync" ]]; then detected="y"; time_to_detect="3min"
  elif [[ "${sync5}" == "OutOfSync" ]]; then detected="y"; time_to_detect="5min"
  fi

  local healed="n/a"
  if [[ "${detected}" == "y" ]]; then
    if [[ "${sync5}" == "Synced" ]]; then healed="y"; else healed="n"; fi
  fi

  curl5="$(cat "${base}/t5min/curl.json" 2>/dev/null)"

  local ge gfile se curl_matches="n"
  ge="$(echo "${curl5}" | jq -r '.greeting_env // ""' 2>/dev/null)"
  gfile="$(echo "${curl5}" | jq -r '.greeting_file // ""' 2>/dev/null)"
  se="$(echo "${curl5}" | jq -r '.secret_sha256 // ""' 2>/dev/null)"

  case "${sid}" in
    S5)
      # Service deleted -- curl is EXPECTED to fail under selfheal=off (not
      # yet recreated). curl_matches_git tracks "does the app currently
      # serve git's declared values", which is n if unreachable.
      if [[ -n "${curl5}" ]] && [[ "${ge}" == "hello from git" && "${gfile}" == "hello from git" ]]; then
        curl_matches="y"
      else
        curl_matches="n"
      fi
      ;;
    S8)
      # Secret is never tracked in git at all -- judge curl_matches_git only
      # on the fields git DOES declare (greeting_env/file). secret_sha256
      # divergence from baseline is noted separately, not scored here.
      if [[ "${ge}" == "hello from git" && "${gfile}" == "hello from git" ]]; then
        curl_matches="y"
      else
        curl_matches="n"
      fi
      ;;
    *)
      if [[ "${ge}" == "hello from git" && "${gfile}" == "hello from git" ]]; then
        curl_matches="y"
      else
        curl_matches="n"
      fi
      ;;
  esac

  local argo_matches="n"
  if [[ "${sync5}" == "Synced" && "${curl_matches}" == "y" ]]; then
    argo_matches="y"
  elif [[ "${sync5}" == "OutOfSync" && "${curl_matches}" == "n" ]]; then
    argo_matches="y"
  else
    argo_matches="n"
  fi

  local notes="sync progression: t0=${sync0} t30s=${sync30} t3min=${sync3} t5min=${sync5}."
  if [[ "${sid}" == "S8" ]]; then
    notes="${notes} secret_sha256 at t5min=${se} (baseline=${BASELINE_SECRET_SHA}); divergence not scored in curl_matches_git since the Secret is untracked by git."
  fi

  {
    printf '%s,' "$(csv_escape "${sid}")"
    printf '%s,' "$(csv_escape "${DRIFT_CMD[${sid}]}")"
    printf '%s,' "$(csv_escape "${PRED[${sid}]}")"
    printf '%s,' "$(csv_escape "${variant}")"
    printf '%s,' "$(csv_escape "${detected}")"
    printf '%s,' "$(csv_escape "${time_to_detect}")"
    printf '%s,' "$(csv_escape "${healed}")"
    printf '%s,' "$(csv_escape "${sync5}")"
    printf '%s,' "$(csv_escape "${health5}")"
    printf '%s,' "$(csv_escape "${curl_matches}")"
    printf '%s,' "$(csv_escape "${argo_matches}")"
    printf '%s,' "$(csv_escape "${base}")"
    printf '%s\n' "$(csv_escape "${notes}")"
  } >> "${CSV}"

  echo "-- row written: ${sid}/${variant} sync5=${sync5} health5=${health5} curl_matches=${curl_matches} argo_matches=${argo_matches} --"
}

if [[ $# -gt 0 ]]; then
  # dry-run / smoke-test mode: scripts/run_all.sh S1 off
  run_one "$1" "$2"
  exit $?
fi

for variant in off on; do
  for n in 1 2 3 4 5 6 7 8 9; do
    run_one "S${n}" "${variant}"
  done
done

echo
echo "ALL SCENARIOS COMPLETE"
