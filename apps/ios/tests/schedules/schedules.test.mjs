import test from 'node:test';
import assert from 'node:assert/strict';
import { LoroDoc, LoroMap } from 'loro-crdt/base64';
import { Flock } from '@loro-dev/flock-wasm/base64';
import { grant, loadSchedules } from './harness.mjs';

const runtime = await loadSchedules();
const {
  scheduleStreams,
  scheduleRepository,
  scheduleDefinitionFingerprint,
  scheduleOwnSessionId,
  activeSessionStatuses,
  inspectBoundSessionLiveStatus,
  hasPendingUserTurnActivation,
  hasFreshPendingUserTurnActivation,
  registerSchedules,
  draftInput,
  ruleOf,
  scheduleMachine,
  triggerOf,
  proposalRule,
} = runtime;

const WS = 'w1';
const OWNER = 'user-1';

function fresh() {
  globalThis.__scheduleStreams = new Map();
  const streams = scheduleStreams(WS, grant, new AbortController().signal);
  return { streams, repository: scheduleRepository(streams) };
}

const draft = (overrides = {}) => ({
  title: 'Nightly review',
  prompt: 'Review open PRs',
  machineId: 'm1',
  agentConfigId: 'codex',
  modelId: 'gpt',
  destination: 'new_session',
  project: { kind: 'local', localProjectId: 'p1', useWorktree: true },
  rule: { kind: 'daily', hour: 9, minute: 30, timeZone: 'Asia/Shanghai' },
  ...overrides,
});

async function create(repository, id = 's1', input = draft(), now = 1000) {
  return repository.save({
    scheduleId: id,
    draft: draftInput(input, undefined, 'UTC', now),
    actorId: OWNER,
    now,
    activationId: 'act-1',
    activityId: `${id}-created`,
    create: true,
  });
}

test('a created schedule publishes its document first and a registry row that matches it', async () => {
  const { streams, repository } = fresh();
  await create(repository);
  const { rows } = await streams.list();
  assert.equal(rows.length, 1);
  const [row] = rows;
  const { document } = await streams.read('s1');
  assert.equal(document.prompt, 'Review open PRs');
  assert.deepEqual(document.definition.trigger, {
    kind: 'cron',
    expression: '30 9 * * *',
    timeZone: 'Asia/Shanghai',
  });
  assert.deepEqual(document.definition.misfirePolicy, { kind: 'run_once' });
  assert.equal(document.definition.overlapPolicy, 'queue_one');
  assert.deepEqual(document.definition.project, {
    kind: 'local',
    localProjectId: 'p1',
    useWorktree: true,
  });
  assert.equal(
    row.definitionFingerprint,
    await scheduleDefinitionFingerprint(document),
  );
  assert.equal(row.projectKey, 'p1');
  assert.equal(row.enabled, true);
  // The document stream is written before the registry row.
  const order = [...globalThis.__scheduleStreams.keys()];
  assert.ok(order.indexOf(`${WS}:schedule:s1`) < order.indexOf(`${WS}:sr`));
});

test('saving an untouched rule keeps the stored trigger verbatim', async () => {
  const { streams, repository } = fresh();
  await repository.save({
    scheduleId: 's1',
    draft: {
      ...draftInput(draft(), undefined, 'UTC', 1000),
      trigger: { kind: 'cron', expression: '0 9 * * MON-FRI', timeZone: 'UTC' },
    },
    actorId: OWNER,
    now: 1000,
    activationId: 'act-1',
    activityId: 'created',
    create: true,
  });
  const before = (await streams.read('s1')).document;
  const rule = ruleOf(before.definition.trigger);
  assert.equal(rule.kind, 'weekdays');
  const input = draftInput(
    draft({ title: 'Renamed', rule }),
    before,
    'UTC',
    2000,
  );
  assert.deepEqual(input.trigger, before.definition.trigger);
  // A changed time is re-authored as cron in the machine's rule zone.
  const moved = draftInput(
    draft({ rule: { ...rule, hour: 10 } }),
    before,
    'UTC',
    2000,
  );
  assert.equal(moved.trigger.expression, '0 10 * * 1-5');
});

test('a schedule computer reads its name, owner, clock and support from workspace metadata', () => {
  const meta = new Flock('meta');
  meta.set(['m', 'machine-studio-mac'], {
    name: 'Studio Mac',
    ownerUserId: OWNER,
    timeZone: 'Asia/Shanghai',
  });
  meta.set(['m', 'machine-studio-mac', 'protocolCapabilities'], {
    schedules: 2,
  });
  assert.deepEqual(scheduleMachine(meta, 'studio-mac'), {
    name: 'Studio Mac',
    owner: OWNER,
    timeZone: 'Asia/Shanghai',
    supported: true,
  });
  assert.deepEqual(scheduleMachine(meta, 'unknown'), {
    name: undefined,
    owner: '',
    timeZone: undefined,
    supported: false,
  });
});

test('an unsupported stored rule can only be kept, never rewritten', () => {
  const stored = { kind: 'cron', expression: '*/7 3 * * *', timeZone: 'UTC' };
  const rule = ruleOf(stored);
  assert.equal(rule.kind, 'unsupported');
  assert.deepEqual(triggerOf(rule, 'UTC', 0, stored), stored);
  assert.throws(
    () => triggerOf(rule, 'UTC', 0, undefined),
    /schedule_trigger_invalid/,
  );
  assert.deepEqual(triggerOf({ kind: 'manual' }, 'UTC', 0, stored), {
    kind: 'manual',
  });
  assert.throws(
    () =>
      triggerOf({ kind: 'weekly', weekdays: [], hour: 9, minute: 0 }, 'UTC', 0),
    /schedule_trigger_invalid/,
  );
});

test('a custom step proposed by an Agent is read, created and reopened like on Web', () => {
  const STEP_MAX = 2_147_483_647;
  // Steps past a day used to drop the whole proposal card on mobile.
  assert.deepEqual(proposalRule({ kind: 'minutes', every: 200_000 }), {
    kind: 'minutes',
    every: 200_000,
  });
  assert.deepEqual(proposalRule({ kind: 'hours', every: STEP_MAX }), {
    kind: 'hours',
    every: STEP_MAX,
  });
  // Android carries `every` as a 32-bit Int.
  assert.equal(proposalRule({ kind: 'hours', every: STEP_MAX + 1 }), undefined);
  assert.equal(proposalRule({ kind: 'minutes', every: 1.5 }), undefined);

  const now = Date.parse('2026-11-17T08:07:00Z');
  const trigger = triggerOf(
    { kind: 'minutes', every: 200_000, timeZone: 'UTC' },
    'UTC',
    now,
  );
  assert.deepEqual(trigger, {
    kind: 'interval',
    everyMs: 200_000 * 60_000,
    anchorAt: new Date(now).toISOString(),
  });
  assert.equal(ruleOf(trigger).kind, 'minutes');
  assert.equal(ruleOf(trigger).every, 200_000);
  assert.throws(
    () => triggerOf({ kind: 'hours', every: STEP_MAX + 1 }, 'UTC', now),
    /schedule_trigger_invalid/,
  );
  // A longer stored interval stays read-only instead of overflowing `every`.
  const longer = {
    kind: 'interval',
    everyMs: (STEP_MAX + 1) * 3_600_000,
    anchorAt: new Date(now).toISOString(),
  };
  assert.equal(ruleOf(longer).kind, 'unsupported');
});

test('an edit keeps what mobile cannot edit and changes what it can', async () => {
  const { streams, repository } = fresh();
  const created = await create(repository);
  // Agent options and memory come from web; mobile never drops them for the same Agent.
  created.definition.agent = {
    ...created.definition.agent,
    configOptionValues: { reasoning: 'high', fast: true },
    memory: { providerId: 'mem', memoryId: 'notes' },
  };
  created.definition.destination = { kind: 'own_session', epoch: 3 };
  created.definition.project = undefined;
  await streams.write(created, false);
  const previous = (await streams.read('s1')).document;
  const same = draftInput(
    draft({ destination: 'own_session' }),
    previous,
    'UTC',
    5000,
  );
  assert.deepEqual(same.agent.configOptionValues, {
    reasoning: 'high',
    fast: true,
  });
  assert.deepEqual(same.destination, { kind: 'own_session', epoch: 3 });
  assert.equal(same.project, undefined, 'an owned chat carries no project');
  const other = draftInput(
    draft({ agentConfigId: 'claude' }),
    previous,
    'UTC',
    5000,
  );
  assert.equal(other.agent.configOptionValues, undefined);
  assert.equal(other.agent.memory, undefined);

  await repository.save({
    scheduleId: 's1',
    draft: same,
    actorId: OWNER,
    now: 5000,
    activationId: 'act-2',
    activityId: 'edit-1',
    create: false,
  });
  const edited = (await streams.read('s1')).document;
  assert.equal(edited.definition.createdAt, 1000);
  assert.equal(edited.definition.updatedAt, 5000);
  assert.deepEqual(
    edited.timeline.map((entry) => entry.kind),
    ['created', 'edited'],
  );
  const [row] = (await streams.list()).rows;
  assert.equal(
    row.definitionFingerprint,
    await scheduleDefinitionFingerprint(edited),
  );
});

test('a retried request replays only the same intent', async () => {
  const { streams, repository } = fresh();
  await create(repository);
  const previous = (await streams.read('s1')).document;
  const args = {
    scheduleId: 's1',
    draft: draftInput(draft({ title: 'Second' }), previous, 'UTC', 2000),
    actorId: OWNER,
    now: 2000,
    activationId: 'act-2',
    activityId: 'edit-1',
    create: false,
  };
  await repository.save(args);
  await repository.save({ ...args, now: 3000, activationId: 'act-3' });
  assert.equal((await streams.read('s1')).document.timeline.length, 2);
  await assert.rejects(
    repository.save({
      ...args,
      draft: draftInput(draft({ title: 'Third' }), previous, 'UTC', 2000),
    }),
    /schedule_conflict/,
  );
  await assert.rejects(create(repository), /schedule_conflict/);
});

test('pause, resume, run and delete are owner-only and delete always wins', async () => {
  const { streams, repository } = fresh();
  await create(repository);
  await assert.rejects(
    repository.setEnabled({
      scheduleId: 's1',
      enabled: false,
      actorId: 'someone-else',
      now: 2000,
      activationId: 'a',
      requestId: 'r1',
    }),
    /schedule_not_owner/,
  );
  await repository.setEnabled({
    scheduleId: 's1',
    enabled: false,
    actorId: OWNER,
    now: 2000,
    activationId: 'a',
    requestId: 'pause-1',
  });
  let [row] = (await streams.list()).rows;
  assert.equal(row.enabled, false);
  await repository.setEnabled({
    scheduleId: 's1',
    enabled: true,
    actorId: OWNER,
    now: 3000,
    activationId: 'act-resume',
    requestId: 'resume-1',
  });
  [row] = (await streams.list()).rows;
  assert.equal(row.enabled, true);
  assert.equal(row.activationId, 'act-resume');
  assert.equal(row.activeFrom, 3000);

  await repository.requestRun({
    scheduleId: 's1',
    actorId: OWNER,
    manualRunId: 'run-1',
    now: 4000,
  });
  await repository.requestRun({
    scheduleId: 's1',
    actorId: OWNER,
    manualRunId: 'run-1',
    now: 4500,
  });
  const { flock } = await streams.registry(false);
  assert.deepEqual(flock.get(['manual', 's1', 'run-1']), {
    scheduleId: 's1',
    actorId: OWNER,
    manualRunId: 'run-1',
    activationId: 'act-resume',
    requestedAt: 4000,
  });

  await assert.rejects(
    repository.remove('s1', 'someone-else', 5000),
    /schedule_not_owner/,
  );
  await repository.remove('s1', OWNER, 5000);
  assert.deepEqual((await streams.list()).rows, []);
  await assert.rejects(
    repository.setEnabled({
      scheduleId: 's1',
      enabled: false,
      actorId: OWNER,
      now: 6000,
      activationId: 'a',
      requestId: 'pause-2',
    }),
    /schedule_not_found/,
  );
});

test('a scheduled message is shown but never rewritten from mobile', async () => {
  const { streams, repository } = fresh();
  await create(repository, 'msg');
  // Turn the stored document into a web-authored scheduled message.
  const key = `${WS}:schedule:msg`;
  const doc = new LoroDoc();
  for (const part of globalThis.__scheduleStreams.get(key)) {
    const view = new DataView(part.buffer, part.byteOffset, part.byteLength);
    let offset = 0;
    while (offset < part.byteLength) {
      const size = view.getUint32(offset, false);
      doc.import(part.subarray(offset + 4, offset + 4 + size));
      offset += 4 + size;
    }
  }
  const before = doc.version();
  doc
    .getMap('message')
    .setContainer('payload', new LoroMap())
    .set('inputBlocks', []);
  doc.commit();
  const update = doc.export({ mode: 'update', from: before });
  const framed = new Uint8Array(update.length + 4);
  new DataView(framed.buffer).setUint32(0, update.length, false);
  framed.set(update, 4);
  globalThis.__scheduleStreams.get(key).push(framed);

  const read = await streams.read('msg');
  assert.equal(read.message, true);
  assert.equal(read.text, 'Review open PRs');
  await assert.rejects(
    repository.setEnabled({
      scheduleId: 'msg',
      enabled: false,
      actorId: OWNER,
      now: 2000,
      activationId: 'a',
      requestId: 'r',
    }),
    /schedule_message_read_only/,
  );
  await repository.remove('msg', OWNER, 3000);
  assert.deepEqual((await streams.list()).rows, []);
});

test('scheduleOwnSessionId derives a deterministic RFC 9562 UUIDv8 per schedule and epoch', async () => {
  const first = await scheduleOwnSessionId('sched-1', 0);
  const again = await scheduleOwnSessionId('sched-1', 0);
  const nextEpoch = await scheduleOwnSessionId('sched-1', 1);
  assert.equal(first, again);
  assert.notEqual(first, nextEpoch);
  assert.match(
    first,
    /^[0-9a-f]{8}-[0-9a-f]{4}-8[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/,
  );
});

test('activeSessionStatuses projects fresh session presence and ignores stale or non-session rows', () => {
  const now = 1_000_000;
  const result = activeSessionStatuses(
    {
      m1: {
        kind: 'machine',
        machineId: 'm1',
        instanceId: 'i1',
        updatedAt: now,
      },
      s1: {
        kind: 'session',
        sessionId: 'sess-run',
        status: { type: 'running' },
        updatedAt: now - 1_000,
      },
      s2: {
        kind: 'session',
        sessionId: 'sess-wait',
        status: { type: 'requestPermission' },
        updatedAt: now - 2_000,
      },
      s3Old: {
        kind: 'session',
        sessionId: 'sess-init',
        status: { type: 'running' },
        updatedAt: now - 10_000,
      },
      s3New: {
        kind: 'session',
        sessionId: 'sess-init',
        status: { type: 'initializing' },
        updatedAt: now - 500,
      },
      sStale: {
        kind: 'session',
        sessionId: 'sess-stale',
        status: { type: 'running' },
        updatedAt: now - 95_000,
      },
    },
    now,
  );
  assert.equal(result.get('sess-run'), 'running');
  assert.equal(result.get('sess-wait'), 'waiting');
  assert.equal(result.get('sess-init'), 'initializing');
  assert.equal(result.has('sess-stale'), false);
});

test('inspectBoundSessionLiveStatus handles busy, idle, race, offline and RPC failure deterministically', async () => {
  const now = 500_000;
  let rpcCalls = 0;

  // 1. Live presence busy short-circuits without calling RPC.
  const presenceBusy = await inspectBoundSessionLiveStatus({
    sessionId: 's1',
    machineId: 'm1',
    getSnapshot: () => ({
      presenceDetail: 'running',
      machineState: 'online',
      sessionMeta: undefined,
      nowMs: now,
    }),
    requestDaemonLiveStatus: async () => {
      rpcCalls += 1;
      return { success: true, sessionId: 's1', state: 'idle' };
    },
  });
  assert.deepEqual(presenceBusy, {
    sessionId: 's1',
    state: 'busy',
    detail: 'running',
    source: 'presence',
  });
  assert.equal(rpcCalls, 0);

  // 2. Fresh pending dispatch pointer counts as busy; stale (>30s) or settled does not.
  assert.equal(
    hasPendingUserTurnActivation({
      latestUserMsgId: 't2',
      lastHandledUserMsgId: 't1',
    }),
    true,
  );
  assert.equal(
    hasFreshPendingUserTurnActivation(
      {
        latestUserMsgId: 't2',
        lastHandledUserMsgId: 't1',
        lastMessageAt: now - 5_000,
      },
      now,
    ),
    true,
  );
  assert.equal(
    hasFreshPendingUserTurnActivation(
      {
        latestUserMsgId: 't2',
        lastHandledUserMsgId: 't1',
        lastMessageAt: now - 45_000,
      },
      now,
    ),
    false,
  );
  assert.equal(
    hasFreshPendingUserTurnActivation(
      {
        latestUserMsgId: 't2',
        lastHandledUserMsgId: 't1',
        settledActivationUserMsgId: 't2',
        lastMessageAt: now - 1_000,
      },
      now,
    ),
    false,
  );

  // 3. Authoritative RPC idle and busy states.
  const rpcIdle = await inspectBoundSessionLiveStatus({
    sessionId: 's1',
    machineId: 'm1',
    getSnapshot: () => ({
      presenceDetail: undefined,
      machineState: 'online',
      sessionMeta: undefined,
      nowMs: now,
    }),
    requestDaemonLiveStatus: async () => ({
      success: true,
      sessionId: 's1',
      state: 'idle',
    }),
  });
  assert.deepEqual(rpcIdle, { sessionId: 's1', state: 'idle', source: 'rpc' });

  const rpcBusy = await inspectBoundSessionLiveStatus({
    sessionId: 's1',
    machineId: 'm1',
    getSnapshot: () => ({
      presenceDetail: undefined,
      machineState: 'online',
      sessionMeta: undefined,
      nowMs: now,
    }),
    requestDaemonLiveStatus: async () => ({
      success: true,
      sessionId: 's1',
      state: 'waiting',
    }),
  });
  assert.deepEqual(rpcBusy, {
    sessionId: 's1',
    state: 'busy',
    detail: 'waiting',
    source: 'rpc',
  });

  // 4. Check-to-dispatch race: session becomes busy in presence while RPC returns idle.
  let reads = 0;
  const raceResult = await inspectBoundSessionLiveStatus({
    sessionId: 's1',
    machineId: 'm1',
    getSnapshot: () => {
      reads += 1;
      return {
        presenceDetail: reads > 1 ? 'running' : undefined,
        machineState: 'online',
        sessionMeta: undefined,
        nowMs: now,
      };
    },
    requestDaemonLiveStatus: async () => ({
      success: true,
      sessionId: 's1',
      state: 'idle',
    }),
  });
  assert.deepEqual(raceResult, {
    sessionId: 's1',
    state: 'busy',
    detail: 'running',
    source: 'presence',
  });

  // 5. Offline machine returns unknown without RPC.
  const offline = await inspectBoundSessionLiveStatus({
    sessionId: 's1',
    machineId: 'm1',
    getSnapshot: () => ({
      presenceDetail: undefined,
      machineState: 'offline',
      sessionMeta: undefined,
      nowMs: now,
    }),
    requestDaemonLiveStatus: async () => {
      throw new Error('should not be called');
    },
  });
  assert.deepEqual(offline, {
    sessionId: 's1',
    state: 'unknown',
    source: 'none',
    reason: 'machine_offline',
  });

  // 6. RPC failure or error response returns unknown.
  const failed = await inspectBoundSessionLiveStatus({
    sessionId: 's1',
    machineId: 'm1',
    getSnapshot: () => ({
      presenceDetail: undefined,
      machineState: 'online',
      sessionMeta: undefined,
      nowMs: now,
    }),
    requestDaemonLiveStatus: async () => {
      throw new Error('timeout');
    },
  });
  assert.deepEqual(failed, {
    sessionId: 's1',
    state: 'unknown',
    source: 'none',
    reason: 'rpc_failed',
  });
});

test('registerSchedules projects bound session ids and fences sessionLiveStatus by workspace', async () => {
  const { repository } = fresh();
  await create(repository, 'new-sched', draft({ destination: 'new_session' }));
  await create(
    repository,
    'own-uncreated',
    draft({ destination: 'own_session' }),
  );
  await create(
    repository,
    'own-created',
    draft({ destination: 'own_session' }),
  );
  await repository.save({
    scheduleId: 'existing-sched',
    draft: {
      ...draftInput(draft(), undefined, 'UTC', 1000),
      destination: { kind: 'existing_session', sessionId: 'sess-existing' },
      project: undefined,
    },
    actorId: OWNER,
    now: 1000,
    activationId: 'act-1',
    activityId: 'existing-created',
    create: true,
  });

  const ownCreatedSessionId = await scheduleOwnSessionId('own-created', 0);
  const meta = new Flock('meta');
  meta.set(['e', 'machine-m1'], true);
  meta.set(['m', 'machine-m1'], {
    name: 'Studio',
    ownerUserId: OWNER,
    protocolCapabilities: { schedules: 2 },
  });
  meta.set(['e', `session-${ownCreatedSessionId}`], true);
  meta.set(['m', `session-${ownCreatedSessionId}`], {
    id: ownCreatedSessionId,
    machineId: 'm1',
  });
  meta.set(['e', 'session-sess-existing'], true);
  meta.set(['m', 'session-sess-existing'], {
    id: 'sess-existing',
    machineId: 'm1',
  });

  const handlers = new Map();
  const state = {
    workspace: WS,
    userId: OWNER,
    workspaceReadOnly: false,
    metaReplica: { flock: meta, client: {} },
    presence: { state: 'live', onlineMachineIds: ['m1'] },
    getLiveSessionPresence: () => undefined,
    knownProjects: [],
    machineReplicas: new Map(),
    catalogs: new Map([
      ['meta', { projects: [], sessions: [], machineIds: ['m1'] }],
    ]),
    unhealthy: new Set(),
    workspaceReplica: undefined,
    pinSections: { sections: [], loaded: false },
  };
  registerSchedules({
    channel: {
      handle(method, fn) {
        handlers.set(method, fn);
      },
    },
    state,
    getGrant: grant,
  });

  const listResult = await handlers.get('schedules')({ workspaceId: WS });
  const byId = new Map(
    listResult.items.map((entry) => [entry.scheduleId, entry]),
  );
  assert.equal(byId.get('new-sched').destinationSessionId, undefined);
  assert.equal(byId.get('own-uncreated').destinationSessionId, undefined);
  assert.equal(
    byId.get('own-created').destinationSessionId,
    ownCreatedSessionId,
  );
  assert.equal(
    byId.get('existing-sched').destinationSessionId,
    'sess-existing',
  );

  // Querying live status calls daemon session/live-status RPC and returns authoritative state.
  let seenRpc = null;
  globalThis.__machineRpc = async (workspaceId, machineId, method, params) => {
    seenRpc = { workspaceId, machineId, method, params };
    return {
      result: { success: true, sessionId: params.sessionId, state: 'running' },
    };
  };
  const live = await handlers.get('sessionLiveStatus')({
    workspaceId: WS,
    sessionId: 'sess-existing',
    machineId: 'm1',
  });
  assert.deepEqual(seenRpc, {
    workspaceId: WS,
    machineId: 'm1',
    method: 'session/live-status',
    params: { sessionId: 'sess-existing' },
  });
  assert.deepEqual(live, {
    sessionId: 'sess-existing',
    state: 'busy',
    detail: 'running',
    source: 'rpc',
  });

  // Workspace mismatch fails closed before any RPC.
  await assert.rejects(
    handlers.get('sessionLiveStatus')({
      workspaceId: 'other-ws',
      sessionId: 'sess-existing',
      machineId: 'm1',
    }),
    /metadata_not_ready/,
  );

  // Workspace change while RPC is in flight fails closed.
  globalThis.__machineRpc = async () => {
    state.workspace = 'w2';
    return {
      result: { success: true, sessionId: 'sess-existing', state: 'idle' },
    };
  };
  await assert.rejects(
    handlers.get('sessionLiveStatus')({
      workspaceId: WS,
      sessionId: 'sess-existing',
      machineId: 'm1',
    }),
    /workspace_changed/,
  );
  delete globalThis.__machineRpc;
});
