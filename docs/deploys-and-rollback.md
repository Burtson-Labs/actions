# Deploys and rollback (k3s services)

How a Burtson Labs service gets to the k3s cluster, what protects it during a deploy,
and how to put the previous version back.

## What a deploy does

1. `build-push-docker-image.yaml` builds the image and pushes three tags:
   - `:<version>`: the chart's `appVersion` (caller passes `chart_path`) or the `version` input.
     Pushed only from the default branch. It is immutable: if the tag already exists and was
     built from another commit, the build fails and asks for a chart bump, unless that commit
     only changed `.github/`, `docs/`, `charts/` or Markdown files; then the existing image is
     reused and the build is skipped (a notice says so).
   - `:sha-<short>`: every build, any branch.
   - `:latest`: default branch only, kept as a convenience. Charts do not deploy it.
2. `package-push-deploy-helm-chart.yaml` pushes the chart to ChartMuseum and runs
   `helm upgrade --install --atomic --timeout 10m --history-max 20`.
   - The chart deploys `image.tag` = `appVersion` with `pullPolicy: IfNotPresent`, so each helm
     revision names the exact image it ran, and `helm rollback` brings that image back.
   - `--atomic` waits for the rollout. If the new pods do not become ready in time, helm rolls
     the release back by itself and the job fails.
   - One deploy per release at a time: the job's concurrency group is
     `helm-deploy-<namespace>-<release>`. A newer run waits for the running one; a queued run is
     replaced by a newer one.
   - A run whose chart version is lower than the live release is skipped with a warning, so an
     older commit's run that finishes late cannot roll production back
     (`allow_downgrade: true` overrides; use the rollback script instead).

GHCR keeps every image version: no Burtson-Labs workflow deletes package versions. Keep it
that way, or keep semver tags if a cleanup job is ever added.

## Releasing a change

Bump `charts/<chart>/Chart.yaml` `version` and `appVersion` together, to the next patch above
what is on `origin/main` (fetch first: other sessions push the same repos). One number,
one image, one helm revision. A push without a bump fails the image build
("Image version already published") instead of silently deploying nothing.

## Rollback

```bash
# from a checkout of Burtson-Labs/actions, kube context burtson.ai
scripts/rollback.sh <service> --list        # history + image per revision, changes nothing
scripts/rollback.sh <service>               # back to the previous live version
scripts/rollback.sh <service> 1.6.39        # back to a specific chart/app version
scripts/rollback.sh <service> 1.6.39 -y     # without the prompt
```

`<service>` is a helm release name or an alias (`gateway`, `auth`, `s3`, `bandit`,
`stealth-web`, `stealth-admin`, `cdn`, `ollama`, `ollama-embed`, `anton`, `website`,
`tenant-ui`, `mcp`). The script runs `helm rollback --wait` and prints the pods it ends up
with. Revisions from before immutable tags deploy `:latest`; the script warns that rolling
back to one restores manifests but not the old code.

Equivalent by hand:

```bash
helm history <release> -n <ns>
helm rollback <release> <revision> -n <ns> --wait --timeout 10m
kubectl -n <ns> get pods -l app.kubernetes.io/instance=<release> -o wide
```

After a rollback:

- CI deploys any chart version above the live one, so the next push rolls forward. Fix
  forward with a new patch above the version you rolled back from.
- A re-run of the bad version's pipeline would redeploy it; don't re-run it.

If the version is older than the 20 revisions helm keeps, deploy it from ChartMuseum:

```bash
helm repo add burtson-labs-charts https://charts.burtson.ai --username … --password …
helm upgrade <release> burtson-labs-charts/<chart> -n <ns> --version <v> --reuse-values --atomic --timeout 10m
```

## When a deploy fails

| Symptom | Meaning | Do |
|---|---|---|
| `Image version already published` | Chart not bumped (or bumped `version` but not `appVersion`) and the commit changes image inputs | Bump both to the next patch above main |
| `Image reused` (notice, green) | CI/docs/chart-only commit without a bump | Nothing; bump the chart if the change should deploy |
| `Stale deploy skipped` (warning, green) | A newer chart is already live | Nothing |
| `timed out waiting for the condition` + `rolled back` | New pods never became ready; helm restored the previous revision | `kubectl -n <ns> describe pod` / `logs --previous` on the failed pods, fix forward |
| `another operation (install/upgrade/rollback) is in progress` | A previous helm run died mid-upgrade (release `pending-upgrade`) | `helm history`; `helm rollback <release> <last deployed rev>` clears it |
| Job waits on "concurrency" | Another deploy of the same release is running | Wait |

## Rollout safety in the charts

Charts converted to this scheme also set:

- `strategy: RollingUpdate` with `maxUnavailable: 0`, `maxSurge: 1` (new pod ready before an
  old one stops). Single-GPU / host-port workloads keep `Recreate`.
- A `PodDisruptionBudget` (`minAvailable: 1`) where there are 2+ replicas, so node drains keep
  one pod serving.
- A `preStop` sleep so endpoints drop the pod before it gets SIGTERM, and a
  `terminationGracePeriodSeconds` long enough for in-flight requests (and streams) to finish.
- Readiness probe (traffic gate) separate from liveness probe (restart only when wedged).
