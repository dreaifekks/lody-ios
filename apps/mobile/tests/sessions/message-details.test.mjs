import test from 'node:test';
import assert from 'node:assert/strict';
import { messageDetailSections } from '../../src/features/sessions/messageDetails.ts';

test('turn details distinguish missing usage, sum output once and prefer recorded reasoning', () => {
  assert.deepEqual(messageDetailSections(), []);
  assert.deepEqual(messageDetailSections({}), []);
  const entry = {
    modelInfo: { modelId: 'id-only', thoughtLevel: 'High' },
    inputConfig: {
      modeId: 'plan',
      configOptionValues: { effort: 'low', fast: false },
    },
    tokenUsage: {
      inputTokens: 1234,
      outputTokens: 6640,
      reasoningOutputTokens: 2000,
      cacheReadInputTokens: 120000,
      cacheCreationInputTokens: 4096,
    },
  };
  const rows = messageDetailSections(entry).flatMap((section) => section.rows);
  const row = (id) => rows.find((row) => row.id === id);
  assert.equal(row('model').subtitle, 'id-only');
  assert.equal(row('reasoning').value, 'High');
  assert.equal(rows.filter((row) => row.id === 'reasoning').length, 1);
  assert.equal(row('fast').value, 'Off');
  assert.equal(row('plan').value, 'On');
  assert.equal(row('output').value, '8,640');
  assert.equal(row('cacheRead').value, '120,000');
  assert.equal(
    messageDetailSections({ ...entry, tokenUsage: undefined }).length,
    1,
  );
  const zero = Object.fromEntries(
    Object.keys(entry.tokenUsage).map((key) => [key, 0]),
  );
  const zeroRows = messageDetailSections({ tokenUsage: zero }).flatMap(
    (section) => section.rows,
  );
  assert.equal(zeroRows.find((row) => row.id === 'input').value, '0');
  assert.equal(
    zeroRows.find((row) => row.id === 'reasoningTokens'),
    undefined,
  );
});

test('turn cost follows desktop precision and omits partial or absent pricing', () => {
  const base = {
    inputTokens: 1,
    outputTokens: 1,
    reasoningOutputTokens: 0,
    cacheReadInputTokens: 0,
    cacheCreationInputTokens: 0,
  };
  const cost = (value) =>
    messageDetailSections({ tokenUsage: { ...base, ...value } })
      .flatMap((s) => s.rows)
      .find((r) => r.id === 'cost');
  assert.equal(cost({}), undefined);
  assert.equal(cost({ costUSD: null }), undefined);
  assert.equal(cost({ costUSD: 0 }).value, '$0.00');
  assert.equal(cost({ costUSD: 0.01234 }).value, '$0.0123');
  assert.equal(cost({ costUSD: 0.00001234 }).value, '$0.00001234');
  assert.equal(cost({ costUSD: 12.345 }).value, '$12.35');
});
