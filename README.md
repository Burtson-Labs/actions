# actions

Reusable GitHub Actions workflows for Burtson-Labs repos.

## Workflows

| Workflow | Purpose |
|---|---|
| `build-push-docker-image.yaml` | Build a multi-arch image and push to GHCR as `:<version>` (immutable), `:sha-<short>` and `:latest`. |
| `build-push-github-npm-package.yaml` | Publish an npm package to GitHub Packages. |
| `build-push-github-pnpm-package.yaml` | Publish a pnpm-managed package to GitHub Packages. |
| `build-push-npmjs-package.yaml` | Publish an npm package to npmjs.org. |
| `build-push-pnpmjs-package.yaml` | Publish a pnpm-managed package to npmjs.org. |
| `build-push-ng-lib.yaml` | Build and publish an Angular library. |
| `package-push-deploy-helm-chart.yaml` | Package, push, and `helm upgrade --install --atomic` a chart (one deploy per release at a time, never older over newer). |

## Self-hosted runner opt-in (`runs_on` input)

Every workflow above accepts an optional `runs_on` input that controls where the job runs. The value is a **JSON-encoded** `runs-on` expression.

- **Default**: `'"ubuntu-latest"'` — keeps existing callers on GitHub-hosted runners with no change required.
- **Burtson-Labs self-hosted pool**: pass the scale-set name advertised by [`ci-runners`](https://github.com/Burtson-Labs/ci-runners). Today that's `'"burtson-labs-runners"'`.

> The deployed [`gha-runner-scale-set`](https://github.com/actions/actions-runner-controller) chart identifies each pool by exactly one label — its `runnerScaleSetName`. Arbitrary labels like `[self-hosted, arm64, ...]` are not supported on this controller; if you see those in older docs, that's the legacy ARC pattern.

Example caller (Docker image, opting in to self-hosted):

```yaml
jobs:
  publish:
    uses: Burtson-Labs/actions/.github/workflows/build-push-docker-image.yaml@main
    with:
      imageName: burtson-labs/my-service
      runs_on: '"burtson-labs-runners"'
    secrets: inherit
```

Omit `runs_on` entirely to stay on `ubuntu-latest` — every existing caller is unaffected by this change.

### Reverting a single repo

If a self-hosted run misbehaves, drop the `runs_on:` line from that repo's caller workflow. Next push lands back on `ubuntu-latest`. The reusable workflow itself stays as-is.

## k3s service deploys: immutable tags, atomic upgrades, rollback

Full write-up: [docs/deploys-and-rollback.md](docs/deploys-and-rollback.md). Rollback:
`scripts/rollback.sh <service> [version]`.

Caller pattern for a service chart:

```yaml
concurrency:                      # serialise this repo's pipeline on main
  group: my-service-pipeline-${{ github.ref }}
  cancel-in-progress: false

jobs:
  build-push-docker-image:
    uses: Burtson-Labs/actions/.github/workflows/build-push-docker-image.yaml@main
    with:
      imageName: burtson-labs/my-service
      chart_path: charts/my-service   # pushes :<appVersion> (+ :sha-<short>, :latest)
      runs_on: '"burtson-labs-runners"'
    secrets: inherit

  package-push-deploy-helm-chart:
    needs: build-push-docker-image
    uses: Burtson-Labs/actions/.github/workflows/package-push-deploy-helm-chart.yaml@main
    with:
      chart_path: charts/my-service
      namespace: my-service
      release_name: my-service
      values_file: charts/my-service/values.yaml
      # atomic: true (default), timeout: '10m' (default), allow_downgrade: false (default)
    secrets: inherit
```

The chart's image line: `{{ .Values.image.repository }}:{{ .Values.image.tag | default .Chart.AppVersion }}`
with `image.tag: ""` and `pullPolicy: IfNotPresent`. Bump `version` and `appVersion` together
on every release.

Inputs added 2026-11-28 (defaults apply to every caller):

| Workflow | Input | Default | |
|---|---|---|---|
| build-push-docker-image | `chart_path` / `version` | `""` | Push `:<version>`; fails if that tag exists from another commit |
| package-push-deploy-helm-chart | `atomic` | `true` | `--atomic`: wait, auto-rollback on a failed rollout |
| package-push-deploy-helm-chart | `timeout` | `10m` | helm `--timeout` |
| package-push-deploy-helm-chart | `allow_downgrade` | `false` | Skip (green, warning) when the chart is older than the live release |

The deploy job's concurrency group is `helm-deploy-<namespace>-<release>`; don't reuse that
name for a caller's workflow-level group.
