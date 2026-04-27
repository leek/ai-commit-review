#!/usr/bin/env node

/**
 * AI Code Review Script
 * Reads a git diff from stdin, sends it to an AI provider, outputs JSON findings.
 * Usage: git diff HEAD~1 HEAD | node ai-review.mjs --provider claude|openai|gemini
 *
 * Env:
 *   <PROVIDER>_API_KEY   required (ANTHROPIC_API_KEY, OPENAI_API_KEY, GEMINI_API_KEY)
 *   AI_REVIEW_MODEL      optional model id override
 *   AI_REVIEW_CONTEXT_FILE optional path to a project context file injected into the prompt
 */

import { readFileSync, existsSync } from 'node:fs';
import { resolve } from 'node:path';
import { argv, stdin, stdout, stderr, exit } from 'node:process';

const PROVIDERS = {
  claude: {
    url: 'https://api.anthropic.com/v1/messages',
    defaultModel: 'claude-opus-4-7',
    envKey: 'ANTHROPIC_API_KEY',
    buildRequest(apiKey, prompt, model) {
      return {
        headers: {
          'x-api-key': apiKey,
          'anthropic-version': '2023-06-01',
          'content-type': 'application/json',
        },
        body: JSON.stringify({
          model,
          max_tokens: 4096,
          messages: [{ role: 'user', content: prompt }],
        }),
      };
    },
    extractText(json) {
      return json.content?.[0]?.text ?? '';
    },
  },

  openai: {
    url: 'https://api.openai.com/v1/chat/completions',
    defaultModel: 'gpt-5.5',
    envKey: 'OPENAI_API_KEY',
    buildRequest(apiKey, prompt, model) {
      return {
        headers: {
          Authorization: `Bearer ${apiKey}`,
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({
          model,
          max_completion_tokens: 4096,
          response_format: { type: 'json_object' },
          messages: [
            { role: 'system', content: 'You are a code reviewer. Always respond with valid JSON.' },
            { role: 'user', content: prompt },
          ],
        }),
      };
    },
    extractText(json) {
      return json.choices?.[0]?.message?.content ?? '';
    },
  },

  gemini: {
    urlTemplate: (model) =>
      `https://generativelanguage.googleapis.com/v1beta/models/${encodeURIComponent(model)}:generateContent`,
    defaultModel: 'gemini-3.1-pro-preview',
    envKey: 'GEMINI_API_KEY',
    buildRequest(apiKey, prompt) {
      return {
        headers: {
          'x-goog-api-key': apiKey,
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({
          contents: [{ parts: [{ text: prompt }] }],
          generationConfig: {
            responseMimeType: 'application/json',
          },
        }),
      };
    },
    extractText(json) {
      return json.candidates?.[0]?.content?.parts?.[0]?.text ?? '';
    },
  },
};

function parseArgs() {
  const providerIdx = argv.indexOf('--provider');
  if (providerIdx === -1 || !argv[providerIdx + 1]) {
    stderr.write('Usage: ai-review.mjs --provider claude|openai|gemini\n');
    exit(1);
  }
  const provider = argv[providerIdx + 1];
  if (!PROVIDERS[provider]) {
    stderr.write(`Unknown provider: ${provider}. Must be one of: ${Object.keys(PROVIDERS).join(', ')}\n`);
    exit(1);
  }
  return provider;
}

function readStdin() {
  return readFileSync(stdin.fd, 'utf-8');
}

async function callApi(provider, diff) {
  const config = PROVIDERS[provider];
  const apiKey = process.env[config.envKey];
  if (!apiKey) {
    stderr.write(`Missing environment variable: ${config.envKey}\n`);
    exit(1);
  }

  const model = process.env.AI_REVIEW_MODEL?.trim() || config.defaultModel;
  const url = config.urlTemplate ? config.urlTemplate(model) : config.url;

  const customPromptFile = process.env.AI_REVIEW_PROMPT_FILE?.trim();
  let promptTemplate;
  if (customPromptFile) {
    const customPath = resolve(process.cwd(), customPromptFile);
    if (existsSync(customPath)) {
      promptTemplate = readFileSync(customPath, 'utf-8');
      stderr.write(`[${provider}] Loaded custom prompt from ${customPromptFile}\n`);
    } else {
      stderr.write(`[${provider}] Custom prompt file not found: ${customPromptFile}, using bundled\n`);
      promptTemplate = readFileSync(new URL('ai-review-prompt.txt', import.meta.url), 'utf-8');
    }
  } else {
    promptTemplate = readFileSync(new URL('ai-review-prompt.txt', import.meta.url), 'utf-8');
  }

  const contextFile = process.env.AI_REVIEW_CONTEXT_FILE?.trim();
  let projectContext = '';
  if (contextFile) {
    const contextPath = resolve(process.cwd(), contextFile);
    if (existsSync(contextPath)) {
      projectContext = readFileSync(contextPath, 'utf-8');
      stderr.write(`[${provider}] Loaded project context from ${contextFile}\n`);
    } else {
      stderr.write(`[${provider}] Context file not found: ${contextFile}\n`);
    }
  }

  const prompt =
    (projectContext ? `## Project Context\n\n${projectContext}\n\n` : '') +
    promptTemplate +
    '\n\n' +
    diff;

  const { headers, body } = config.buildRequest(apiKey, prompt, model);

  const maxRetries = 2;
  for (let attempt = 0; attempt <= maxRetries; attempt++) {
    try {
      const response = await fetch(url, { method: 'POST', headers, body });

      if (!response.ok) {
        const errorText = await response.text();
        stderr.write(`[${provider}] API error (${response.status}): ${errorText}\n`);
        if (attempt < maxRetries && response.status >= 500) {
          stderr.write(`[${provider}] Retrying in 5s... (attempt ${attempt + 1}/${maxRetries})\n`);
          await new Promise((r) => setTimeout(r, 5000));
          continue;
        }
        exit(1);
      }

      const json = await response.json();
      const text = config.extractText(json);

      if (!text) {
        stderr.write(`[${provider}] Empty response from API\n`);
        exit(1);
      }

      return text;
    } catch (err) {
      stderr.write(`[${provider}] Request failed: ${err.message}\n`);
      if (attempt < maxRetries) {
        stderr.write(`[${provider}] Retrying in 5s... (attempt ${attempt + 1}/${maxRetries})\n`);
        await new Promise((r) => setTimeout(r, 5000));
        continue;
      }
      exit(1);
    }
  }
}

function parseFindings(text) {
  const cleaned = text.replace(/^```(?:json)?\s*\n?/m, '').replace(/\n?```\s*$/m, '').trim();

  try {
    const parsed = JSON.parse(cleaned);
    if (!parsed.summary || !Array.isArray(parsed.findings)) {
      stderr.write('Response missing required fields (summary, findings)\n');
      return { summary: 'Parse error', findings: [] };
    }
    return parsed;
  } catch (err) {
    stderr.write(`Failed to parse JSON response: ${err.message}\n`);
    stderr.write(`Raw response: ${text.substring(0, 500)}\n`);
    return { summary: 'Parse error', findings: [] };
  }
}

async function main() {
  const provider = parseArgs();
  const diff = readStdin();

  if (!diff.trim()) {
    stderr.write('No diff provided on stdin\n');
    stdout.write(JSON.stringify({ summary: 'Empty diff', findings: [] }));
    exit(0);
  }

  stderr.write(`[${provider}] Reviewing ${diff.split('\n').length} lines of diff...\n`);

  const text = await callApi(provider, diff);
  const findings = parseFindings(text);
  findings.provider = provider;

  stdout.write(JSON.stringify(findings, null, 2));
}

main();
