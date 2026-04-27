#!/usr/bin/env bash
set -uo pipefail

: "${SCRIPT_DIR:?SCRIPT_DIR must be set}"

mkdir -p claude-findings openai-findings gemini-findings

run_provider() {
  local provider="$1"
  local key_var="$2"
  local model_var="$3"
  local context_var="$4"

  local key="${!key_var:-}"
  if [ -z "$key" ]; then
    echo "[$provider] No API key provided. Skipping."
    return
  fi

  echo "[$provider] Running review (model: ${!model_var:-default})"

  AI_REVIEW_MODEL="${!model_var:-}" \
  AI_REVIEW_CONTEXT_FILE="${!context_var:-}" \
  AI_REVIEW_PROMPT_FILE="${PROMPT_FILE:-}" \
    node "$SCRIPT_DIR/ai-review.mjs" --provider "$provider" \
    < /tmp/filtered-diff.txt \
    > "/tmp/${provider}-findings.json" \
    2> "/tmp/${provider}-review.log" || true

  if [ -s "/tmp/${provider}-findings.json" ]; then
    cp "/tmp/${provider}-findings.json" "${provider}-findings/findings.json"
  fi

  if [ -s "/tmp/${provider}-review.log" ]; then
    echo "[$provider] log:"
    cat "/tmp/${provider}-review.log"
  fi
}

run_provider claude ANTHROPIC_API_KEY CLAUDE_MODEL CLAUDE_CONTEXT_FILE
run_provider openai OPENAI_API_KEY OPENAI_MODEL OPENAI_CONTEXT_FILE
run_provider gemini GEMINI_API_KEY GEMINI_MODEL GEMINI_CONTEXT_FILE

echo "reviewed=true" >> "$GITHUB_OUTPUT"
