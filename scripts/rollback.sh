#!/usr/bin/env bash
# Roll a Burtson Labs k3s service back to an earlier release.
#
#   scripts/rollback.sh <service>                 # previous deployed version
#   scripts/rollback.sh <service> <version>       # a chart/app version from helm history
#   scripts/rollback.sh <service> --list          # show history and images, change nothing
#   scripts/rollback.sh <service> [version] -y    # no confirmation prompt
#
# <service> is a helm release name (helm list -A) or one of the aliases below.
# The rollback is `helm rollback --wait`: the previous manifests (including
# their pinned image tag) are re-applied and the command waits until the pods
# are ready. Revisions deployed before immutable image tags (image :latest)
# cannot bring the old code back; the script says so before doing anything.
#
# After a rollback, the next CI deploy of a NEWER chart version rolls forward
# as usual; CI never redeploys an older version over the live one. Fix forward
# with a new chart patch (above the version that was live before the rollback).
#
# Needs: helm 3.13+, kubectl, jq, and a kube context with deploy rights
# (KUBE_CONTEXT, default: current context).
set -euo pipefail

usage() { sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-1}"; }

SERVICE="${1:-}"; [ -n "$SERVICE" ] || usage
case "$SERVICE" in -h|--help) usage 0 ;; esac
shift
TARGET=""; YES=false; LIST=false
for a in "$@"; do
  case "$a" in
    -y|--yes) YES=true ;;
    --list|-l) LIST=true ;;
    -h|--help) usage 0 ;;
    *) TARGET="$a" ;;
  esac
done

h() { if [ -n "${KUBE_CONTEXT:-}" ]; then helm --kube-context "$KUBE_CONTEXT" "$@"; else helm "$@"; fi; }
k() { if [ -n "${KUBE_CONTEXT:-}" ]; then kubectl --context "$KUBE_CONTEXT" "$@"; else kubectl "$@"; fi; }

# alias -> namespace/release
case "$SERVICE" in
  gateway|gateway-api|GatewayApi)        NS=gateway-api;   REL=gateway-api ;;
  auth|auth-api|AuthApi)                 NS=auth-api;      REL=auth-api ;;
  s3|s3-api|S3Api)                       NS=s3-api;        REL=s3-api ;;
  bandit|bandit-site|banditailabs)       NS=bandit;        REL=bandit ;;
  stealth-web|bandit-stealth-web)        NS=bandit;        REL=bandit-stealth-web ;;
  stealth-admin|stealth-admin-api|StealthAdminApi) NS=stealth-admin; REL=stealth-admin-api ;;
  cdn|cdn-api)                           NS=cdn-api;       REL=cdn-api ;;
  ollama|ollama-k8s)                     NS=ollama;        REL=ollama-k8s ;;
  ollama-embed)                          NS=ollama;        REL=ollama-embed ;;
  anton|anton-node-agent)                NS=anton;         REL=anton-node-agent ;;
  website|burtson-labs|burtson-labs-website) NS=burtson-labs; REL=burtson-labs ;;
  tenant-ui|chat-tenant-ui)              NS=chat-tenant-ui; REL=chat-tenant-ui ;;
  mcp|mcp-server)                        NS=mcp-server;    REL=mcp-server ;;
  *)
    REL="$SERVICE"
    NS="$(h list -A -f "^${REL}\$" -o json | jq -r '.[0].namespace // ""')"
    [ -n "$NS" ] || { echo "Unknown service/release '$SERVICE' (helm list -A)." >&2; exit 1; }
    ;;
esac

HIST="$(h history "$REL" -n "$NS" --max 20 -o json)"
CUR_REV="$(h get metadata "$REL" -n "$NS" -o json | jq -r '.revision')"
CUR_VER="$(printf '%s' "$HIST" | jq -r --argjson r "$CUR_REV" '.[] | select(.revision==$r) | .chart')"

images_of() { # revision -> images in that revision's manifest
  h get manifest "$REL" -n "$NS" --revision "$1" 2>/dev/null \
    | grep -E '^[[:space:]]*image:' | awk '{print $2}' | tr -d '"' | sort -u | tr '\n' ' '
}

echo "Release $NS/$REL — live revision $CUR_REV ($CUR_VER)"
echo
printf '%-5s %-12s %-30s %s\n' REV STATUS CHART IMAGES
printf '%s' "$HIST" | jq -r '.[] | "\(.revision)\t\(.status)\t\(.chart)"' | sort -rn | while IFS=$'\t' read -r rev st ch; do
  printf '%-5s %-12s %-30s %s\n' "$rev" "$st" "$ch" "$(images_of "$rev")"
done
echo
$LIST && exit 0

if [ -z "$TARGET" ]; then
  # Newest earlier revision that was actually live (superseded/deployed) with a
  # different chart version than now. Skips failed and atomic-rolled-back ones.
  REV="$(printf '%s' "$HIST" | jq -r --argjson r "$CUR_REV" --arg cur "$CUR_VER" \
    '[.[] | select(.revision < $r and (.status=="superseded" or .status=="deployed") and .chart != $cur)] | sort_by(.revision) | last | .revision // empty')"
  [ -n "$REV" ] || { echo "No earlier live revision with a different version in the last 20." >&2; exit 1; }
else
  REV="$(printf '%s' "$HIST" | jq -r --arg v "$TARGET" \
    '[.[] | select((.chart|endswith("-" + $v)) or .app_version==$v or (.revision|tostring)==$v) | select(.status!="failed" and .status!="pending-upgrade" and .status!="pending-rollback")] | sort_by(.revision) | last | .revision // empty')"
  if [ -z "$REV" ]; then
    echo "Version $TARGET is not in the last 20 revisions of $REL." >&2
    echo "Deploy it from ChartMuseum instead (keeps current values):" >&2
    echo "  helm upgrade $REL burtson-labs-charts/<chart-name> -n $NS --version $TARGET --reuse-values --atomic --timeout 10m" >&2
    exit 1
  fi
fi

TARGET_CHART="$(printf '%s' "$HIST" | jq -r --argjson r "$REV" '.[] | select(.revision==$r) | .chart')"
TARGET_IMAGES="$(images_of "$REV")"
echo "Roll back $NS/$REL: revision $CUR_REV ($CUR_VER) -> revision $REV ($TARGET_CHART)"
echo "  images now:   $(images_of "$CUR_REV")"
echo "  images after: $TARGET_IMAGES"
if printf '%s' "$TARGET_IMAGES" | grep -qE ':latest( |$)|^[^:@ ]+( |$)'; then
  echo
  echo "WARNING: revision $REV deploys a mutable :latest image. Rolling back restores its"
  echo "manifests (env, probes, resources) but NOT the old code: :latest is today's image."
fi
if ! $YES; then
  read -r -p "Proceed? [y/N] " ans
  [ "$ans" = y ] || [ "$ans" = Y ] || { echo "Aborted."; exit 1; }
fi

h rollback "$REL" "$REV" -n "$NS" --wait --timeout "${ROLLBACK_TIMEOUT:-10m}"
echo
h history "$REL" -n "$NS" --max 3
k -n "$NS" get pods -l "app.kubernetes.io/instance=$REL" \
  -o custom-columns='POD:.metadata.name,READY:.status.containerStatuses[*].ready,IMAGE:.spec.containers[*].image,STARTED:.status.startTime' 2>/dev/null || true
echo
echo "Rolled back from $CUR_VER. CI deploys any chart version above the live one, so fix"
echo "forward with a new patch above $CUR_VER (a re-run of the $CUR_VER pipeline would redeploy it)."
