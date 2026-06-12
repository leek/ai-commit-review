import { test } from 'node:test';
import assert from 'node:assert/strict';

import { isSelfRetracted } from './ai-review.mjs';

// Why these matter: the model files a finding then undermines it in the same
// description. Shipping it wastes a reviewer's time triaging a non-issue, which
// is exactly what prompted this filter (e.g. issue #769 Finding 2).
test('drops findings the model retracts in its own words', () => {
  const retracted = [
    // Verbatim shape of the real #769 Finding 2 that slipped through.
    {
      title: 'Backfill sets is_system after exists check',
      description:
        'The new guard throws when flagging an existing row. The transient flag IS set first, so this path is allowed. This is actually OK. Dropping.',
    },
    { title: 'Disregard — import exists', description: 'Disregard, the symbol is defined elsewhere.' },
    { description: 'On closer inspection the existing code already handles this.' },
    { description: 'This looks like a false positive.' },
    { description: 'Re-reading: this technically works, so dropping this finding.' },
    { description: 'Actually fine — the saving guard short-circuits.' },
    { description: 'This is not actually a bug.' },
    { description: 'Not a real issue once you account for the cast.' },
    { description: 'Scratch that, the value is hydrated in the constructor.' },
  ];

  for (const finding of retracted) {
    assert.equal(isSelfRetracted(finding), true, `expected retracted: ${JSON.stringify(finding)}`);
  }
});

// Guard against over-matching: genuine findings often mention "drop" or "issue"
// in a non-retraction sense. Those must survive.
test('keeps genuine findings, including ones that mention drop/issue innocently', () => {
  const legit = [
    { title: 'Off-by-one on token boundary', description: 'Uses < instead of <= so the final token is rejected.' },
    { title: 'SQL injection', description: 'User input is concatenated directly into the query string.' },
    { title: 'Unsafe migration', description: 'The migration is dropping the orders column with no backfill.' },
    { title: 'Swallowed error', description: 'The promise is not awaited, dropping the error on the floor.' },
    { title: 'Missing index', description: 'The WHERE clause filters on status with no covering index.' },
    { title: 'Race on counter', description: 'Two requests can read the same value before either writes, an issue under load.' },
  ];

  for (const finding of legit) {
    assert.equal(isSelfRetracted(finding), false, `expected kept: ${JSON.stringify(finding)}`);
  }
});

test('handles missing title/description without throwing', () => {
  assert.equal(isSelfRetracted({}), false);
  assert.equal(isSelfRetracted({ title: 'Dropping.' }), true);
});
