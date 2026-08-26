#!/usr/bin/env bash
# daily-local.sh — local daily driver for the CI pipeline (fork-friendly).
#
# GitHub does not run `schedule` triggers on forked repos, so while this
# repo is a fork the daily run is poked from a local cron. This script
# triggers the `Daily Sync & Release` workflow, which:
#   1. merges upstream (volcengine/OpenViking main) into the sync branch
#   2. builds the selected components
#   3. publishes a release versioned by the short git hash (d@<hash>)
#
# Usage:
#   scripts/daily-local.sh [--component all|cli|lib] [--branch <ref>]
#
#   --component  which component to build: all (default), cli, or lib
#   --branch     ref the workflow runs on (default: feat/cross-platform-
#                release-binaries). The called release workflow must exist
#                on that ref.
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
    -h|--help)   sed -n '2,30p' "$0"; exit 0 ;;
    *)           echo "FATAL: unknown arg: $1"; exit 1 ;;
  esac
  shift
done

case "$COMPONENT" in all|cli|lib) ;; *) echo "FATAL: --component must be all|cli|lib"; exit 1 ;; esac

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

command -v gh >/dev/null 2>&1 || { echo "FATAL: gh not found (brew install gh)"; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "FATAL: gh not authenticated (gh auth login)"; exit 1; }

echo "==> Triggering Daily Sync & Release (ref=$BRANCH, component=$COMPONENT)"
gh workflow run daily-release.yml --ref "$BRANCH" --field "component=$COMPONENT"
echo "==> Triggered. Follow it with:"
echo "      gh run list --workflow 'Daily Sync & Release' --limit 5"
