#!/usr/bin/env bash
set -euo pipefail

: "${COMMIT_SHA:?COMMIT_SHA must be set}"
: "${MAX_DIFF_LINES:?MAX_DIFF_LINES must be set}"

DIFF_ARGS=(diff "${COMMIT_SHA}~1" "${COMMIT_SHA}" --)

while IFS= read -r path; do
  [ -z "$path" ] && continue
  DIFF_ARGS+=("$path")
done <<< "${EXCLUDE_PATHS:-}"

git "${DIFF_ARGS[@]}" > /tmp/filtered-diff.txt

LINE_COUNT=$(grep -c '^+' /tmp/filtered-diff.txt || true)
echo "Filtered diff: ${LINE_COUNT} added/changed lines"
echo "line_count=${LINE_COUNT}" >> "$GITHUB_OUTPUT"

if [ "$LINE_COUNT" -gt "$MAX_DIFF_LINES" ]; then
  echo "Diff too large (${LINE_COUNT} lines > ${MAX_DIFF_LINES}). Skipping."
  echo "skip_large=true" >> "$GITHUB_OUTPUT"
else
  echo "skip_large=false" >> "$GITHUB_OUTPUT"
fi
