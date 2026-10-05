# drift-lab

A small local experiment measuring what Argo CD actually detects,
self-heals, or misses when live Kubernetes state drifts from Git.

See `results/FINDINGS.md` for the write-up once scenarios are run.

## Quick start

```sh
scripts/setup.sh
# push repo to GitHub, confirm argocd/*.yaml repoURL points at it, then:
kubectl apply -f argocd/selfheal-off.yaml -f argocd/selfheal-on.yaml
scripts/reset.sh off
scripts/reset.sh on
```

Then, per scenario `Sx`:

```sh
scripts/reset.sh off
# fill the prediction in results/results.csv before causing drift
scripts/sx.sh off
scripts/observe.sh Sx off t0
# wait, observe again at 30s / 3min / 5min
scripts/reset.sh on
scripts/sx.sh on
scripts/observe.sh Sx on t0
```
