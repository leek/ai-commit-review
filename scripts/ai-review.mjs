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
import { pathToFileURL } from 'node:url';
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
    defaultModel: 'gemini-3.5-flash',
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
    stderr.write('Usage: ai-review.mjs --provider claude|openai|gemini [--print-prompt|--print-schema|--normalize]\n');
    exit(1);
  }
  const provider = argv[providerIdx + 1];
  if (!PROVIDERS[provider]) {
    stderr.write(`Unknown provider: ${provider}. Must be one of: ${Object.keys(PROVIDERS).join(', ')}\n`);
    exit(1);
  }

  return {
    provider,
    printPrompt: argv.includes('--print-prompt'),
    printSchema: argv.includes('--print-schema'),
    normalize: argv.includes('--normalize'),
  };
}

function readStdin() {
  return readFileSync(stdin.fd, 'utf-8');
}

function loadPromptTemplate(provider) {
  const customPromptFile = process.env.AI_REVIEW_PROMPT_FILE?.trim();
  if (customPromptFile) {
    const customPath = resolve(process.cwd(), customPromptFile);
    if (existsSync(customPath)) {
      stderr.write(`[${provider}] Loaded custom prompt from ${customPromptFile}\n`);
      return readFileSync(customPath, 'utf-8');
    } else {
      stderr.write(`[${provider}] Custom prompt file not found: ${customPromptFile}, using bundled\n`);
    }
  }

  return readFileSync(new URL('ai-review-prompt.txt', import.meta.url), 'utf-8');
}

function loadProjectContext(provider) {
  const contextFile = process.env.AI_REVIEW_CONTEXT_FILE?.trim();
  if (!contextFile) {
    return '';
  }

  const contextPath = resolve(process.cwd(), contextFile);
  if (existsSync(contextPath)) {
    stderr.write(`[${provider}] Loaded project context from ${contextFile}\n`);
    return readFileSync(contextPath, 'utf-8');
  }

  stderr.write(`[${provider}] Context file not found: ${contextFile}\n`);

  return '';
}

function buildReviewPrompt(provider, diff) {
  const promptTemplate = loadPromptTemplate(provider);
  const projectContext = loadProjectContext(provider);
  const commitSha = process.env.AI_REVIEW_COMMIT_SHA?.trim();
  const hasFullRepoContext = process.env.AI_REVIEW_FULL_REPO_CONTEXT === 'true';
  const commitContext = commitSha
    ? [
        '## Commit Under Review',
        '',
        `Commit SHA: ${commitSha}`,
        ...(hasFullRepoContext
          ? [
              '',
              'You are running inside a full git checkout for this repository. Use read-only repository inspection to validate the diff against surrounding code, related tests, routes, configuration, and existing patterns before reporting a finding. Do not modify files. The extracted diff below identifies the commit under review; repository context is available only to confirm or reject findings.',
            ]
          : []),
        '',
      ].join('\n')
    : '';

  return (
    (projectContext ? `## Project Context\n\n${projectContext}\n\n` : '') +
    commitContext +
    promptTemplate +
    '\n\n' +
    diff
  );
}

export function findingsJsonSchema() {
  return {
    type: 'object',
    additionalProperties: false,
    required: ['summary', 'findings'],
    properties: {
      summary: { type: 'string' },
      findings: {
        type: 'array',
        maxItems: 10,
        items: {
          type: 'object',
          additionalProperties: false,
          required: ['severity', 'title', 'description', 'file', 'line', 'fix', 'confidence'],
          properties: {
            severity: { enum: ['critical', 'warning', 'info'] },
            title: { type: 'string' },
            description: { type: 'string' },
            file: { type: 'string' },
            line: { type: ['integer', 'null'] },
            fix: { type: ['string', 'null'] },
            confidence: { enum: ['high', 'medium', 'low'] },
          },
        },
      },
    },
  };
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
  const prompt = buildReviewPrompt(provider, diff);

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

function stripJsonFence(text) {
  const cleaned = text.replace(/^```(?:json)?\s*\n?/m, '').replace(/\n?```\s*$/m, '').trim();

  return cleaned;
}

function parseJsonLinesForFinalMessage(text) {
  const messages = [];

  for (const line of text.split('\n')) {
    const trimmed = line.trim();
    if (!trimmed.startsWith('{')) {
      continue;
    }

    try {
      const event = JSON.parse(trimmed);
      const item = event.item ?? event;

      if (item?.type === 'agent_message' && typeof item.text === 'string') {
        messages.push(item.text);
      } else if (typeof item?.message?.content === 'string') {
        messages.push(item.message.content);
      }
    } catch {
      // Ignore non-JSONL progress output.
    }
  }

  return messages.at(-1) ?? null;
}

function extractNestedResponseText(parsed) {
  const candidates = [
    parsed?.result,
    parsed?.text,
    parsed?.content,
    parsed?.message,
    parsed?.final_message,
    parsed?.['final-message'],
    parsed?.item?.text,
    parsed?.item?.message?.content,
  ];

  return candidates.find((candidate) => typeof candidate === 'string' && candidate.trim()) ?? null;
}

export function parseFindings(text) {
  const jsonLineMessage = parseJsonLinesForFinalMessage(text);
  const cleaned = stripJsonFence(jsonLineMessage ?? text);

  try {
    const parsed = JSON.parse(cleaned);
    if (!parsed.summary || !Array.isArray(parsed.findings)) {
      const nestedText = extractNestedResponseText(parsed);
      if (nestedText) {
        return parseFindings(nestedText);
      }

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

/**
 * Phrases a model uses when it talks itself out of a finding it just filed.
 * The prompt already tells models to drop these (rule 6), but they routinely
 * ignore it and ship the retraction in the description anyway, so we strip
 * them deterministically. Kept high-precision to avoid nuking genuine
 * findings that merely mention "drop"/"issue" in a non-retraction sense.
 */
export const SELF_RETRACTION_PATTERNS = [
  /\bdisregard\b/i,
  /\bnever ?mind\b/i,
  /\bnvm\b/i,
  /\bscratch that\b/i,
  /this technically works/i,
  /\bactually (?:ok|okay|fine|correct|safe|allowed|valid|harmless)\b/i,
  /\bnot (?:actually|really) an? (?:bug|issue|problem|defect|concern|vulnerability|error)\b/i,
  /\bnot a (?:real|genuine|true) (?:bug|issue|problem|defect|concern)\b/i,
  /\balready handles (?:this|it|that)\b/i,
  /\bexisting code already\b/i,
  /\bfalse[ -]?positive\b/i,
  /\bdropping (?:this|the) (?:finding|issue|item|one)\b/i,
  /(?:^|[.!?]\s+)dropping[.!]?\s*$/i,
  /\b(?:drop|ignore|disregard|retract|withdraw|remove) (?:this|the) finding\b/i,
  /\bon (?:second|closer) (?:thought|inspection|look|reading|review)\b/i,
];

/**
 * True when a finding's title/description contains language the model uses to
 * undermine its own finding. Such findings must not reach the issue.
 */
export function isSelfRetracted(finding) {
  const text = `${finding?.title ?? ''}\n${finding?.description ?? ''}`;
  return SELF_RETRACTION_PATTERNS.some((pattern) => pattern.test(text));
}

function dropSelfRetractedFindings(findings, provider) {
  return findings.filter((finding) => {
    if (isSelfRetracted(finding)) {
      stderr.write(`[${provider}] Dropped self-retracted finding: ${finding.title ?? '(untitled)'}\n`);
      return false;
    }
    return true;
  });
}

async function main() {
  const { provider, printPrompt, printSchema, normalize } = parseArgs();

  if (printSchema) {
    stdout.write(JSON.stringify(findingsJsonSchema(), null, 2));
    exit(0);
  }

  const diff = readStdin();

  if (!diff.trim()) {
    stderr.write('No diff provided on stdin\n');
    stdout.write(JSON.stringify({ summary: 'Empty diff', findings: [] }));
    exit(0);
  }

  if (printPrompt) {
    stdout.write(buildReviewPrompt(provider, diff));
    exit(0);
  }

  if (normalize) {
    const findings = parseFindings(diff);
    findings.findings = dropSelfRetractedFindings(findings.findings, provider);
    findings.provider = provider;

    stdout.write(JSON.stringify(findings, null, 2));
    exit(0);
  }

  stderr.write(`[${provider}] Reviewing ${diff.split('\n').length} lines of diff...\n`);

  const text = await callApi(provider, diff);
  const findings = parseFindings(text);
  findings.findings = dropSelfRetractedFindings(findings.findings, provider);
  findings.provider = provider;

  stdout.write(JSON.stringify(findings, null, 2));
}

if (import.meta.url === pathToFileURL(argv[1] ?? '').href) {
  main();
}
