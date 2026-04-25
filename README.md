# actions

Reusable GitHub Actions workflows for Burtson-Labs repos.

## Workflows

| Workflow | Purpose |
|---|---|
| `build-push-docker-image.yaml` | Build a multi-arch image and push to GHCR. |
| `build-push-github-npm-package.yaml` | Publish an npm package to GitHub Packages. |
| `build-push-github-pnpm-package.yaml` | Publish a pnpm-managed package to GitHub Packages. |
| `build-push-npmjs-package.yaml` | Publish an npm package to npmjs.org. |
| `build-push-pnpmjs-package.yaml` | Publish a pnpm-managed package to npmjs.org. |
| `build-push-ng-lib.yaml` | Build and publish an Angular library. |
| `package-push-deploy-helm-chart.yaml` | Package, push, and `helm upgrade --install` a chart. |

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
