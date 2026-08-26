#!/usr/bin/env bash
# daily-local.sh — local daily driver for the CI pipeline (fork-friendly).
#
# GitHub does not run `schedule` triggers on forked repos, and the
# workflow_dispatch API can lag on forks (the workflow index is stale).
# So the daily run is triggered by pushing a `daily*` tag: push events
# load the workflow file from the pushed ref itself, which always works.
#
# The tagged run triggers the `Daily Sync & Release` workflow, which:
#   1. merges upstream (volcengine/OpenViking main) into the sync branch
#   2. builds the selected components
#   3. publishes a release versioned by the short git hash (d@<hash>)
#
# Tag -> component mapping:
#   daily@<ts>      full release (cli + lib)   <- --component all (default)
#   daily-lib@<ts>  lib only                   <- --component lib
#   daily-cli@<ts>  cli only                   <- --component cli
#
# Usage:
#   scripts/daily-local.sh [--component all|cli|lib] [--branch <ref>]
#
#   --component  which component to build: all (default), cli, or lib
#   --branch     branch the workflow runs from / syncs into (default:
#                feat/cross-platform-release-binaries). daily-release.yml
#                must exist on that branch.
#
# Crontab (daily 02:00 Asia/Shanghai):
#   0 2 * * * cd /Users/oliveagle/ole/repos/github.com/oliveagle/OpenViking && /usr/bin/env bash scripts/daily-local.sh >> ~/.openviking-daily.log 2>&1
#
# Once the repo is standalone / merged upstream, delete this crontab entry:
# the `schedule` trigger in daily-release.yml takes over.

set -euo pipefail

COMPONENT="all"
BRANCH="feat/cross-platform-release-binaries"

while [ $# -gt 0 ]; do
  case "$1" in
    --component) shift; COMPONENT="${1:?--component requires all|cli|lib}" ;;
    --branch)    shift; BRANCH="${1:?--branch requires a ref}" ;;
    -h|--help)   sed -n '2,40p' "$0"; exit 0 ;;
    *)           echo "FATAL: unknown arg: $1"; exit 1 ;;
  esac
  shift
done

case "$COMPONENT" in
  all) TAG_PREFIX="daily" ;;
  lib) TAG_PREFIX="daily-lib" ;;
  cli) TAG_PREFIX="daily-cli" ;;
  *)   echo "FATAL: --component must be all|cli|lib"; exit 1 ;;
esac

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# Resolve owner/repo from the origin remote so git targets the fork, not
# the upstream parent.
REPO="$(git remote get-url origin | sed -E 's#^git@github.com:##; s#^https?://github.com/##; s#\.git$##')"
[[ -n "$REPO" ]] || { echo "FATAL: cannot resolve repo from origin remote"; exit 1; }

# Fetch the branch tip and tag it — the tag push triggers the workflow.
git fetch origin "$BRANCH"
TAG="${TAG_PREFIX}@$(date +%Y%m%d-%H%M%S)"
git tag -f "$TAG" "origin/$BRANCH"
git push origin "$TAG"

echo "==> Pushed trigger tag $TAG (repo=$REPO, branch=$BRANCH, component=$COMPONENT)"
echo "==> Follow it with:"
echo "      gh run list --repo $REPO --workflow 'Daily Sync & Release' --limit 5"
