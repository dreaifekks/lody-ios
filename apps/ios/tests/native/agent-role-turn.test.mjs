import assert from 'node:assert/strict';
import test from 'node:test';
import { Flock } from '@loro-dev/flock-wasm/base64';
import { openTestSession } from '../helpers.mjs';

// A new session's first turn may run as an Agent Role (web chat landing): only
// the id crosses, and the runtime reads the fresh row itself.
const role = (patch = {}) => ({
  v: 1,
  id: 'reviewer',
  ownerUserId: 'u1',
  visibility: 'private',
  name: 'Reviewer',
  promptPrefix: 'Review carefully.',
  machineId: 'm1',
  agentConfigId: 'a1',
  runConfig: {
    modelId: 'gpt',
    configOptionValues: { api_key: 'fixture-secret', plan_mode: true },
    memory: { providerId: 'p', memoryId: 'mem' },
  },
  revision: 3,
  createdAt: 1,
  updatedAt: 1,
  ...patch,
});
const settingsWith = (value) => () => {
  const flock = new Flock(`settings-${crypto.randomUUID()}`);
  flock.set(['agentRole', 'reviewer'], value);
  flock.commit();
  return flock.exportFile();
};
// The second turn either dispatched (its RPC) or waits in the session's queue.
const laterConfig = (f, calls) =>
  calls[1]?.params.inputConfig ??
  f.server.toJSON().mq?.at(-1)?.acpSessionConfig;
const outcome = (result) => ({ state: result.state, reason: result.reason });
const turn = {
  sessionId: 's1',
  machineId: 'm1',
  userId: 'u1',
  cliType: 'builtin',
  agentType: 'codex',
  text: 'Fix the bug',
  agentRoleId: 'reviewer',
  agentConfigId: 'a1',
  modelId: 'gpt',
};

test('a first turn runs as the Role only while it is bound to the session and its pins still hold', async () => {
  const calls = [];
  const f = await openTestSession({
    settings: settingsWith(role()),
    onRpc(request) {
      calls.push(request);
      return { result: { accepted: true } };
    },
  });
  try {
    const before = f.appends.length;
    // Another Agent Config on the same machine is not this Role's binding.
    assert.deepEqual(
      outcome(await f.runtime.sendTurn({ ...turn, agentConfigId: 'a2' })),
      {
        state: 'not_sent',
        reason: 'role_unavailable',
      },
    );
    // Moving a pinned value (the model) means the Role is no longer what will run.
    assert.deepEqual(
      outcome(await f.runtime.sendTurn({ ...turn, modelId: 'other' })),
      {
        state: 'not_sent',
        reason: 'role_changed',
      },
    );
    assert.equal(f.appends.length, before, 'refusals write nothing');

    // An independent Plan toggle is a per-turn override and keeps the Role.
    const sent = await f.runtime.sendTurn({
      ...turn,
      configOptionValues: { plan_mode: false },
    });
    assert.equal(sent.state, 'accepted');
    const config = calls[0].params.inputConfig;
    assert.equal(config.prompt, 'Review carefully.\n\nFix the bug');
    assert.deepEqual(config.inputBlocks, [
      { type: 'text', text: 'Fix the bug' },
    ]);
    assert.equal(config.agentRoleId, 'reviewer');
    assert.equal(config.agentRoleRevision, 3);
    assert.deepEqual(config.memory, { providerId: 'p', memoryId: 'mem' });
    assert.deepEqual(config.agentRoleSnapshot, {
      id: 'reviewer',
      revision: 3,
      name: 'Reviewer',
      emoji: '🪼',
    });
    assert.equal(JSON.stringify(config).includes('fixture-secret'), false);
    // The composer reopens on the Role the latest turn ran as (web `sessionConversationConfig`).
    assert.equal(
      f.runtime.projectSession(f.server, 'live').composer.agentRoleId,
      'reviewer',
    );
  } finally {
    f.close();
  }
});

// Web's session composer: a Role picked mid-conversation runs the turn with its pins and
// provenance, but its instruction only ever starts a conversation.
test('a later turn runs as a Role without repeating its instruction', async () => {
  const calls = [];
  const f = await openTestSession({
    settings: settingsWith(role()),
    onRpc(request) {
      calls.push(request);
      return { result: { accepted: true } };
    },
  });
  try {
    const { agentRoleId: _, ...plain } = turn;
    assert.equal(
      (await f.runtime.sendTurn({ ...plain, text: 'First' })).state,
      'accepted',
    );
    const later = await f.runtime.sendTurn({
      ...turn,
      configOptionValues: { plan_mode: true },
      text: 'Again',
      queue: true,
    });
    assert.notEqual(later.state, 'not_sent', later.reason);
    const config = laterConfig(f, calls);
    assert.ok(config, 'the later turn reached the session');
    assert.equal(config.prompt, 'Again');
    assert.equal(config.agentRoleId, 'reviewer');
    assert.equal(config.agentRoleRevision, 3);
    assert.deepEqual(config.memory, { providerId: 'p', memoryId: 'mem' });
    assert.deepEqual(config.agentRoleSnapshot, {
      id: 'reviewer',
      revision: 3,
      name: 'Reviewer',
      emoji: '🪼',
    });
  } finally {
    f.close();
  }
});

test('an explicit None ends the Role a conversation was running as', async () => {
  const calls = [];
  const f = await openTestSession({
    settings: settingsWith(role()),
    onRpc(request) {
      calls.push(request);
      return { result: { accepted: true } };
    },
  });
  try {
    assert.equal(
      (
        await f.runtime.sendTurn({
          ...turn,
          configOptionValues: { plan_mode: true },
        })
      ).state,
      'accepted',
    );
    const later = await f.runtime.sendTurn({
      ...turn,
      agentRoleId: null,
      text: 'Plain',
      queue: true,
    });
    assert.notEqual(later.state, 'not_sent', later.reason);
    const config = laterConfig(f, calls);
    assert.ok(config, 'the later turn reached the session');
    assert.equal(config.prompt, 'Plain');
    assert.equal(config.agentRoleId, null);
    assert.equal(config.agentRoleRevision, undefined);
    assert.equal(config.agentRoleSnapshot, undefined);
  } finally {
    f.close();
  }
});

test('a Role another user keeps private is never applied', async () => {
  const f = await openTestSession({
    settings: settingsWith(role({ ownerUserId: 'someone-else' })),
  });
  try {
    assert.deepEqual(outcome(await f.runtime.sendTurn(turn)), {
      state: 'not_sent',
      reason: 'role_unavailable',
    });
  } finally {
    f.close();
  }
});

test('replying in a legacy Antigravity auto_review session preserves inherited Role and memory', async () => {
  const calls = [];
  const f = await openTestSession({
    onRpc(request) {
      calls.push(request);
      return { result: { accepted: true } };
    },
  });
  const roleSnapshot = {
    id: 'agy-reviewer',
    revision: 2,
    name: 'Agy Reviewer',
    emoji: '🪼',
  };
  const memory = { providerId: 'p', memoryId: 'mem-agy' };
  try {
    f.server.getList('history').push({
      id: 'legacy-u1',
      role: 'user',
      status: 'handled',
      items: [{ type: 'text', text: 'First legacy agy turn' }],
      inputConfig: {
        cliType: 'registry',
        agentType: 'antigravity-acp',
        modelId: 'gemini-3.8-flash',
        modeId: 'auto_review',
        configOptionValues: { mode: 'auto_review', thought_level: 'high' },
        mcpServerIds: [],
        agentRoleId: 'agy-reviewer',
        agentRoleRevision: 2,
        agentRoleSnapshot: roleSnapshot,
        memory,
      },
    });
    f.server.getList('history').push({
      id: 'legacy-a1',
      role: 'assistant',
      finished: true,
      items: [{ type: 'text', text: 'Done.' }],
    });
    f.server.commit();
    await f.pushUpdate();

    // Inherited reply (no explicit modeId/configOptionValues): auto_review -> auto must NOT clear Role or memory.
    const inherited = await f.runtime.sendTurn({
      sessionId: 's1',
      machineId: 'm1',
      userId: 'u1',
      cliType: 'registry',
      agentType: 'antigravity-acp',
      text: 'Continue review',
    });
    assert.equal(inherited.state, 'accepted');
    const firstReplyConfig = calls[0].params.inputConfig;
    assert.equal(firstReplyConfig.modeId, 'auto');
    assert.deepEqual(firstReplyConfig.configOptionValues, {
      mode: 'auto',
      thought_level: 'high',
    });
    assert.equal(firstReplyConfig.agentRoleId, 'agy-reviewer');
    assert.equal(firstReplyConfig.agentRoleRevision, 2);
    assert.deepEqual(firstReplyConfig.agentRoleSnapshot, roleSnapshot);
    assert.deepEqual(firstReplyConfig.memory, memory);

    // Explicitly switching away from auto to yolo still clears Role and memory.
    const switched = await f.runtime.sendTurn({
      sessionId: 's1',
      machineId: 'm1',
      userId: 'u1',
      cliType: 'registry',
      agentType: 'antigravity-acp',
      modeId: 'yolo',
      configOptionValues: { mode: 'yolo' },
      text: 'Switch mode',
      queue: true,
    });
    assert.notEqual(switched.state, 'not_sent', switched.reason);
    const switchedConfig = laterConfig(f, calls);
    assert.equal(switchedConfig.modeId, 'yolo');
    assert.equal(switchedConfig.agentRoleId, null);
    assert.equal(switchedConfig.agentRoleRevision, undefined);
    assert.equal(switchedConfig.agentRoleSnapshot, undefined);
    assert.equal(switchedConfig.memory, undefined);
  } finally {
    f.close();
  }
});
