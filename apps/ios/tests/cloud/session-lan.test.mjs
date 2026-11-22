import assert from 'node:assert/strict';
import test from 'node:test';
import { LoroDoc, LoroList, LoroMap, LoroText } from 'loro-crdt/base64';
import { loadProject, loadRuntime, openTestSession } from '../helpers.mjs';

const settled = async (check) => {
  for (let i = 0; i < 400; i++) {
    const value = check();
    if (value) return value;
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
  assert.fail('the session replica did not settle');
};

test('a Continue turn carries Lody’s delivery marker into history and the projection', async () => {
  const calls = [];
  const fixture = await openTestSession({
    onRpc: (request) => {
      calls.push(request);
      return { result: { accepted: true } };
    },
  });
  const args = {
    sessionId: 's1',
    machineId: 'm1',
    userId: 'u1',
    cliType: 'builtin',
    agentType: 'claude',
  };
  try {
    assert.equal(
      (
        await fixture.runtime.sendTurn({
          ...args,
          text: 'Continue from where you left off.',
          deliveryKind: 'continue',
        })
      ).state,
      'accepted',
    );
    assert.equal(
      (await fixture.runtime.sendTurn({ ...args, text: 'Plain turn' })).state,
      'queued',
    );
    const raw = fixture.server.toJSON();
    assert.equal(raw.history[0].inputConfig._lodyDeliveryKind, 'continue');
    assert.equal(calls[0].params.inputConfig._lodyDeliveryKind, 'continue');
    assert.equal(raw.mq[0].acpSessionConfig._lodyDeliveryKind, undefined);
    const [entry] = fixture.runtime.projectSession(
      fixture.server,
      'live',
    ).entries;
    assert.equal(entry.deliveryKind, 'continue');
  } finally {
    fixture.close();
  }
});

test('a Role session keeps its Role, instance record and memory while the run configuration is unchanged and records None without them once a control moves', async () => {
  const calls = [];
  const fixture = await openTestSession({
    onRpc: (request) => {
      calls.push(request);
      return { result: { accepted: true } };
    },
  });
  const args = {
    sessionId: 's1',
    machineId: 'm1',
    userId: 'u1',
    cliType: 'acp',
    agentType: 'claude',
    text: 'Synthetic Role follow-up',
  };
  const memory = { providerId: 'nowledge-mem', memoryId: 'reviewer' };
  const snapshot = {
    id: 'role-1',
    revision: 4,
    name: 'Reviewer',
    emoji: '🪼',
    instanceId: 'instance-1',
    instanceLabel: 'Claude Code',
  };
  const finish = async () => {
    fixture.server.getList('history').push({
      id: `reply-${calls.length}`,
      role: 'assistant',
      finished: true,
      items: [],
    });
    fixture.server.commit();
    await fixture.pushUpdate();
  };
  try {
    fixture.server.getList('history').push({
      id: 'role-turn',
      role: 'user',
      finished: true,
      items: [],
      inputConfig: {
        modeId: 'auto',
        modelId: 'opus',
        configOptionValues: { effort: 'high', fast: false },
        agentRoleId: 'role-1',
        agentRoleRevision: 4,
        agentRoleSnapshot: snapshot,
        memory,
      },
    });
    await finish();
    assert.equal((await fixture.runtime.sendTurn(args)).state, 'accepted');
    assert.equal(calls[0].params.inputConfig.agentRoleId, 'role-1');
    assert.equal(calls[0].params.inputConfig.agentRoleRevision, 4);
    assert.deepEqual(calls[0].params.inputConfig.agentRoleSnapshot, snapshot);
    assert.deepEqual(
      calls[0].params.inputConfig.memory,
      memory,
      'A turn without the binding makes the machine restart the agent without its memory',
    );
    assert.equal(
      fixture.server.toJSON().history.at(-1).inputConfig.agentRoleId,
      'role-1',
      'The durable turn names the Role it ran as',
    );
    assert.deepEqual(
      fixture.server.toJSON().history.at(-1).inputConfig.memory,
      memory,
      'The next turn inherits from the durable one',
    );
    await finish();
    assert.equal(
      (
        await fixture.runtime.sendTurn({
          ...args,
          modelId: 'opus',
          reasoningEffort: 'high',
          reasoningEffortConfigId: 'effort',
        })
      ).state,
      'accepted',
      'Restating the Role values is not a change',
    );
    assert.equal(calls[1].params.inputConfig.agentRoleId, 'role-1');
    await finish();
    assert.equal(
      (await fixture.runtime.sendTurn({ ...args, modelId: 'sonnet' })).state,
      'accepted',
    );
    assert.equal(calls[2].params.inputConfig.agentRoleId, null);
    assert.equal(calls[2].params.inputConfig.agentRoleRevision, undefined);
    assert.equal(
      calls[2].params.inputConfig.agentRoleSnapshot,
      undefined,
      'The instance record leaves with the Role it describes',
    );
    assert.equal(
      calls[2].params.inputConfig.memory,
      undefined,
      'The memory is the instance’s and leaves with it',
    );
    assert.equal(
      'memory' in fixture.server.toJSON().history.at(-1).inputConfig,
      false,
    );
    assert.equal(
      fixture.server.toJSON().history.at(-1).inputConfig.agentRoleId,
      null,
    );
    await finish();
    assert.equal((await fixture.runtime.sendTurn(args)).state, 'accepted');
    assert.equal(
      calls[3].params.inputConfig.agentRoleId,
      null,
      'Once None, a later turn does not return to the Role',
    );
    assert.equal(calls[3].params.inputConfig.memory, undefined);
  } finally {
    fixture.close();
  }
});

test('memory follows a session without a Role record into dispatched and queued turns, and not a turn recorded as None', async () => {
  const memory = { providerId: 'nowledge-mem', memoryId: 'reviewer' };
  const send = async (inputConfig) => {
    const calls = [];
    const fixture = await openTestSession({
      onRpc: (request) => {
        calls.push(request);
        return { result: { accepted: true } };
      },
    });
    const args = {
      sessionId: 's1',
      machineId: 'm1',
      userId: 'u1',
      cliType: 'builtin',
      agentType: 'claude',
      text: 'Synthetic memory follow-up',
    };
    try {
      const history = fixture.server.getList('history');
      history.push({
        id: 'first',
        role: 'user',
        finished: true,
        items: [],
        inputConfig,
      });
      history.push({
        id: 'reply',
        role: 'assistant',
        finished: true,
        items: [],
      });
      fixture.server.commit();
      await fixture.pushUpdate();
      assert.equal((await fixture.runtime.sendTurn(args)).state, 'accepted');
      assert.equal((await fixture.runtime.sendTurn(args)).state, 'queued');
      return {
        dispatched: calls[0].params.inputConfig,
        queued: fixture.server.toJSON().mq[0].acpSessionConfig,
      };
    } finally {
      fixture.close();
    }
  };
  const inherited = await send({ modelId: 'opus', memory });
  assert.deepEqual(inherited.dispatched.memory, memory);
  assert.deepEqual(inherited.queued.memory, memory);
  assert.equal('agentRoleId' in inherited.dispatched, false);
  const none = await send({ modelId: 'opus', memory, agentRoleId: null });
  assert.equal(none.dispatched.agentRoleId, null);
  assert.equal(none.dispatched.memory, undefined);
  assert.equal('memory' in none.queued, false);
});

test('the next turn and the composer follow the newest queued turn before history, as Lody resolves a conversation', async () => {
  const instance = (name) => ({
    agentRoleId: `role-${name}`,
    agentRoleRevision: 2,
    agentRoleSnapshot: {
      id: `role-${name}`,
      revision: 2,
      name,
      emoji: '🪼',
      instanceId: `instance-${name}`,
    },
    memory: { providerId: 'nowledge-mem', memoryId: name },
  });
  const send = async (queuedConfig) => {
    const fixture = await openTestSession({
      onRpc: () => ({ result: { accepted: true } }),
    });
    try {
      const history = fixture.server.getList('history');
      history.push({
        id: 'first',
        role: 'user',
        finished: true,
        items: [],
        inputConfig: {
          modelId: 'opus',
          mcpServerIds: ['history'],
          ...instance('a'),
        },
      });
      history.push({
        id: 'reply',
        role: 'assistant',
        finished: true,
        items: [],
      });
      // Another client queued a turn after the one history ends with.
      fixture.server.getMovableList('mq').push({
        task: 'Synthetic queued turn',
        userId: 'u2',
        userTurnId: 'queued',
        timestamp: new Date().toISOString(),
        acpSessionConfig: queuedConfig,
      });
      fixture.server.commit();
      await fixture.pushUpdate();
      const composer = fixture.runtime.projectSession(
        fixture.server,
        'live',
      ).composer;
      assert.equal(
        (
          await fixture.runtime.sendTurn({
            sessionId: 's1',
            machineId: 'm1',
            userId: 'u1',
            cliType: 'builtin',
            agentType: 'claude',
            text: 'Synthetic follow-up',
          })
        ).state,
        'queued',
      );
      return { composer, sent: fixture.server.toJSON().mq[1].acpSessionConfig };
    } finally {
      fixture.close();
    }
  };
  const other = await send({
    modelId: 'sonnet',
    mcpServerIds: ['queue'],
    ...instance('b'),
  });
  assert.equal(other.composer.modelId, 'sonnet');
  assert.equal(other.sent.modelId, 'sonnet');
  assert.deepEqual(other.sent.mcpServerIds, ['queue']);
  assert.equal(other.sent.agentRoleId, 'role-b');
  assert.deepEqual(
    other.sent.agentRoleSnapshot,
    instance('b').agentRoleSnapshot,
  );
  assert.deepEqual(
    other.sent.memory,
    instance('b').memory,
    'Returning to the memory history ends with would restart the agent the queue left running',
  );
  const none = await send({ modelId: 'opus', agentRoleId: null });
  assert.equal(none.sent.agentRoleId, null);
  assert.equal('agentRoleSnapshot' in none.sent, false);
  assert.equal(
    'memory' in none.sent,
    false,
    'A queue that ends in None is not followed by the Role history named',
  );
  const sticky = await send({ modelId: 'opus' });
  assert.equal(
    sticky.sent.agentRoleId,
    'role-a',
    'A queued turn that names no Role leaves the one before it standing',
  );
  assert.equal('memory' in sticky.sent, false);
});

test('a turn projects who wrote it, and a record of another shape is no author', async () => {
  const { projectSession, projectSessionFull } = await loadProject();
  const doc = new LoroDoc();
  const history = doc.getList('history');
  const agent = {
    v: 1,
    kind: 'agent',
    sessionId: 'coordinator',
    turnId: 'turn-1',
    agentConfigId: 'config-1',
    cliType: 'builtin',
    agentType: 'claude',
    name: ' Claude Code ',
    role: {
      id: 'role-1',
      revision: 3,
      name: 'Reviewer',
      emoji: '🪼',
      instanceId: 'instance-1',
      instanceLabel: 'Fable',
    },
    model: { id: 'opus', name: 'Opus 5.5', source: 'runtime' },
    reasoningEffort: 'high',
  };
  const authors = {
    human: { v: 1, kind: 'human', userId: 'u1' },
    system: { v: 1, kind: 'system' },
    agent,
    bare: {
      ...agent,
      role: undefined,
      model: { id: 'opus', source: 'configured' },
    },
    legacy: undefined,
    future: { ...agent, v: 2 },
    unnamed: { ...agent, name: ' ' },
    'bad-role': { ...agent, role: { ...agent.role, name: 7 } },
    'bad-model': { ...agent, model: { name: 'Opus 5.5' } },
    anonymous: { v: 1, kind: 'human' },
    unknown: { v: 1, kind: 'robot', name: 'Claude Code' },
    text: 'Claude Code',
  };
  for (const [id, author] of Object.entries(authors)) {
    const entry = history.pushContainer(new LoroMap());
    entry.set('id', id);
    entry.set('role', 'user');
    entry.set('finished', true);
    entry.setContainer('items', new LoroList());
    if (author !== undefined)
      entry.set('author', JSON.parse(JSON.stringify(author)));
  }
  doc.commit();
  const projected = Object.fromEntries(
    projectSession(doc, 'live').entries.map((entry) => [
      entry.id,
      entry.author,
    ]),
  );
  assert.deepEqual(projected, {
    human: { kind: 'human' },
    system: { kind: 'system' },
    agent: {
      kind: 'agent',
      name: 'Claude Code',
      role: { name: 'Reviewer', emoji: '🪼', instanceLabel: 'Fable' },
      model: 'Opus 5.5',
    },
    bare: { kind: 'agent', name: 'Claude Code', model: 'opus' },
    legacy: undefined,
    future: undefined,
    unnamed: undefined,
    'bad-role': undefined,
    'bad-model': undefined,
    anonymous: undefined,
    unknown: undefined,
    text: undefined,
  });
  assert.deepEqual(
    projectSessionFull(doc, 'live').entries.map((entry) => entry.author),
    projectSession(doc, 'live').entries.map((entry) => entry.author),
  );
});

test('the envelope carries the latest run step; the run sheet reads every step in transcript item shape', async () => {
  const { projectSession, subagentRun } = await loadProject();
  const doc = new LoroDoc();
  const entry = doc.getList('history').pushContainer(new LoroMap());
  entry.set('id', 'e-run');
  entry.set('role', 'assistant');
  const task = entry
    .setContainer('items', new LoroList())
    .pushContainer(new LoroMap());
  task.set('type', 'subagent_task');
  task.set('taskId', 'run-1');
  task.set('status', 'in_progress');
  const run = task.setContainer('run', new LoroMap());
  run.set('sessionId', 'acp-root');
  run.set('snapshot', {
    state: 'running',
    modelId: 'gpt-5-codex',
    outputIncomplete: true,
    support: { stream: ['text', 'tool'], cancel: true },
  });
  run.set('progress', {
    totalTokens: 3100,
    toolCallCount: 7,
    contextUsagePercent: 18,
  });
  const items = run.setContainer('items', new LoroList());
  const thought = items.pushContainer(new LoroMap());
  thought.set('type', 'thought');
  thought.set('text', 'Trace verifyToken.');
  const tool = items.pushContainer(new LoroMap());
  tool.set('type', 'tool_call');
  tool.set('toolCallId', 'grep-1');
  tool.set('kind', 'search');
  tool.set('status', 'completed');
  tool.set('title', 'Grep verifyToken');
  const text = items.pushContainer(new LoroMap());
  text.set('type', 'text');
  text.setContainer('text', new LoroText()).insert(0, 'Six callers.');
  doc.commit();
  const item = projectSession(doc, 'live').entries[0].items[0];
  assert.deepEqual(
    {
      state: item.run.state,
      modelId: item.run.modelId,
      outputIncomplete: item.run.outputIncomplete,
      cancel: item.run.cancel,
      totalTokens: item.run.totalTokens,
      toolCallCount: item.run.toolCallCount,
      contextUsagePercent: item.run.contextUsagePercent,
    },
    {
      state: 'running',
      modelId: 'gpt-5-codex',
      outputIncomplete: true,
      cancel: true,
      totalTokens: 3100,
      toolCallCount: 7,
      contextUsagePercent: 18,
    },
  );
  assert.equal(item.run.itemCount, 3);
  assert.deepEqual(
    item.run.items.map((i) => [i.type, i.text]),
    [['text', 'Six callers.']],
    'The session envelope carries only the latest step',
  );
  const full = subagentRun(doc, 'e-run', item.itemId, task);
  assert.deepEqual(
    full.items.map((i) => [i.type, i.text ?? i.title]),
    [
      ['thought', 'Trace verifyToken.'],
      ['tool_call', 'Grep verifyToken'],
      ['text', 'Six callers.'],
    ],
  );
  assert.equal(full.items[1].itemId, JSON.stringify([item.itemId, 'grep-1']));
  assert.equal(full.items.at(-1).rev, item.run.items[0].rev);
  // A step before the latest one still moves the task's rev.
  tool.set('status', 'failed');
  doc.commit();
  const middle = projectSession(doc, 'live').entries[0].items[0];
  assert.deepEqual(middle.run.items, item.run.items);
  assert.ok(middle.rev > item.rev);
  assert.equal(
    subagentRun(doc, 'e-run', item.itemId, task).items[1].status,
    'failed',
  );
  const before = middle.rev;
  doc
    .getList('history')
    .get(0)
    .get('items')
    .get(0)
    .get('run')
    .get('items')
    .get(2)
    .get('text')
    .insert(12, ' Two misorder the cookie.');
  doc.commit();
  const next = projectSession(doc, 'live').entries[0].items[0];
  assert.equal(next.run.items[0].text, 'Six callers. Two misorder the cookie.');
  assert.ok(next.rev > before);
});

test('a LAN file names the machine that keeps it and the digest it is fetched against', async () => {
  const { projectSession } = await loadProject();
  const doc = new LoroDoc();
  const entry = doc.getList('history').pushContainer(new LoroMap());
  entry.set('id', 'lan');
  entry.set('role', 'user');
  const file = entry
    .setContainer('items', new LoroList())
    .pushContainer(new LoroMap());
  for (const [key, value] of Object.entries({
    type: 'file',
    fileId: 'file-1',
    fileName: 'photo.jpg',
    mimeType: 'image/jpeg',
    sizeBytes: 2048,
    sha256: 'b'.repeat(64),
    textPreview: false,
    transport: 'local',
    machineId: 'desk',
    uploadedAt: 1,
  }))
    file.set(key, value);
  doc.commit();
  assert.deepEqual(projectSession(doc, 'live').entries[0].items[0].file, {
    id: 'file-1',
    fileName: 'photo.jpg',
    transport: 'local',
    sizeBytes: 2048,
    storageSessionId: undefined,
    machineId: 'desk',
    sha256: 'b'.repeat(64),
    mimeType: 'image/jpeg',
  });
});

test(
  'a read below the start of a compacted stream bootstraps a fresh replica instead of retrying the offset',
  { timeout: 8000 },
  async (t) => {
    const bootstraps = [];
    const reads = [];
    const events = [];
    const history = new LoroDoc();
    let recovered;
    const recovery = new Promise((resolve) => {
      recovered = resolve;
    });
    globalThis.__sessionClient = class {
      async bootstrap() {
        const offset = bootstraps.length ? '20' : '7';
        bootstraps.push(offset);
        return {
          ok: true,
          result: {
            snapshotOffset: offset,
            snapshot: { body: history.export({ mode: 'snapshot' }) },
            updates: [],
            nextOffset: offset,
            cursor: `cursor-${offset}`,
            upToDate: true,
          },
        };
      }
      async readOnce(request) {
        reads.push(request.offset);
        if (request.offset === '7')
          return { ok: false, result: { code: 'gone' } };
        recovered();
        return new Promise((resolve, reject) => {
          request.signal.addEventListener(
            'abort',
            () => reject(request.signal.reason),
            { once: true },
          );
        });
      }
      append() {
        assert.fail('read recovery must never append');
      }
    };
    const runtime = await loadRuntime();
    runtime.appendUserTurn(
      history,
      'saved-turn',
      'Existing message',
      'u1',
      {},
      '2026-09-11T00:00:00Z',
    );
    t.after(() => {
      runtime.stopSessions();
      delete globalThis.__sessionClient;
    });
    await runtime.openSession(
      'compacted',
      'w1',
      async () => ({
        token: 'synthetic',
        gatewayBaseUrl: 'https://x.invalid',
      }),
      (event) => events.push(JSON.parse(event.session)),
      async () => {
        assert.fail('read recovery must never dispatch');
      },
    );
    await recovery;
    assert.deepEqual(bootstraps, ['7', '20']);
    assert.deepEqual(reads, ['7', '20']);
    assert.equal(events.at(-1).status, 'live');
    assert.equal(events.at(-1).entries.length, 1);
    assert.ok(events.every((event) => event.status !== 'offline'));
  },
);

test('a turn the hub never received leaves the replica and is offered again under a new id', async () => {
  let fail = false;
  const fixture = await openTestSession({
    failAppend: () => fail,
    onRpc: () => ({ result: { accepted: true } }),
  });
  try {
    const args = {
      sessionId: 's1',
      machineId: 'm1',
      userId: 'u1',
      text: 'lost',
      cliType: 'builtin',
      agentType: 'codex',
    };
    const confirm = (id) =>
      fixture.runtime.confirmTurn({ sessionId: 's1', id });
    fail = true;
    const lost = await fixture.runtime.sendTurn(args);
    assert.equal(lost.state, 'unknown');
    const verdict = await settled(() => {
      const value = confirm(lost.id);
      return value.state === 'pending' ? undefined : value;
    });
    assert.equal(verdict.state, 'absent');
    assert.match(
      verdict.retryId,
      /^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$/,
    );
    assert.notEqual(verdict.retryId, lost.id);
    await settled(() => fixture.events.at(-1).status === 'live');
    assert.ok(
      fixture.events.every(
        (event) => !event.entries?.some((entry) => entry.id === lost.id),
      ),
      'an unacknowledged write is never shown as history',
    );
    const appends = fixture.appends.length;
    assert.equal(
      (await fixture.runtime.sendTurn({ ...args, id: lost.id })).reason,
      'turn_already_exists',
    );
    assert.equal(
      fixture.appends.length,
      appends,
      'the lost id is never written again',
    );
    fail = false;
    const retried = await fixture.runtime.sendTurn({
      ...args,
      id: verdict.retryId,
    });
    assert.equal(retried.state, 'accepted');
    assert.deepEqual(
      fixture.server.toJSON().history.map((entry) => entry.id),
      [verdict.retryId],
    );
  } finally {
    fixture.close();
  }
});

test('a turn whose acknowledgement was lost is confirmed from the hub, not from the local write', async () => {
  let lose = false;
  const fixture = await openTestSession({ loseAck: () => lose });
  try {
    const args = {
      sessionId: 's1',
      machineId: 'm1',
      userId: 'u1',
      text: 'kept',
      cliType: 'builtin',
      agentType: 'codex',
    };
    const confirm = (id) =>
      fixture.runtime.confirmTurn({ sessionId: 's1', id });
    const gate = Promise.withResolvers();
    const id = '11111111-1111-4111-8111-111111111111';
    lose = true;
    const sending = fixture.runtime.sendTurn({ ...args, id }, async (text) => {
      await gate.promise;
      return text;
    });
    assert.deepEqual(
      confirm(id),
      { state: 'pending' },
      'a send in flight is not settled',
    );
    gate.resolve();
    assert.equal((await sending).state, 'unknown');
    const verdict = await settled(() => {
      const value = confirm(id);
      return value.state === 'pending' ? undefined : value;
    });
    assert.deepEqual(verdict, { state: 'uploaded', undispatched: true });
    fixture.server
      .getList('history')
      .push({ id: 'reply', role: 'assistant', finished: false, items: [] });
    fixture.server.commit();
    await fixture.pushUpdate();
    assert.deepEqual(confirm(id), { state: 'uploaded', undispatched: false });

    lose = false;
    const queued = await fixture.runtime.sendTurn({ ...args, text: 'next' });
    assert.equal(queued.state, 'queued');
    assert.deepEqual(confirm(queued.id), { state: 'queued' });
  } finally {
    fixture.close();
  }
});

test('a replica the hub has not answered lately asks before writing, and a dead route writes nothing', async (t) => {
  let alive = false;
  const fixture = await openTestSession({
    reachable: () => alive,
    onRpc: () => ({ result: { accepted: true } }),
  });
  try {
    const args = {
      sessionId: 's1',
      machineId: 'm1',
      userId: 'u1',
      text: 'after a suspension',
      cliType: 'builtin',
      agentType: 'codex',
    };
    t.mock.timers.enable({ apis: ['Date'], now: Date.now() });
    t.mock.timers.tick(fixture.runtime.REPLICA_FRESH_MS + 1);
    const reads = fixture.reads.length;
    const refused = await fixture.runtime.sendTurn(args);
    assert.deepEqual(
      { state: refused.state, reason: refused.reason },
      { state: 'not_sent', reason: 'session_not_ready' },
    );
    assert.equal(fixture.probes.length, 1);
    assert.equal(
      fixture.appends.length,
      0,
      'nothing is written into a dead route',
    );
    assert.equal(fixture.server.toJSON().history, undefined);
    await settled(() => fixture.reads.length > reads);
    assert.equal(
      fixture.events.at(-1).status,
      'syncing',
      'the stalled read is restarted instead of waiting out its timeout',
    );
    assert.deepEqual(
      fixture.runtime.confirmTurn({ sessionId: 's1', id: refused.id }),
      { state: 'pending' },
    );

    alive = true;
    await fixture.pushUpdate();
    t.mock.timers.tick(fixture.runtime.REPLICA_FRESH_MS + 1);
    const sent = await fixture.runtime.sendTurn({ ...args, id: refused.id });
    assert.equal(
      sent.state,
      'accepted',
      'the same message goes once the hub answers',
    );
    assert.equal(fixture.probes.length, 2);
    assert.deepEqual(
      fixture.server.toJSON().history.map((entry) => entry.id),
      [refused.id],
    );

    const probes = fixture.probes.length;
    fixture.server
      .getList('history')
      .push({ id: 'reply', role: 'assistant', finished: true, items: [] });
    fixture.server.commit();
    await fixture.pushUpdate();
    assert.equal((await fixture.runtime.sendTurn(args)).state, 'accepted');
    assert.equal(
      fixture.probes.length,
      probes,
      'a replica the hub just answered is not probed again',
    );
  } finally {
    fixture.close();
  }
});

test('turn, pointer and dispatch request are appended under producer tuples the hub can deduplicate', async () => {
  const fixture = await openTestSession({
    onRpc: () => ({ result: { accepted: true } }),
  });
  try {
    const sent = await fixture.runtime.sendTurn({
      sessionId: 's1',
      machineId: 'm1',
      userId: 'u1',
      text: 'once',
      cliType: 'builtin',
      agentType: 'codex',
    });
    assert.equal(sent.state, 'accepted');
    assert.equal(
      fixture.producers.length,
      2,
      'the turn and its dispatch request',
    );
    for (const producer of fixture.producers) {
      assert.match(producer.producerId, /^[0-9a-f-]{36}$/);
      assert.deepEqual(
        { epoch: producer.epoch, seq: producer.seq },
        { epoch: 0, seq: 0 },
      );
    }
    assert.notEqual(
      fixture.producers[0].producerId,
      fixture.producers[1].producerId,
      'each write has its own tuple, so no sequence can gap',
    );
  } finally {
    fixture.close();
  }
});

test('a guide whose target finishes during MCP selection uses ordinary dispatch', async () => {
  const requests = [];
  const fixture = await openTestSession({
    onRpc: (request) => {
      requests.push(request);
      return { result: { accepted: true, applied: false } };
    },
  });
  try {
    const history = fixture.server.getList('history');
    const reply = history.pushContainer(new LoroMap());
    reply.set('id', 'running');
    reply.set('role', 'assistant');
    reply.set('finished', false);
    reply.set('items', []);
    fixture.server.commit();
    await fixture.pushUpdate();
    const sent = await fixture.runtime.sendTurn(
      {
        sessionId: 's1',
        machineId: 'm1',
        userId: 'u1',
        text: 'follow-up',
        cliType: 'builtin',
        agentType: 'codex',
        guide: true,
      },
      undefined,
      async () => {
        reply.set('finished', true);
        fixture.server.commit();
        await fixture.pushUpdate();
        return [];
      },
    );
    assert.equal(sent.state, 'accepted');
    assert.deepEqual(
      requests.map((request) => request.method),
      ['session/dispatch-turn'],
    );
    const turn = fixture.server
      .toJSON()
      .history.find((entry) => entry.id === sent.id);
    assert.notEqual(turn.status, 'pending_apply');
    assert.equal(turn.inputConfig._lodySteerTarget, undefined);
  } finally {
    fixture.close();
  }
});
