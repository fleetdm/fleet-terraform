#!/bin/bash

set -euo pipefail

if ! command -v gh >/dev/null 2>&1; then
  echo "error: GitHub CLI (gh) is required but not installed." >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "error: jq is required but not installed." >&2
  exit 1
fi

if ! gh extension list | awk '{print $1}' | grep -qx "agynio/gh-pr-review"; then
  echo "Installing gh extension agynio/gh-pr-review..." >&2
  gh extension install agynio/gh-pr-review
fi

GH_REPO="$(git config --get remote.origin.url | sed 's/.*[:\/]\(.*\)\/\(.*\)\.git/\1\/\2/')"
GIT_PR="$(gh pr list --head "$(git branch --show-current)" --json number | jq '.[0].number')"

gh pr-review review view "${GIT_PR}" --repo "${GH_REPO}"
