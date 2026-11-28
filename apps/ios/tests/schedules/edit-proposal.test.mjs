import test from 'node:test';
import assert from 'node:assert/strict';
import { Flock } from '@loro-dev/flock-wasm/base64';
import { grant, loadSchedules } from './harness.mjs';

const runtime = await loadSchedules({ proposals: true });
const {
  scheduleStreams,
  scheduleRepository,
  draftInput,
  registerProposals,
  scheduleEditProposal,
  proposalOf,
  diffPromptLines,
} = runtime;

const WS = 'w1';
const OWNER = 'user-1';
const SESSION = 's1';
const NOTICE = { entryId: 'system', itemId: 'notice' };
// Web `scheduleEditProposalActivityId('s1', 'p1')`, computed independently.
const ACTIVITY = '13f281c3-2d1a-8a7d-9246-1cfb6fecb8af';

function workspace(userId = OWNER) {
  globalThis.__scheduleStreams = new Map();
  globalThis.__notices = new Map();
  const meta = new Flock('meta');
  meta.set(['m', 'machine-m1'], {
    name: 'Studio Mac',
    ownerUserId: OWNER,
    timeZone: 'UTC',
  });
  meta.set(['m', 'machine-m1', 'protocolCapabilities'], { schedules: 2 });
  const machine = new Flock('m1');
  machine.set(['agentConfig', 'codex'], {
    id: 'codex',
    name: 'Codex',
    machineId: 'm1',
    cliType: 'builtin',
    agentType: 'codex',
  });
  const handlers = {};
  registerProposals({
    channel: { handle: (name, fn) => (handlers[name] = fn) },
    state: {
      workspace: WS,
      userId,
      metaReplica: { flock: meta },
      unhealthy: new Set(),
      machineReplicas: new Map([['m1', machine]]),
      catalogs: new Map(),
    },
    getGrant: grant,
  });
  const streams = scheduleStreams(WS, grant, new AbortController().signal);
  const repository = scheduleRepository(streams);
  const call = (name, extra = {}) =>
    handlers[name]({
      workspaceId: WS,
      sessionId: SESSION,
      ...NOTICE,
      ...extra,
    });
  return { streams, repository, call };
}

const draft = {
  title: 'Nightly review',
  prompt: 'Review open PRs\nList failures\nPost a summary',
  machineId: 'm1',
  agentConfigId: 'codex',
  destination: 'new_session',
  rule: { kind: 'daily', hour: 9, minute: 30, timeZone: 'UTC' },
};

async function seed(repository) {
  await repository.save({
    scheduleId: 'sched',
    draft: draftInput(draft, undefined, 'UTC', 1000),
    actorId: OWNER,
    now: 1000,
    activationId: 'act-1',
    activityId: 'created-1',
    create: true,
  });
}

function propose(patch, extra = {}) {
  const notice = {
    name: 'schedule_edit_proposal',
    meta: {
      proposalId: 'p1',
      scheduleId: 'sched',
      title: 'Nightly review',
      patch,
      baseActivityId: 'created-1',
      ...extra,
    },
  };
  globalThis.__notices.set(`${NOTICE.entryId}/${NOTICE.itemId}`, notice);
  return notice;
}

test('an edit proposal is read only when its patch is a well-formed change', () => {
  const meta = {
    proposalId: 'p1',
    scheduleId: 'sched',
    title: ' Nightly ',
    patch: { rule: { kind: 'once', at: '2026-12-01T09:00:00Z' } },
    baseActivityId: 'created-1',
  };
  assert.deepEqual(proposalOf('schedule_edit_proposal', meta), {
    kind: 'schedule_edit',
    proposalId: 'p1',
    scheduleId: 'sched',
    title: 'Nightly',
    patch: { rule: { kind: 'once', at: Date.parse('2026-12-01T09:00:00Z') } },
    baseActivityId: 'created-1',
  });
  for (const patch of [
    {},
    { destination: { kind: 'own_session' } },
    { title: '  ' },
    { rule: { kind: 'cron', expression: '* * * * *' } },
  ])
    assert.equal(scheduleEditProposal({ ...meta, patch }), undefined);
  assert.equal(
    scheduleEditProposal({ ...meta, outcome: 'created' }),
    undefined,
  );
  // The older notice keeps its own card; this one never reads as a create.
  assert.equal(proposalOf('schedule_proposal', meta), undefined);
});

test('the prompt diff keeps two lines of context and folds the rest', () => {
  const before = ['a', 'b', 'c', 'd', 'e', 'f', 'g'].join('\n');
  const after = ['a', 'b', 'c', 'd', 'e', 'f', 'G'].join('\n');
  assert.deepEqual(diffPromptLines(before, after), [
    { kind: 'gap', text: '' },
    { kind: 'same', text: 'e' },
    { kind: 'same', text: 'f' },
    { kind: 'del', text: 'g' },
    { kind: 'add', text: 'G' },
  ]);
  assert.equal(diffPromptLines(before, before), null);
});

test('Apply saves the proposed fields over the live schedule under the card activity id', async () => {
  const { streams, repository, call } = workspace();
  await seed(repository);
  // Pause does not move the content revision.
  await repository.setEnabled({
    scheduleId: 'sched',
    enabled: false,
    actorId: OWNER,
    now: 1500,
    activationId: 'act-2',
    requestId: 'pause-1',
  });
  const notice = propose({
    title: 'Morning review',
    prompt: 'Review open PRs\nList failures\nPost a short summary',
    rule: { kind: 'weekdays', hour: 8, minute: 0 },
  });
  const inspected = await call('inspectProposal');
  assert.equal(inspected.state, 'ready');
  assert.equal(inspected.isOwner, true);
  assert.equal(inspected.currentTitle, 'Nightly review');
  assert.deepEqual(inspected.currentRule, {
    kind: 'daily',
    hour: 9,
    minute: 30,
    timeZone: 'UTC',
  });
  assert.equal(inspected.timeZone, 'UTC');
  assert.deepEqual(inspected.promptDiff, [
    { kind: 'same', text: 'Review open PRs' },
    { kind: 'same', text: 'List failures' },
    { kind: 'del', text: 'Post a summary' },
    { kind: 'add', text: 'Post a short summary' },
  ]);

  assert.deepEqual(await call('decideProposal', { decision: 'accept' }), {
    outcome: 'applied',
    scheduleId: 'sched',
  });
  const { document } = await streams.read('sched');
  assert.equal(document.definition.title, 'Morning review');
  assert.equal(document.prompt, notice.meta.patch.prompt);
  assert.equal(document.definition.enabled, false);
  assert.equal(document.definition.agent.agentConfigId, 'codex');
  assert.deepEqual(document.definition.destination, { kind: 'new_session' });
  assert.equal(document.definition.trigger.kind, 'cron');
  assert.equal(document.definition.trigger.expression, '0 8 * * 1-5');
  assert.equal(document.timeline.at(-1).id, ACTIVITY);
  assert.equal(notice.meta.outcome, 'applied');

  // A recorded decision is reported, never applied twice.
  const parts = () =>
    [...globalThis.__scheduleStreams.values()].reduce(
      (count, stream) => count + stream.length,
      0,
    );
  const before = parts();
  assert.deepEqual(await call('decideProposal', { decision: 'dismiss' }), {
    outcome: 'applied',
    scheduleId: 'sched',
  });
  assert.equal(parts(), before);
});

test('a schedule edited after the proposal refuses Apply and asks for a new one', async () => {
  const { repository, call } = workspace();
  await seed(repository);
  const notice = propose({ title: 'Morning review' });
  const previous = (
    await scheduleStreams(WS, grant, new AbortController().signal).read('sched')
  ).document;
  await repository.save({
    scheduleId: 'sched',
    draft: draftInput(
      { ...draft, title: 'Edited by hand' },
      previous,
      'UTC',
      2000,
    ),
    actorId: OWNER,
    now: 2000,
    activationId: 'act-3',
    activityId: 'edited-1',
    create: false,
  });
  assert.equal((await call('inspectProposal')).state, 'stale');
  await assert.rejects(call('decideProposal', { decision: 'accept' }), {
    message: 'schedule_edit_stale',
  });
  assert.equal(notice.meta.outcome, undefined);
  assert.deepEqual(await call('decideProposal', { decision: 'dismiss' }), {
    outcome: 'dismissed',
  });
});

test('a landed save whose outcome was not recorded completes on retry without reapplying', async () => {
  const { streams, repository, call } = workspace();
  await seed(repository);
  const notice = propose({ title: 'Morning review' });
  // The outcome write fails after the schedule save landed.
  globalThis.__failNoticeWrite = true;
  await assert.rejects(call('decideProposal', { decision: 'accept' }), {
    message: 'upload_failed',
  });
  assert.equal(notice.meta.outcome, undefined);
  const saved = (await streams.read('sched')).document;
  assert.equal(saved.definition.title, 'Morning review');
  // The landed save reads as ready even though its revision moved past the base.
  assert.equal((await call('inspectProposal')).state, 'ready');
  assert.deepEqual(await call('decideProposal', { decision: 'accept' }), {
    outcome: 'applied',
    scheduleId: 'sched',
  });
  const { document } = await streams.read('sched');
  assert.equal(
    document.timeline.filter((entry) => entry.id === ACTIVITY).length,
    1,
  );
  assert.equal(notice.meta.outcome, 'applied');
});

test('only the owner may apply or ignore; a deleted schedule is unavailable', async () => {
  const other = workspace('user-2');
  await seed(other.repository);
  propose({ title: 'Morning review' });
  const inspected = await other.call('inspectProposal');
  assert.equal(inspected.state, 'not_owner');
  assert.equal(inspected.isOwner, false);
  await assert.rejects(other.call('decideProposal', { decision: 'accept' }), {
    message: 'schedule_not_owner',
  });
  await assert.rejects(other.call('decideProposal', { decision: 'dismiss' }), {
    message: 'schedule_not_owner',
  });

  const owner = workspace();
  await seed(owner.repository);
  const notice = propose({ title: 'Morning review' });
  await owner.repository.remove('sched', OWNER, 3000);
  assert.deepEqual(await owner.call('inspectProposal'), {
    state: 'unavailable',
    isOwner: false,
    timeZone: (await owner.call('inspectProposal')).timeZone,
  });
  await assert.rejects(owner.call('decideProposal', { decision: 'accept' }), {
    message: 'proposal_unavailable',
  });
  assert.deepEqual(
    await owner.call('decideProposal', { decision: 'dismiss' }),
    {
      outcome: 'dismissed',
    },
  );
  assert.equal(notice.meta.outcome, 'dismissed');
});
