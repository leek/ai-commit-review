#!/usr/bin/env bash
set -euo pipefail

: "${COMMIT_SHA:?COMMIT_SHA must be set}"

MESSAGE=$(git log -1 --format='%s' "$COMMIT_SHA")
AUTHOR=$(git log -1 --format='%an' "$COMMIT_SHA")

echo "Commit: $COMMIT_SHA"
echo "Subject: $MESSAGE"
echo "Author: $AUTHOR"

skip() {
  local reason="$1"
  echo "Skipping: $reason"
  {
    echo "should_review=false"
    echo "skip_reason=$reason"
  } >> "$GITHUB_OUTPUT"
  exit 0
}

while IFS= read -r pattern; do
  [ -z "$pattern" ] && continue
  # shellcheck disable=SC2053
  if [[ "$MESSAGE" == $pattern ]]; then
    skip "message matches pattern: $pattern"
  fi
done <<< "${SKIP_MESSAGE_PATTERNS:-}"

while IFS= read -r pattern; do
  [ -z "$pattern" ] && continue
  # shellcheck disable=SC2053
  if [[ "$AUTHOR" == $pattern ]]; then
    skip "author matches pattern: $pattern"
  fi
done <<< "${SKIP_AUTHOR_PATTERNS:-}"

echo "should_review=true" >> "$GITHUB_OUTPUT"
