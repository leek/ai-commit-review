# AI Commit Review

GitHub Action that reviews a single commit with **Claude**, **GPT**, and **Gemini** in parallel, deduplicates findings, files them as a GitHub Issue, and optionally opens a draft PR with high-confidence fixes that multiple models agree on.

Designed to be called inside a per-commit matrix on push events. The action reviews **one commit per invocation** — your workflow handles enumeration.

## Quickstart

```yaml
name: AI Commit Review

on:
  push:
    branches: [main]

permissions:
  contents: write
  issues: write
  pull-requests: write

jobs:
  enumerate:
    runs-on: ubuntu-latest
    outputs:
      matrix: ${{ steps.commits.outputs.matrix }}
      count: ${{ steps.commits.outputs.count }}
    steps:
      - uses: actions/checkout@v6
        with: { fetch-depth: 0 }
      - id: commits
        env:
          BEFORE: ${{ github.event.before }}
          AFTER: ${{ github.event.after }}
        run: |
          if [[ "$BEFORE" == "0000000000000000000000000000000000000000" ]]; then
            SHAS=$(git log --format='%H' -1 "$AFTER")
          else
            SHAS=$(git log --format='%H' "${BEFORE}..${AFTER}")
          fi
          MATRIX=$(echo "$SHAS" | jq -R -s -c 'split("\n") | map(select(. != "")) | map({sha: .})')
          echo "count=$(echo "$MATRIX" | jq 'length')" >> "$GITHUB_OUTPUT"
          echo "matrix=${MATRIX}" >> "$GITHUB_OUTPUT"

  review:
    needs: enumerate
    if: needs.enumerate.outputs.count != '0'
    runs-on: ubuntu-latest
    strategy:
      fail-fast: false
      max-parallel: 5
      matrix:
        commit: ${{ fromJson(needs.enumerate.outputs.matrix) }}
    steps:
      - uses: actions/checkout@v6
        with: { fetch-depth: 0 }

      - uses: leek/ai-commit-review@v1
        with:
          commit-sha: ${{ matrix.commit.sha }}
          anthropic-api-key: ${{ secrets.ANTHROPIC_API_KEY }}
          openai-api-key: ${{ secrets.OPENAI_API_KEY }}
          gemini-api-key: ${{ secrets.GEMINI_API_KEY }}
```

Any provider whose API key is empty is skipped. Run with one, two, or all three.

## Inputs

| Input | Default | Description |
|---|---|---|
| `commit-sha` | _required_ | Commit SHA to review. Caller must `actions/checkout` with `fetch-depth: 0`. |
| `anthropic-api-key` | _empty_ | Anthropic API key. Provider runs only when set. |
| `openai-api-key` | _empty_ | OpenAI API key. |
| `gemini-api-key` | _empty_ | Gemini API key. |
| `claude-model` | `claude-opus-4-7` | Anthropic model id. |
| `openai-model` | `gpt-5.5` | OpenAI model id. |
| `gemini-model` | `gemini-3.1-pro-preview` | Gemini model id. |
| `claude-context-file` | _empty_ | Project context file injected into the Claude prompt. |
| `openai-context-file` | _empty_ | Project context file injected into the OpenAI prompt. |
| `gemini-context-file` | _empty_ | Project context file injected into the Gemini prompt. |
| `prompt-file` | _empty_ | Path to a custom prompt template. Overrides the bundled generic prompt. |
| `exclude-paths` | _empty_ | Newline-separated git pathspecs excluded from the diff. Use the `:!path` syntax. |
| `max-diff-lines` | `5000` | Skip review if filtered diff exceeds this many added/changed lines. |
| `skip-message-patterns` | `Merge*` | Newline-separated bash globs matched against the commit subject. |
| `skip-author-patterns` | _empty_ | Newline-separated bash globs matched against the commit author name. |
| `min-severity-for-issue` | `critical` | One of `critical`, `warning`, `info`. |
| `min-models-for-fix-pr` | `2` | Number of providers that must agree on a high-confidence fix before a fix PR is opened. `0` disables. |
| `issue-label` | `ai-review` | Label applied to created issues. |
| `issue-title-prefix` | `[AI Review]` | Issue title prefix. |
| `fix-pr-title-prefix` | `[AI Fix] Suggested fixes for` | Fix PR title prefix. |
| `fix-branch-prefix` | `ai-fix/` | Fix branch prefix. Short SHA is appended. |
| `base-branch` | `main` | Base branch for fix PRs. |
| `github-token` | `${{ github.token }}` | Token used to create issues, comments, branches, and PRs. |
| `node-version` | `20` | Node.js version. |

## Outputs

| Output | Description |
|---|---|
| `reviewed` | `true` if the commit was reviewed, `false` if skipped. |
| `skip-reason` | Reason the commit was skipped, if any. |
| `diff-line-count` | Added/changed line count of the filtered diff. |
| `critical-count` | Critical findings after dedup. |
| `warning-count` | Warning findings after dedup. |
| `info-count` | Info findings after dedup. |
| `issue-url` | URL of the created issue, if any. |
| `fix-pr-url` | URL of the created draft fix PR, if any. |

## Example: project-tuned

```yaml
- uses: leek/ai-commit-review@v1
  with:
    commit-sha: ${{ matrix.commit.sha }}
    anthropic-api-key: ${{ secrets.ANTHROPIC_API_KEY }}
    openai-api-key: ${{ secrets.OPENAI_API_KEY }}
    gemini-api-key: ${{ secrets.GEMINI_API_KEY }}
    claude-context-file: CLAUDE.md
    openai-context-file: AGENTS.md
    gemini-context-file: GEMINI.md
    prompt-file: .github/ai-review-prompt.txt
    exclude-paths: |
      :!package-lock.json
      :!yarn.lock
      :!vendor/
      :!node_modules/
      :!tests/
    skip-message-patterns: |
      Merge*
      build(deps)*
      *[skip-review]*
      *[skip-ci]*
      *fix code style*
      *Fix Code Style*
      ai-review:*
    skip-author-patterns: |
      *dependabot*
```

## How it works

1. **Skip check** — matches the commit subject and author against your skip patterns.
2. **Diff filter** — `git diff sha~1 sha` with your `exclude-paths` applied. Skips if larger than `max-diff-lines`.
3. **Provider fan-out** — runs Claude, GPT, Gemini in sequence. Each provider receives the bundled (or custom) prompt, optional project context, and the diff.
4. **Digest** — merges findings, dedupes by file + line proximity + severity, builds a markdown report, files it as an issue. Optionally opens a draft fix PR for high-confidence findings that multiple models agree on.

## Permissions

The workflow needs:

```yaml
permissions:
  contents: write       # for the fix PR branch
  issues: write         # for finding issues
  pull-requests: write  # for the fix PR
```

## Notes

- The action does not enumerate commits. Drive the matrix from your workflow so failures isolate per-commit.
- Existing issues for the same short SHA are detected and creation is skipped.
- All API calls have two retries on 5xx responses.

## License

MIT
