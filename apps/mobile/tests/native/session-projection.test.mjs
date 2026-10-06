import test from 'node:test';
import assert from 'node:assert/strict';
import { LoroDoc, LoroMap, LoroList, LoroText } from 'loro-crdt/base64';
import { loadProject } from '../helpers.mjs';

const { projectSession, projectSessionFull, releaseProjection, subagentRun } =
  await loadProject();

// Stands in for a screenshot an agent read: no projection may need its bytes.
const IMAGE = 'iVBORw0KGgo'.repeat(4096);

function setAll(map, fields) {
  for (const [key, value] of Object.entries(fields)) map.set(key, value);
  return map;
}
function text(map, key, value) {
  map.setContainer(key, new LoroText()).insert(0, value);
}
function toolCall(items, fields) {
  const tool = setAll(items.pushContainer(new LoroMap()), {
    type: 'tool_call',
    ...fields,
  });
  const content = tool.setContainer('content', new LoroList());
  setAll(content.pushContainer(new LoroMap()), {
    type: 'content',
    content: { type: 'image', mimeType: 'image/png', data: IMAGE },
  });
  setAll(content.pushContainer(new LoroMap()), {
    type: 'diff',
    path: 'src/app.ts',
    oldText: 'a\nb\n',
    newText: 'a\nc\nd\n',
  });
  setAll(tool.setContainer('_meta', new LoroMap()), {
    lody: { subagentRaw: { rawOutput: [{ source: { data: IMAGE } }] } },
  });
  setAll(tool.setContainer('rawInput', new LoroMap()), { file: 'shot.png' });
  return tool;
}

function seed(doc) {
  const history = doc.getList('history');
  const user = setAll(history.pushContainer(new LoroMap()), {
    id: 'u1',
    role: 'user',
    status: 'handled',
    timestamp: '2026-10-06T00:00:00.000Z',
  });
  setAll(user.setContainer('inputConfig', new LoroMap()), {
    modelId: 'gpt-test',
    configOptionValues: { effort: 'high', fast: true },
    _lodyDeliveryKind: 'continue',
  });
  text(
    user.setContainer('items', new LoroList()).pushContainer(new LoroMap()),
    'text',
    'Rework the chart page',
  );
  user.get('items').get(0).set('type', 'text');

  const reply = setAll(history.pushContainer(new LoroMap()), {
    id: 'a1',
    role: 'assistant',
    userTurnId: 'u1',
    acpTurnId: 'turn-1',
    finished: false,
    fileDiff: [{ filePath: 'src/app.ts', add: 2, del: 1 }],
    modelInfo: {
      modelId: 'gpt-test',
      name: 'GPT Test',
      _meta: { lodyThoughtLevel: 'high' },
    },
    tokenUsage: {
      inputTokens: 10,
      outputTokens: 5,
      cacheReadInputTokens: 0,
      cacheCreationInputTokens: 0,
      reasoningOutputTokens: 1,
    },
  });
  const items = reply.setContainer('items', new LoroList());
  text(
    setAll(items.pushContainer(new LoroMap()), { type: 'thought' }),
    'text',
    'Look first.',
  );
  const tool = toolCall(items, {
    toolCallId: 'read-1',
    kind: 'other',
    title: 'Read shot.png',
    status: 'completed',
  });
  setAll(tool.setContainer('permissionRequest', new LoroMap()), {
    requestId: 'req-1',
    options: [{ optionId: 'allow', name: 'Allow', kind: 'allow_once' }],
    outcome: null,
  });
  const task = setAll(items.pushContainer(new LoroMap()), {
    type: 'subagent_task',
    taskId: 'task-1',
    status: 'in_progress',
    actor: 'Rework chart page',
  });
  const run = task.setContainer('run', new LoroMap());
  run.set('sessionId', 'child');
  run.set('snapshot', {
    state: 'running',
    modelId: 'gpt-test',
    support: { cancel: true },
  });
  run.set('progress', { totalTokens: 900, toolCallCount: 2 });
  const steps = run.setContainer('items', new LoroList());
  toolCall(steps, {
    toolCallId: 'child-read-1',
    kind: 'read',
    title: 'Read m01.png',
    status: 'completed',
  });
  toolCall(steps, {
    toolCallId: 'child-edit-1',
    kind: 'edit',
    title: 'Edit page.tsx',
    status: 'in_progress',
  });
  text(
    setAll(items.pushContainer(new LoroMap()), { type: 'text' }),
    'text',
    'Working on it',
  );
  doc.getMovableList('mq');
  doc.commit();
}

const lastReply = (doc) => {
  const history = doc.getList('history');
  for (let i = history.length - 1; i >= 0; i--)
    if (history.get(i).get?.('id') === 'a1') return history.get(i);
};
const runSteps = (doc) => lastReply(doc).get('items').get(2).get('run');

// Each change runs on the hub's copy and reaches both replicas as an update.
const changes = [
  [
    'stream reply text',
    (doc) =>
      lastReply(doc)
        .get('items')
        .get(3)
        .get('text')
        .insert(13, ', almost done'),
  ],
  [
    'append a run step',
    (doc) => {
      toolCall(runSteps(doc).get('items'), {
        toolCallId: 'child-read-2',
        kind: 'read',
        title: 'Read m02.png',
        status: 'pending',
      });
    },
  ],
  [
    'finish a middle run step',
    (doc) => runSteps(doc).get('items').get(1).set('status', 'completed'),
  ],
  [
    'update run progress',
    (doc) =>
      runSteps(doc).set('progress', { totalTokens: 1800, toolCallCount: 3 }),
  ],
  [
    'insert an entry before the reply',
    (doc) => {
      const notice = setAll(
        doc.getList('history').insertContainer(1, new LoroMap()),
        {
          id: 'n1',
          role: 'assistant',
          userTurnId: 'u1',
          finished: true,
        },
      );
      setAll(
        notice
          .setContainer('items', new LoroList())
          .pushContainer(new LoroMap()),
        {
          type: 'system_notice',
          name: 'context_compacted',
        },
      );
    },
  ],
  [
    'answer a permission',
    (doc) =>
      lastReply(doc)
        .get('items')
        .get(1)
        .get('permissionRequest')
        .set('outcome', {
          outcome: 'selected',
          optionId: 'allow',
        }),
  ],
  [
    'link a steer',
    (doc) =>
      doc
        .getMap('lodySteerLinks')
        .set('u1', { targetId: 'a1', mode: 'native' }),
  ],
  [
    'push a plain entry',
    (doc) =>
      doc.getList('history').push({
        id: 'u2',
        role: 'user',
        status: 'pending',
        inputConfig: { modelId: 'gpt-next' },
        items: [
          { type: 'text', text: 'And the legend', _meta: { big: IMAGE } },
        ],
      }),
  ],
  ['delete the first entry', (doc) => doc.getList('history').delete(0, 1)],
  [
    'replace an entry under the same id',
    (doc) => {
      const history = doc.getList('history');
      const index = history.toJSON().findIndex((entry) => entry.id === 'n1');
      history.delete(index, 1);
      const again = setAll(history.insertContainer(index, new LoroMap()), {
        id: 'n1',
        role: 'assistant',
        userTurnId: 'u1',
        finished: true,
      });
      setAll(
        again
          .setContainer('items', new LoroList())
          .pushContainer(new LoroMap()),
        {
          type: 'text',
          text: 'Compacted, then resumed',
        },
      );
    },
  ],
  [
    'queue a message',
    (doc) =>
      setAll(doc.getMovableList('mq').pushContainer(new LoroMap()), {
        task: 'Then the dark theme',
        userTurnId: 'q1',
        timestamp: 3,
      }),
  ],
  [
    'finish the reply',
    (doc) => {
      lastReply(doc).set('finished', true);
      runSteps(doc).set('snapshot', {
        state: 'completed',
        modelId: 'gpt-test',
      });
    },
  ],
];

const comparable = ({ revision, ...envelope }) => envelope;

function assertSame(incremental, full, label, options = {}) {
  const pending = options.pending;
  assert.deepEqual(
    comparable(projectSession(incremental, 'live', undefined, pending)),
    comparable(projectSessionFull(full, 'live', undefined, pending)),
    label,
  );
}

function replicate(server, replicas, change) {
  const from = server.version();
  change(server);
  server.commit();
  const update = server.export({ mode: 'update', from });
  for (const doc of replicas) doc.import(update);
}

test('incremental projection equals a full projection through every kind of change', () => {
  const server = new LoroDoc();
  seed(server);
  const snapshot = server.export({ mode: 'snapshot' });
  const incremental = new LoroDoc();
  const full = new LoroDoc();
  incremental.import(snapshot);
  full.import(snapshot);
  assertSame(incremental, full, 'bootstrap');
  for (const [label, change] of changes) {
    replicate(server, [incremental, full], change);
    assertSame(incremental, full, label);
  }
});

test('changes between projections, unsent answers and local writes stay equal', () => {
  const server = new LoroDoc();
  seed(server);
  const incremental = new LoroDoc();
  const full = new LoroDoc();
  incremental.import(server.export({ mode: 'snapshot' }));
  full.import(server.export({ mode: 'snapshot' }));
  assertSame(incremental, full, 'bootstrap');
  // Several updates land before the next flush.
  for (const [, change] of changes.slice(0, 5))
    replicate(server, [incremental, full], change);
  assertSame(incremental, full, 'batched updates');
  // An answer the hub has not acknowledged shows as still pending.
  const itemId = 'read-1';
  const pending = new Map([
    [`a1/${itemId}/req-1`, { outcome: 'selected', optionId: 'allow' }],
  ]);
  for (const doc of [incremental, full]) {
    lastReply(doc)
      .get('items')
      .get(1)
      .get('permissionRequest')
      .set('outcome', { outcome: 'selected', optionId: 'allow' });
    doc.commit();
  }
  assertSame(incremental, full, 'unsent answer', { pending });
  const sent = projectSession(incremental, 'live', undefined, pending);
  assert.equal(
    sent.entries.find((entry) => entry.id === 'a1').items[1].permission.pending,
    true,
  );
  assertSame(incremental, full, 'acknowledged answer');
  // Checking out an older version and back re-reads every entry.
  const frontiers = [incremental, full].map((doc) => doc.frontiers());
  replicate(server, [incremental, full], changes[5][1]);
  [incremental, full].forEach((doc, i) => doc.checkout(frontiers[i]));
  assertSame(incremental, full, 'checkout');
  for (const doc of [incremental, full]) doc.checkoutToLatest();
  assertSame(incremental, full, 'latest again');
});

test('a re-read or evicted replica projects the same history from scratch', () => {
  const server = new LoroDoc();
  seed(server);
  const live = new LoroDoc();
  live.import(server.export({ mode: 'snapshot' }));
  projectSession(live, 'live');
  for (const [, change] of changes) replicate(server, [live], change);
  const reread = new LoroDoc();
  reread.import(server.export({ mode: 'snapshot' }));
  const reference = new LoroDoc();
  reference.import(server.export({ mode: 'snapshot' }));
  assertSame(reread, reference, 'bootstrap from a newer snapshot');
  releaseProjection(live);
  const fresh = new LoroDoc();
  fresh.import(server.export({ mode: 'snapshot' }));
  assert.deepEqual(
    comparable(projectSession(live, 'live')),
    comparable(projectSessionFull(fresh, 'live')),
    'A released replica starts over like a new one',
  );
});

test('the envelope carries a run as its latest step and the sheet reads the rest without payloads', () => {
  const doc = new LoroDoc();
  seed(doc);
  const envelope = projectSession(doc, 'live');
  const task = envelope.entries
    .find((entry) => entry.id === 'a1')
    .items.find((item) => item.type === 'subagent_task');
  assert.equal(task.run.itemCount, 2);
  assert.deepEqual(
    task.run.items.map((item) => item.itemId),
    ['child-edit-1'],
  );
  assert.ok(
    JSON.stringify(envelope).length < 8000,
    'Screenshots never reach the envelope',
  );
  const run = subagentRun(
    doc,
    'a1',
    task.itemId,
    lastReply(doc).get('items').get(2),
  );
  assert.deepEqual(
    run.items.map((item) => [item.itemId, item.status, item.hasDetail]),
    [
      ['child-read-1', 'completed', true],
      ['child-edit-1', 'in_progress', true],
    ],
  );
  assert.deepEqual(
    [run.items[0].path, run.items[0].added, run.items[0].removed],
    ['src/app.ts', 2, 1],
  );
  assert.ok(JSON.stringify(run).length < 4000);
});
