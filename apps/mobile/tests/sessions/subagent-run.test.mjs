import assert from 'node:assert/strict';
import test from 'node:test';
import {
  runEntries,
  runMeta,
  liveTask,
  runComplete,
  withRunItems,
} from '../../src/features/sessions/subagentRun.ts';
import { setLocale } from '../../src/lib/i18n/index.ts';

setLocale('en');
const task = (run, extra = {}) => ({
  itemId: 'task-1',
  rev: 1,
  type: 'subagent_task',
  taskId: 't1',
  status: 'in_progress',
  actor: 'Explore',
  run,
  ...extra,
});
const items = [
  { itemId: 'run-0', rev: 1, type: 'thought', text: 'Trace it.' },
  {
    itemId: 'grep',
    rev: 1,
    type: 'tool_call',
    kind: 'search',
    status: 'completed',
    title: 'Grep verifyToken',
  },
  { itemId: 'run-2', rev: 1, type: 'text', text: 'Six callers.' },
];

test('a run becomes one assistant turn the chat folds like any other', () => {
  const [entry] = runEntries(task({ state: 'running', items }));
  assert.equal(entry.role, 'assistant');
  assert.equal(entry.finished, false);
  assert.equal(entry.status, 'running');
  assert.deepEqual(
    entry.items.map((i) => i.itemId),
    ['run-0', 'grep', 'run-2'],
  );
  const [done] = runEntries(task({ state: 'completed', items }));
  assert.equal(done.finished, true);
  assert.equal(done.status, 'completed');
  assert.deepEqual(runEntries(task(undefined)), []);
});

test('run metadata lists only what the provider reported', () => {
  assert.equal(
    runMeta(
      task({
        state: 'running',
        modelId: 'gpt-5-codex',
        totalTokens: 3100,
        toolCallCount: 7,
        contextUsagePercent: 18,
        items,
      }),
    ),
    'gpt-5-codex · 3.1k tokens · 7 tools · context 18%',
  );
  assert.equal(
    runMeta(task({ state: 'running', totalTokens: 640, items: [] })),
    '640 tokens',
  );
});

test('the open detail follows the live task by item id', () => {
  const entries = [
    {
      id: 'e1',
      items: [task({ state: 'completed', items }, { status: 'completed' })],
    },
  ];
  assert.equal(
    liveTask(
      task({ state: 'running', items: [] }),
      'e1',
      JSON.stringify(entries),
    ).run.state,
    'completed',
  );
  assert.equal(
    liveTask(
      task({ state: 'running', items: [] }),
      'gone',
      JSON.stringify(entries),
    ).run.state,
    'running',
  );
});

test('a run from the session envelope is completed by the steps its sheet read', () => {
  const latest = { ...items[2], rev: 2, text: 'Six callers, two misordered.' };
  const envelope = task(
    { state: 'running', items: [latest], itemCount: 3 },
    { rev: 5 },
  );
  assert.equal(runComplete(envelope), false);
  assert.equal(runComplete(task({ state: 'running', items })), true);
  assert.equal(
    withRunItems(envelope, undefined),
    envelope,
    'Before the read lands the sheet shows the latest step',
  );
  const read = { itemId: 'task-1', rev: 4, items };
  const merged = withRunItems(envelope, read);
  assert.deepEqual(
    merged.run.items.map((item) => [item.itemId, item.text ?? item.title]),
    [
      ['run-0', 'Trace it.'],
      ['grep', 'Grep verifyToken'],
      ['run-2', 'Six callers, two misordered.'],
    ],
    'A newer latest step replaces its older copy',
  );
  assert.equal(runComplete(merged), true);
  const next = { itemId: 'run-3', rev: 1, type: 'text', text: 'Done.' };
  assert.deepEqual(
    withRunItems(
      task({ state: 'running', items: [next], itemCount: 4 }, { rev: 6 }),
      read,
    ).run.items.map((item) => item.itemId),
    ['run-0', 'grep', 'run-2', 'run-3'],
    'A step the read has not seen yet is appended',
  );
  assert.deepEqual(
    withRunItems(envelope, { ...read, rev: 9 }).run.items.at(-1).text,
    'Six callers.',
    'An envelope older than the read never rolls a step back',
  );
  assert.equal(
    withRunItems(envelope, { ...read, itemId: 'other' }),
    envelope,
    'A read of another task is ignored',
  );
});
