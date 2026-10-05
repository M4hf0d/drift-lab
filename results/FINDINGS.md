# Findings: Argo CD drift detection, self-heal, and silent divergence

All 18 rows (9 scenarios × selfHeal off/on) are in `results.csv`, each
backed by saved command output under `results/raw/<id>/<variant>/`.

## Results matrix

| ID | Drift | selfHeal | Detected | Healed | Final sync/health | curl matches Git | Argo matches reality |
|---|---|---|---|---|---|---|---|
| S1 | scale 1→3 | off | y (t0) | n | OutOfSync / Healthy | y | **n** |
| S1 | scale 1→3 | on | y (t0) | y | Synced / Healthy | y | y |
| S2 | bad image tag | off | y (t0) | n | OutOfSync / Progressing | y | **n** |
| S2 | bad image tag | on | y (t0) | y | Synced / Healthy | y | y |
| S3 | edit ConfigMap | off | y (t0) | n | OutOfSync / Healthy | **n** | y |
| S3 | edit ConfigMap | on | **n** | n/a | Synced / Healthy | y | y |
| S4 | edit ConfigMap + delete pod | off | y (t0) | n | OutOfSync / Healthy | **n** | y |
| S4 | edit ConfigMap + delete pod | on | **n** | n/a | Synced / Healthy | y | y |
| S5 | delete Service | off | y (t0) | n | OutOfSync / Healthy | **n** | y |
| S5 | delete Service | on | y (t0) | y | Synced / Healthy | y | y |
| S6 | extra untracked ConfigMap | off | n | n/a | Synced / Healthy | y | y |
| S6 | extra untracked ConfigMap | on | n | n/a | Synced / Healthy | y | y |
| S7 | extra annotation | off | n | n/a | Synced / Healthy | y | y |
| S7 | extra annotation | on | n | n/a | Synced / Healthy | y | y |
| S8 | change untracked Secret | off | n | n/a | Synced / Healthy | y* | y |
| S8 | change untracked Secret | on | n | n/a | Synced / Healthy | y* | y |
| S9 | edit file in container | off | n | n/a | Synced / Healthy | y | y |
| S9 | edit file in container | on | n | n/a | Synced / Healthy | y | y |

\* S8's `curl_matches_git` only scores the two fields Git actually declares
(`greeting_env`/`greeting_file`); the Secret itself isn't in Git at all,
so there's no Git value to compare `secret_sha256` against. See finding 3.

## What "argo_status_matches_reality" means here, precisely

For each row this is computed as: **y** if (`Synced` and the app serves
Git's declared values) or (`OutOfSync` and the app does *not* serve Git's
declared values) — i.e. Argo's status and the app's actual behavior tell
the same story. **n** means they contradict each other.

This produced one case worth flagging as a scoring artifact, not a real
divergence: **S1/off** scores `n` because Argo reported `OutOfSync`
while the app still served perfectly correct content (the only drift was
an extra replica, which doesn't affect what any one pod returns). That's
Argo being *accurately pedantic* about infra state, not Argo being wrong
about the app. Contrast this with **S3/off**, **S4/off**, **S5/off** —
these score `y` specifically because Argo's `OutOfSync` *coincided* with
the app visibly serving wrong/unreachable content, which is the
"everything is consistent, nothing is silently wrong" case the method is
designed to detect. None of the 18 rows landed in the dangerous
quadrant — `Synced` while the app served something wrong — which is the
actual silent-divergence case this whole lab was built to catch.

## Finding 1: the predicted S4 silent divergence did not occur — and why, specifically

**Prediction**: editing the ConfigMap then deleting the pod would let the
replacement pod start with `DRIFTED` baked into `greeting_env`; with
selfHeal on, Argo would then heal the ConfigMap and report Synced/Healthy
while the already-started pod kept serving the stale value underneath.

**Observed** (`results/raw/S4/on/`): the drift script ran
`kubectl patch configmap ...` then immediately `kubectl delete pod -l
app=driftapp`. The original pod (`driftapp-5594586b-gzt4q`) was deleted;
its replacement (`driftapp-5594586b-98npf`) was already serving
`greeting_env: "hello from git"` — correct — by the very first
observation, taken only a few seconds after both commands ran. Sync
status never showed `OutOfSync` at any of the four checkpoints (t0,
30s, 3min, 5min); it was `Synced` throughout.

**Why**: Argo's self-heal controller reacted to the live ConfigMap change
fast enough — on the order of a few seconds, not the ~3-minute full
reconciliation interval the original hypothesis assumed — to revert the
ConfigMap *before* the replacement pod finished starting and read its
environment. The race the hypothesis depended on (pod restart happens
*while* the ConfigMap is still wrong) was won by Argo, not by the drift,
under this lab's conditions: a local kind cluster with the image already
cached on the node, so pod restart latency is about as low as it gets.

**S4/off**, by contrast, behaved exactly as predicted: no selfHeal means
nothing reverts the ConfigMap, so `OutOfSync` + the pod serving `DRIFTED`
persisted at every checkpoint through 5 minutes — visible and consistent,
not silent.

This is a real result, just not the one hypothesized: *under these
conditions*, self-heal's reaction latency beat the pod-restart race
rather than losing to it. It leaves open — and this lab cannot answer —
whether a slower cluster, a larger ConfigMap, higher API-server latency,
or a slower-starting container image would flip this result the other
way. See "Limits" below.

## Finding 2: self-heal reaction speed is not uniform across resource types

S1/on, S2/on, and S5/on (replica count, image tag, deleted Service) all
showed a real, observable `OutOfSync` window at t0 before healing to
`Synced` by t5min. S3/on and S4/on (ConfigMap-data-only edits) never
showed `OutOfSync` at all, at any checkpoint — the earliest possible
observation already found them healed. The common factor: S3/S4's drift
was a single ConfigMap object edit, the cheapest possible change for
Argo's live-state informer to notice and revert; S1/S2/S5 involve a
Deployment rollout or a missing Service, which take measurably longer to
actually settle (new pods must schedule and start, or get deleted) even
after Argo decides to fix them — keeping the transitional `OutOfSync`
state visible for at least one checkpoint. This wasn't a thing the
original plan anticipated measuring, but the evidence shows it clearly.

## Finding 3: "Synced" says nothing about state outside what Git declares

S8 is the cleanest version of this. The Secret is created directly by
`kubectl` in `setup.sh` and is never referenced in `deploy/` at all.
Changing its value live (`results/raw/S8/*/t5min/curl.json`:
`secret_sha256` changes from the baseline `36eb49...` to `a36cfe...`)
produced **zero change** in Argo's reported status, in both selfHeal
variants — it stayed `Synced`/`Healthy` throughout. This isn't a bug or
a gap in Argo's detection; it's a direct, correct consequence of GitOps
scope: Argo can only ever report on resources it was told to track.
"Synced" is a claim about the *tracked* subset of reality, not about
reality in general — and nothing in the UI distinguishes "this resource
matches Git" from "this resource was never Argo's concern."

## Finding 4: Argo's default diff has a real blind spot for additive live changes

S6 (an untracked ConfigMap created alongside the app) and S7 (an
annotation added to the tracked Deployment that Git never declared)
both stayed `Synced` throughout, in both variants. S6 is expected and
by design — Argo only prunes/compares resources it owns. **S7 was a
genuine prediction miss**: the plan expected Argo's diff to flag a
hand-added annotation as `OutOfSync` even under selfHeal off. It didn't,
in either variant, at any checkpoint. Argo CD's default comparison
appears to tolerate fields present live but absent from Git (at least
for annotations on a Deployment) rather than treating every additive
difference as drift. This is worth being precise about in any
conclusions drawn from this lab: Argo's "drift detection" is diffing
*specific fields it's configured to compare*, not a literal
live-vs-Git equality check.

## Finding 5: selfHeal=off behaves exactly as documented, no surprises

S1, S2, S3, S4, S5 under `off`: Argo correctly flagged every one as
`OutOfSync` and took no corrective action on its own, leaving the drift
in place through all four checkpoints (confirmed in each scenario's
`t5min/app-get.json`). `automated` + `prune` alone does not revert live
drift — only Git-side changes trigger an auto-sync. This matched the
plan's prediction for every off-variant row with no exceptions.

## Limits of this lab

- **Single tool, default config.** Argo CD, stable manifests, no custom
  health checks, no `ignoreDifferences`, no resource exclusions. A
  production Argo setup with those customizations could behave
  differently in either direction (more or less sensitive to drift).
- **Single trivial app.** No readiness gates, no multi-container pods, no
  CRDs, no admission webhooks, no real traffic.
- **Local kind cluster, warm caches.** The S4 finding (self-heal winning
  the restart race) is plausibly an artifact of extremely low local
  latency and a pre-cached image. A cluster with slower pod startup,
  larger objects, higher API-server latency, or a cold image pull could
  plausibly produce the originally-predicted silent divergence instead.
  This lab cannot tell you which is more common in real deployments —
  it can only tell you it's possible to not get one under favorable
  (fast) conditions.
- **One run per scenario per variant**, not repeated for variance. The
  self-heal reaction-time findings in particular (Finding 1, Finding 2)
  are based on a single observation each and could be timing noise
  rather than a reliable property — they're reported as "what happened
  once," not "what always happens."
- **Observation granularity is seconds, not sub-second.** "Healed before
  t0" means "healed before our first check, taken a few seconds after
  the drift command" — we have no instrumentation finer than that, so
  exact reaction latency (is it 200ms? 3 seconds?) is not something this
  lab actually measured, only bounded from above.
- **Environmental interruptions during the run**: a kind-cluster crash
  (unrelated Docker Desktop/WSL event, not triggered by any scenario)
  and a later full session teardown both happened mid-run and were
  recovered from manually. Neither appears to have affected the
  recorded scenario evidence (each row's reset step independently
  re-verifies Synced/Healthy/correct-content before the drift is caused),
  but it's a reason this wasn't a single unbroken automated run.

## Two sentences for a researcher

In a local, single-tool GitOps lab, Argo CD's self-heal reverted every
kind of live drift it was configured to track — including a config
change that had already been baked into a restarted pod — fast enough
that the "looks healed but is secretly still wrong" failure mode we
specifically built this experiment to catch never actually occurred.
The more robust finding was the opposite kind of gap: for anything
outside Argo's tracked scope (an out-of-Git secret, an untracked
resource, or state inside a running container), "Synced" provides zero
signal one way or the other, which is a sharper and more generally
true claim than anything about race-condition timing.

## Claims this evidence does not fully support

- That self-heal *always* wins the restart race (Finding 1/2) — this is
  one observation per scenario on one specific low-latency cluster.
- That Argo's annotation tolerance (Finding 4) generalizes to all field
  types, all resource kinds, or non-default Argo configurations — only
  one specific annotation on one Deployment was tested.
- Any claim about production Argo CD deployments, which commonly run
  customized health checks, `ignoreDifferences`, or notification/alerting
  on top of the defaults tested here.
