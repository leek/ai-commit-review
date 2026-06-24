#!/usr/bin/env bash
set -uo pipefail

: "${SCRIPT_DIR:?SCRIPT_DIR must be set}"

REVIEW_WORKSPACE="${GITHUB_WORKSPACE:-$PWD}"

mkdir -p claude-findings openai-findings gemini-findings

lower() {
  tr '[:upper:]' '[:lower:]' <<< "${1:-}"
}

is_truthy() {
  case "$(lower "${1:-}")" in
    1|true|yes|on) return 0 ;;
    *) return 1 ;;
  esac
}

install_cli_if_needed() {
  local provider="$1"
  local command_path="$2"

  if command -v "$command_path" >/dev/null 2>&1; then
    return 0
  fi

  if ! is_truthy "${INSTALL_CLI_TOOLS:-true}"; then
    echo "[$provider] CLI command not found: $command_path. install-cli-tools is false. Skipping."
    return 1
  fi

  echo "[$provider] CLI command not found: $command_path. Installing..."

  case "$provider" in
    claude)
      npm install -g @anthropic-ai/claude-code@latest >/tmp/claude-cli-install.log 2>&1 || {
        echo "[claude] Failed to install Claude Code CLI"
        cat /tmp/claude-cli-install.log
        return 1
      }
      ;;
    openai)
      local install_dir="${RUNNER_TEMP:-/tmp}/ai-commit-review-bin"
      mkdir -p "$install_dir"
      curl -fsSL https://chatgpt.com/codex/install.sh \
        | CODEX_NON_INTERACTIVE=1 CODEX_INSTALL_DIR="$install_dir" sh \
        >/tmp/codex-cli-install.log 2>&1 || {
          echo "[openai] Failed to install Codex CLI"
          cat /tmp/codex-cli-install.log
          return 1
        }
      export PATH="$install_dir:$PATH"
      ;;
    *)
      echo "[$provider] No CLI installer configured"
      return 1
      ;;
  esac

  if ! command -v "$command_path" >/dev/null 2>&1; then
    echo "[$provider] CLI command is still unavailable after install: $command_path"
    return 1
  fi
}

provider_mode() {
  local provider="$1"
  local mode="$2"
  local key_var="$3"

  mode="$(lower "${mode:-auto}")"

  case "$mode" in
    api|cli) echo "$mode" ;;
    auto|"")
      case "$provider" in
        claude)
          if [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
            echo "cli"
          elif [ -n "${!key_var:-}" ]; then
            echo "api"
          else
            echo "skip"
          fi
          ;;
        openai)
          if [ -n "${CODEX_ACCESS_TOKEN:-}" ] || [ -n "${CODEX_AUTH_JSON:-}" ]; then
            echo "cli"
          elif [ -n "${!key_var:-}" ]; then
            echo "api"
          else
            echo "skip"
          fi
          ;;
        *)
          if [ -n "${!key_var:-}" ]; then
            echo "api"
          else
            echo "skip"
          fi
          ;;
      esac
      ;;
    *)
      echo "[$provider] Unknown auth mode '$mode'. Use auto, api, or cli. Skipping." >&2
      echo "skip"
      ;;
  esac
}

normalize_provider_output() {
  local provider="$1"
  local raw_file="$2"
  local log_file="$3"

  if [ ! -s "$raw_file" ]; then
    return
  fi

  node "$SCRIPT_DIR/ai-review.mjs" --provider "$provider" --normalize \
    < "$raw_file" \
    > "/tmp/${provider}-findings.json" \
    2>> "$log_file" || true

  if [ -s "/tmp/${provider}-findings.json" ]; then
    cp "/tmp/${provider}-findings.json" "${provider}-findings/findings.json"
  fi
}

ensure_codex_config() {
  local codex_home="$1"
  local config_file="${codex_home}/config.toml"
  local project_doc_fallback='project_doc_fallback_filenames = ["CLAUDE.md"]'

  mkdir -p "$codex_home"
  chmod 700 "$codex_home"
  touch "$config_file"
  chmod 600 "$config_file"

  if grep -Eq '^[[:space:]]*project_doc_fallback_filenames[[:space:]]*=' "$config_file"; then
    sed -i.bak -E "s|^[[:space:]]*project_doc_fallback_filenames[[:space:]]*=.*|${project_doc_fallback}|" "$config_file"
    rm -f "${config_file}.bak"
  else
    printf '\n%s\n' "$project_doc_fallback" >> "$config_file"
  fi
}

run_api_provider() {
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

run_claude_cli_provider() {
  local model="${CLAUDE_MODEL:-}"
  local command_path="${CLAUDE_CLI_PATH:-claude}"
  local prompt_file="/tmp/claude-review-prompt.txt"
  local schema_file="/tmp/ai-review-schema.json"
  local raw_file="/tmp/claude-cli-output.txt"
  local log_file="/tmp/claude-review.log"

  install_cli_if_needed claude "$command_path" || return

  AI_REVIEW_CONTEXT_FILE="${CLAUDE_CONTEXT_FILE:-}" \
  AI_REVIEW_COMMIT_SHA="${COMMIT_SHA:-}" \
  AI_REVIEW_FULL_REPO_CONTEXT=true \
  AI_REVIEW_INCLUDE_DIFF=false \
  AI_REVIEW_PROMPT_FILE="${PROMPT_FILE:-}" \
    node "$SCRIPT_DIR/ai-review.mjs" --provider claude --print-prompt \
    < /dev/null \
    > "$prompt_file" \
    2> "$log_file" || return

  node "$SCRIPT_DIR/ai-review.mjs" --provider claude --print-schema > "$schema_file"

  echo "[claude] Running review with Claude Code CLI (model: ${model:-default})"

  local args=(-p "Return only the requested JSON object for the code review prompt provided on stdin.")
  if [ -n "$model" ]; then
    args+=(--model "$model")
  fi
  args+=(--allowedTools "Read,Grep,Glob,Bash(git *),Bash(rg *),Bash(sed *),Bash(cat *),Bash(pwd),Bash(ls *)")
  args+=(--json-schema "$(cat "$schema_file")")
  args+=(--no-session-persistence)

  local claude_env=()
  if [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
    claude_env+=(CLAUDE_CODE_OAUTH_TOKEN="$CLAUDE_CODE_OAUTH_TOKEN")
  fi

  (
    cd "$REVIEW_WORKSPACE" || exit 1
    env -u ANTHROPIC_API_KEY -u ANTHROPIC_AUTH_TOKEN "${claude_env[@]}" "$command_path" "${args[@]}" \
      < "$prompt_file" \
      > "$raw_file" \
      2>> "$log_file" || true
  )

  normalize_provider_output claude "$raw_file" "$log_file"

  if [ -s "$log_file" ]; then
    echo "[claude] log:"
    cat "$log_file"
  fi
}

run_openai_cli_provider() {
  local model="${OPENAI_MODEL:-}"
  local command_path="${CODEX_CLI_PATH:-codex}"
  local prompt_file="/tmp/openai-review-prompt.txt"
  local schema_file="/tmp/ai-review-schema.json"
  local raw_file="/tmp/openai-cli-output.txt"
  local log_file="/tmp/openai-review.log"
  local codex_home="${CODEX_HOME_INPUT:-${CODEX_HOME:-}}"

  if [ -n "${CODEX_AUTH_JSON:-}" ]; then
    if [ -z "$codex_home" ]; then
      codex_home="${RUNNER_TEMP:-/tmp}/ai-commit-review-codex"
    fi
    mkdir -p "$codex_home"
    chmod 700 "$codex_home"
    printf '%s' "$CODEX_AUTH_JSON" > "$codex_home/auth.json"
    chmod 600 "$codex_home/auth.json"
  elif [ -z "$codex_home" ]; then
    codex_home="${HOME:-${RUNNER_TEMP:-/tmp}/ai-commit-review-codex}/.codex"
  fi

  ensure_codex_config "$codex_home"

  install_cli_if_needed openai "$command_path" || return

  AI_REVIEW_CONTEXT_FILE="${OPENAI_CONTEXT_FILE:-}" \
  AI_REVIEW_COMMIT_SHA="${COMMIT_SHA:-}" \
  AI_REVIEW_FULL_REPO_CONTEXT=true \
  AI_REVIEW_INCLUDE_DIFF=false \
  AI_REVIEW_PROMPT_FILE="${PROMPT_FILE:-}" \
    node "$SCRIPT_DIR/ai-review.mjs" --provider openai --print-prompt \
    < /dev/null \
    > "$prompt_file" \
    2> "$log_file" || return

  node "$SCRIPT_DIR/ai-review.mjs" --provider openai --print-schema > "$schema_file"

  echo "[openai] Running review with Codex CLI (model: ${model:-default})"

  local args=(exec --cd "$REVIEW_WORKSPACE" --sandbox "${CODEX_SANDBOX:-read-only}" --output-schema "$schema_file" -o "$raw_file")
  if [ -n "$model" ]; then
    args+=(--model "$model")
  fi
  args+=("Return only the requested JSON object for the code review prompt provided on stdin.")

  local codex_env=()
  if [ -n "$codex_home" ]; then
    codex_env+=(CODEX_HOME="$codex_home")
  fi
  if [ -n "${CODEX_ACCESS_TOKEN:-}" ]; then
    codex_env+=(CODEX_ACCESS_TOKEN="$CODEX_ACCESS_TOKEN")
  fi

  env -u OPENAI_API_KEY -u CODEX_API_KEY "${codex_env[@]}" "$command_path" "${args[@]}" \
    < "$prompt_file" \
    >> "$log_file" \
    2>&1 || true

  normalize_provider_output openai "$raw_file" "$log_file"

  if [ -s "$log_file" ]; then
    echo "[openai] log:"
    cat "$log_file"
  fi
}

run_provider() {
  local provider="$1"
  local key_var="$2"
  local model_var="$3"
  local context_var="$4"
  local mode_var="$5"

  local mode
  mode="$(provider_mode "$provider" "${!mode_var:-auto}" "$key_var")"

  case "$mode" in
    api) run_api_provider "$provider" "$key_var" "$model_var" "$context_var" ;;
    cli)
      case "$provider" in
        claude) run_claude_cli_provider ;;
        openai) run_openai_cli_provider ;;
        *)
          echo "[$provider] CLI mode is not supported. Falling back to API mode."
          run_api_provider "$provider" "$key_var" "$model_var" "$context_var"
          ;;
      esac
      ;;
    skip) echo "[$provider] No credentials provided. Skipping." ;;
  esac
}

CLAUDE_AUTH="${CLAUDE_AUTH:-auto}"
OPENAI_AUTH="${OPENAI_AUTH:-auto}"
GEMINI_AUTH="api"

run_provider claude ANTHROPIC_API_KEY CLAUDE_MODEL CLAUDE_CONTEXT_FILE CLAUDE_AUTH
run_provider openai OPENAI_API_KEY OPENAI_MODEL OPENAI_CONTEXT_FILE OPENAI_AUTH
run_provider gemini GEMINI_API_KEY GEMINI_MODEL GEMINI_CONTEXT_FILE GEMINI_AUTH

echo "reviewed=true" >> "$GITHUB_OUTPUT"
