#!/usr/bin/env bash
set -euo pipefail

# AI Review Digest Script
# Merges findings from multiple AI providers into a single GitHub Issue.
# Optionally creates a draft fix PR for high-confidence findings.

COMMIT_SHA="${COMMIT_SHA:?COMMIT_SHA must be set to the commit being reviewed}"
COMMIT_SHORT="${COMMIT_SHA:0:7}"
REPO="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY must be set}"
AUTHOR="${GITHUB_ACTOR:?GITHUB_ACTOR must be set}"
MESSAGE=$(git log -1 --format='%s' "$COMMIT_SHA" 2>/dev/null || echo "(no message)")

MIN_SEVERITY="${MIN_SEVERITY_FOR_ISSUE:-critical}"
MIN_MODELS_FIX_PR="${MIN_MODELS_FOR_FIX_PR:-2}"
ISSUE_LABEL="${ISSUE_LABEL:-ai-review}"
ISSUE_TITLE_PREFIX="${ISSUE_TITLE_PREFIX:-[AI Review]}"
FIX_PR_TITLE_PREFIX="${FIX_PR_TITLE_PREFIX:-[AI Fix] Suggested fixes for}"
FIX_BRANCH_PREFIX="${FIX_BRANCH_PREFIX:-ai-fix/}"
BASE_BRANCH="${BASE_BRANCH:-main}"

CLAUDE_MODEL="${CLAUDE_MODEL:-claude}"
OPENAI_MODEL="${OPENAI_MODEL:-gpt}"
GEMINI_MODEL="${GEMINI_MODEL:-gemini}"

emit_output() {
  local key="$1"
  local val="$2"
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    echo "${key}=${val}" >> "$GITHUB_OUTPUT"
  fi
}

severity_rank() {
  case "$1" in
    critical) echo 0 ;;
    warning) echo 1 ;;
    info) echo 2 ;;
    *) echo 3 ;;
  esac
}

MIN_RANK=$(severity_rank "$MIN_SEVERITY")

trap 'rm -f "${ISSUE_BODY_FILE:-}" "${PR_BODY_FILE:-}"' EXIT

# Collect all findings files that exist
FINDING_FILES=()
PROVIDERS_PRESENT=()
for provider in claude openai gemini; do
  file="${provider}-findings/findings.json"
  if [ -f "$file" ] && jq empty "$file" 2>/dev/null; then
    FINDING_FILES+=("$file")
    PROVIDERS_PRESENT+=("$provider")
  else
    echo "Warning: No valid findings from ${provider}"
  fi
done

if [ ${#FINDING_FILES[@]} -eq 0 ]; then
  echo "No findings files found. Skipping digest."
  emit_output critical_count 0
  emit_output warning_count 0
  emit_output info_count 0
  exit 0
fi

# Merge all findings into a single JSON array with provider attribution
MERGED=$(jq -s '
  [.[] | .provider as $p | .findings[]? | . + {source: $p}]
  | sort_by(
      if .severity == "critical" then 0
      elif .severity == "warning" then 1
      else 2 end
    )
' "${FINDING_FILES[@]}")

TOTAL=$(echo "$MERGED" | jq 'length')

if [ "$TOTAL" -eq 0 ]; then
  echo "No findings across all providers. Clean commit!"
  emit_output critical_count 0
  emit_output warning_count 0
  emit_output info_count 0
  exit 0
fi

echo "Found ${TOTAL} total findings across ${#FINDING_FILES[@]} providers"

SUMMARIES=$(jq -s '[.[] | {provider: .provider, summary: .summary}]' "${FINDING_FILES[@]}")

DEDUPED=$(echo "$MERGED" | jq '
  def as_num: if . == null then 0 elif type == "number" then . else (tonumber? // 0) end;
  reduce .[] as $f ([];
    . as $acc |
    ($acc | map(select(
      .file == $f.file and
      (((.line | as_num) - ($f.line | as_num)) | fabs) <= 3 and
      .severity == $f.severity
    )) | first) as $existing |
    if $existing then
      map(
        if . == $existing then
          .sources = (.sources + [$f.source] | unique)
        else . end
      )
    else
      . + [$f + {sources: [$f.source]}]
    end
  )
  | sort_by(
      if .severity == "critical" then 0
      elif .severity == "warning" then 1
      else 2 end
    )
')

DEDUPED_COUNT=$(echo "$DEDUPED" | jq 'length')
echo "After deduplication: ${DEDUPED_COUNT} unique findings"

build_findings_section() {
  local severity="$1"
  local label="$2"
  local items

  items=$(echo "$DEDUPED" | jq -r --arg sev "$severity" '
    [.[] | select(.severity == $sev)] |
    if length == 0 then empty
    else
      .[] |
      "- **\(.title)** (`\(.file):\(.line // "?")`) — flagged by \(.sources | join(", "))\n  \(.description)" +
      if .fix then "\n\n<details><summary>Suggested fix</summary>\n\n```\n\(.fix)\n```\n\n</details>\n" else "" end
    end
  ')

  if [ -n "$items" ]; then
    echo ""
    echo "### ${label}"
    echo "$items"
  fi
}

build_agreement_table() {
  echo ""
  echo "### Model Agreement"
  echo "| Finding | Claude | GPT | Gemini | Confidence |"
  echo "|---------|--------|-----|--------|------------|"

  echo "$DEDUPED" | jq -r '
    .[] |
    "| \(.title | .[0:40]) | \(if (.sources | index("claude")) then "x" else " " end) | \(if (.sources | index("openai")) then "x" else " " end) | \(if (.sources | index("gemini")) then "x" else " " end) | \(.confidence // "?") |"
  '
}

build_summaries_section() {
  echo ""
  echo "### Provider Summaries"
  echo "$SUMMARIES" | jq -r '.[] | "- **\(.provider):** \(.summary)"'
}

CRITICAL_COUNT=$(echo "$DEDUPED" | jq '[.[] | select(.severity == "critical")] | length')
WARNING_COUNT=$(echo "$DEDUPED" | jq '[.[] | select(.severity == "warning")] | length')
INFO_COUNT=$(echo "$DEDUPED" | jq '[.[] | select(.severity == "info")] | length')

emit_output critical_count "$CRITICAL_COUNT"
emit_output warning_count "$WARNING_COUNT"
emit_output info_count "$INFO_COUNT"

# Filter findings to those at or above the minimum severity for issue creation
QUALIFYING_COUNT=$(echo "$DEDUPED" | jq --argjson rank "$MIN_RANK" '
  [.[] | select(
    (if .severity == "critical" then 0
     elif .severity == "warning" then 1
     else 2 end) <= $rank
  )] | length
')

if [ "$QUALIFYING_COUNT" -eq 0 ]; then
  echo "No findings at or above '${MIN_SEVERITY}' severity. Skipping issue creation (${CRITICAL_COUNT} critical, ${WARNING_COUNT} warnings, ${INFO_COUNT} info)."
  exit 0
fi

# Check for existing issue for this commit to prevent duplicates
TITLE_LOOKUP_PREFIX="${ISSUE_TITLE_PREFIX} ${COMMIT_SHORT}"
EXISTING=$(gh api "repos/${REPO}/issues?labels=${ISSUE_LABEL}&state=all&per_page=100" \
  --jq "[.[] | select(.title | startswith(\"${TITLE_LOOKUP_PREFIX}\"))] | .[0].number // empty")
if [ -n "$EXISTING" ]; then
  echo "Issue already exists for ${COMMIT_SHORT}: #${EXISTING}. Skipping."
  exit 0
fi

FIRST_SUMMARY=$(echo "$SUMMARIES" | jq -r '.[0].summary // "Review complete"')
ISSUE_TITLE="${ISSUE_TITLE_PREFIX} ${COMMIT_SHORT}: ${FIRST_SUMMARY}"
ISSUE_TITLE="${ISSUE_TITLE:0:256}"

# Build a "Models" line listing only providers that produced findings
MODELS_LINE=""
for p in "${PROVIDERS_PRESENT[@]}"; do
  case "$p" in
    claude) MODELS_LINE+="${MODELS_LINE:+, }${CLAUDE_MODEL}" ;;
    openai) MODELS_LINE+="${MODELS_LINE:+, }${OPENAI_MODEL}" ;;
    gemini) MODELS_LINE+="${MODELS_LINE:+, }${GEMINI_MODEL}" ;;
  esac
done

ISSUE_BODY="## Commit Review: ${COMMIT_SHORT} by @${AUTHOR}
**Commit:** [\`${COMMIT_SHORT}\`](https://github.com/${REPO}/commit/${COMMIT_SHA})
**Message:** ${MESSAGE}
**Models:** ${MODELS_LINE}
**Findings:** ${CRITICAL_COUNT} critical, ${WARNING_COUNT} warnings, ${INFO_COUNT} info
$(build_findings_section "critical" "Critical")
$(build_findings_section "warning" "Warnings")
$(build_findings_section "info" "Info")
$(build_agreement_table)
$(build_summaries_section)"

# Ensure label exists
gh api "repos/${REPO}/labels" \
  -f name="${ISSUE_LABEL}" -f color="7057ff" -f description="AI-generated code review" \
  > /dev/null 2>&1 || true

ISSUE_BODY_FILE=$(mktemp)
jq -n \
  --arg title "${ISSUE_TITLE}" \
  --arg body "${ISSUE_BODY}" \
  --arg label "${ISSUE_LABEL}" \
  '{title: $title, body: $body, labels: [$label]}' > "${ISSUE_BODY_FILE}"

ISSUE_URL=$(gh api "repos/${REPO}/issues" \
  --input "${ISSUE_BODY_FILE}" \
  --jq '.html_url')

rm -f "${ISSUE_BODY_FILE}"

if [ -z "${ISSUE_URL}" ]; then
  echo "ERROR: Failed to create issue"
  exit 1
fi

echo "Created issue: ${ISSUE_URL}"
emit_output issue_url "${ISSUE_URL}"

# Create a fix PR if there are high-confidence fixes agreed on by enough models
if [ "$MIN_MODELS_FIX_PR" -le 0 ]; then
  echo "Fix PR creation disabled (min-models-for-fix-pr=0)."
  echo "Done!"
  exit 0
fi

HIGH_CONF_FIXES=$(echo "$DEDUPED" | jq --argjson min "$MIN_MODELS_FIX_PR" \
  '[.[] | select(.confidence == "high" and .fix != null and (.sources | length) >= $min)]')
HIGH_CONF_COUNT=$(echo "$HIGH_CONF_FIXES" | jq 'length')

if [ "$HIGH_CONF_COUNT" -gt 0 ]; then
  echo "Found ${HIGH_CONF_COUNT} high-confidence fixes agreed on by ${MIN_MODELS_FIX_PR}+ models"

  FIX_BRANCH="${FIX_BRANCH_PREFIX}${COMMIT_SHORT}"
  git checkout -b "${FIX_BRANCH}"

  PR_BODY="## AI-Suggested Fixes for ${COMMIT_SHORT}

Related issue: ${ISSUE_URL}

The following high-confidence fixes were identified by ${MIN_MODELS_FIX_PR}+ AI models.
**These fixes need human review before applying.**

$(echo "$HIGH_CONF_FIXES" | jq -r '
  .[] |
  "### \(.title)\n**File:** \(.file):\(.line // "?")\n**Flagged by:** \(.sources | join(", "))\n**Confidence:** \(.confidence)\n\n\(.description)\n\n**Suggested fix:**\n```\n\(.fix)\n```\n"
')"

  git commit --allow-empty -m "$(cat <<EOF
ai-review: suggested fixes for ${COMMIT_SHORT}

Fixes suggested by AI review. See PR body for details.
These are suggestions only — human review required.

Related: ${ISSUE_URL}
EOF
)"

  git push origin "${FIX_BRANCH}"

  PR_BODY_FILE=$(mktemp)
  jq -n \
    --arg title "${FIX_PR_TITLE_PREFIX} ${COMMIT_SHORT}" \
    --arg body "${PR_BODY}" \
    --arg head "${FIX_BRANCH}" \
    --arg base "${BASE_BRANCH}" \
    '{title: $title, body: $body, head: $head, base: $base, draft: true}' > "${PR_BODY_FILE}"

  PR_URL=$(gh api "repos/${REPO}/pulls" \
    --input "${PR_BODY_FILE}" \
    --jq '.html_url')

  rm -f "${PR_BODY_FILE}"

  echo "Created draft fix PR: ${PR_URL}"
  emit_output fix_pr_url "${PR_URL}"

  ISSUE_NUMBER=$(basename "${ISSUE_URL}")
  if [ -z "${ISSUE_NUMBER}" ] || ! [[ "${ISSUE_NUMBER}" =~ ^[0-9]+$ ]]; then
    echo "ERROR: Failed to extract issue number from ISSUE_URL: ${ISSUE_URL}"
    exit 1
  fi
  gh api "repos/${REPO}/issues/${ISSUE_NUMBER}/comments" \
    -f body="Draft fix PR created: ${PR_URL}" > /dev/null

  git checkout -
fi

echo "Done!"
