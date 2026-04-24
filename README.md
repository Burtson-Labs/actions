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

Every workflow above accepts an optional `runs_on` input that controls where the job runs. The value is a **JSON-encoded** label expression — pass either a quoted string (single label) or a JSON array (multiple labels).

- **Default**: `'"ubuntu-latest"'` — keeps existing callers on GitHub-hosted runners with no change required.
- **Burtson-Labs self-hosted pool** (ARC on the home K3s cluster, see [`ci-runners`](https://github.com/Burtson-Labs/ci-runners)): pass `'["self-hosted","arm64","burtson"]'`.

Example caller (Docker image, opting in to self-hosted):

```yaml
jobs:
  publish:
    uses: Burtson-Labs/actions/.github/workflows/build-push-docker-image.yaml@main
    with:
      imageName: burtson-labs/my-service
      runs_on: '["self-hosted","arm64","burtson"]'
    secrets: inherit
```

Omit `runs_on` entirely to stay on `ubuntu-latest` — every existing caller is unaffected by this change.

### Reverting a single repo

If a self-hosted run misbehaves, drop the `runs_on:` line from that repo's caller workflow. Next push lands back on `ubuntu-latest`. The reusable workflow itself stays as-is.
