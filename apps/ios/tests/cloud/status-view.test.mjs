import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import test from 'node:test';
import { Flock } from '@loro-dev/flock-wasm/base64';
import { projectRows } from '../../../../packages/cloud-runtime/src/protocol/catalog.ts';
import {
  applyStatusViewWrites,
  catalogStatusView,
  pinSectionRows,
  planCommand,
  conversationOf,
  sessionPermissions,
  snoozePresets,
  statusViewState,
} from '../../../../packages/cloud-runtime/src/runtime/status-view.ts';
import {
  buildStatusViewLayout,
  planStatusViewCommand,
} from '../../../../packages/cloud-runtime/src/protocol/lody-shared/status-view/index.ts';
import {
  CatalogStatusView,
  SnoozePresetsResult,
  StatusViewCommand,
  StatusViewLayout,
} from '../../../../packages/cloud-runtime/src/contract/status-view.ts';
import {
  createServerClock,
  fetchLodyServerTime,
} from '../../../../packages/cloud-runtime/src/runtime/server-clock.ts';

const vendorDir = new URL(
  '../../../../packages/cloud-runtime/src/protocol/lody-shared/',
  import.meta.url,
);
const vectors = async (name) =>
  JSON.parse(
    await readFile(new URL(`status-view/vectors/${name}.json`, vendorDir)),
  );
const cycling = (bytes) => {
  let next = 0;
  return () => bytes[next++ % bytes.length];
};

test('the vendored layout reproduces every golden layout vector', async () => {
  const { cases } = await vectors('layout');
  assert.ok(cases.length > 0);
  for (const entry of cases) {
    const layout = buildStatusViewLayout(entry.input);
    assert.deepEqual(layout, entry.expected, entry.name);
    // The host contract carries exactly what the shared layout produces.
    assert.deepEqual(StatusViewLayout.parse(layout), layout, entry.name);
  }
});

test('the vendored planner reproduces every golden command vector', async () => {
  const { cases } = await vectors('commands');
  assert.ok(cases.length > 0);
  for (const entry of cases) {
    const writes = planStatusViewCommand(entry.state, entry.command, {
      nowMs: entry.env.nowMs,
      randomByte: cycling(entry.env.randomBytes),
    });
    assert.deepEqual(writes, entry.expected, entry.name);
    // Host commands are the planner's commands minus the runtime-only ones;
    // one the contract refuses at the boundary is one the planner refuses too.
    const runtimeOnly = ['touchOnSend', 'newSessionOrder'];
    const accepted = StatusViewCommand.safeParse(entry.command).success;
    if (runtimeOnly.includes(entry.command.type))
      assert.equal(accepted, false, entry.name);
    else if (!accepted) assert.deepEqual(writes, [], entry.name);
  }
});

test('vendored status-view files match their recorded upstream bytes', async () => {
  const provenance = JSON.parse(
    await readFile(new URL('provenance.json', vendorDir), 'utf8'),
  );
  assert.match(provenance.commit, /^[0-9a-f]{40}$/);
  for (const file of provenance.files) {
    let text = await readFile(new URL(file.path, vendorDir), 'utf8');
    for (const [upstream, local] of file.adapt) {
      assert.ok(text.includes(local), `${file.path}: ${local}`);
      text = text.replaceAll(local, upstream);
    }
    assert.equal(
      createHash('sha256').update(text).digest('hex'),
      file.sha256,
      file.path,
    );
  }
});

test('catalog keeps the Status view fields and machine owners', () => {
  const flock = new Flock('status-fields');
  flock.set(['e', 'machine-m1'], true);
  flock.set(['m', 'machine-m1'], { name: 'Mac', ownerUserId: 'u1' });
  flock.set(['e', 'session-s1'], true);
  flock.set(['m', 'session-s1'], {
    machineId: 'm1',
    title: 'One',
    isPinned: true,
    pinSectionId: ' sec-1 ',
    orderKey: '80',
    snoozedUntil: 1000,
    settledAt: 2000,
    focusRestoredAt: 3000,
  });
  flock.set(['e', 'session-s2'], true);
  flock.set(['m', 'session-s2'], { machineId: 'm1', title: 'Two' });
  // Field rows written later override the document value, as on desktop.
  flock.set(['m', 'session-s2', 'snoozedUntil'], 5000);
  flock.set(['m', 'session-s2', 'orderKey'], 7);
  const catalog = projectRows(flock.scan(), 'meta');
  const [one, two] = ['s1', 's2'].map((id) =>
    catalog.sessions.find((session) => session.id === id),
  );
  assert.equal(one.pinSectionId, 'sec-1');
  assert.equal(one.orderKey, '80');
  assert.equal(one.snoozedUntil, 1000);
  assert.equal(one.settledAt, 2000);
  assert.equal(one.focusRestoredAt, 3000);
  assert.equal(two.snoozedUntil, 5000);
  assert.equal(two.orderKey, undefined);
  assert.equal(two.settledAt, undefined);
  assert.deepEqual(catalog.machineOwners, { m1: 'u1' });
});

test('pin sections keep valid rows only, in key then id order', () => {
  const flock = new Flock('sections');
  flock.set(['pinSection', 'b'], { id: 'b', name: 'Beta', orderKey: '80' });
  flock.set(['pinSection', 'a'], { id: 'a', name: 'Alpha', orderKey: '80' });
  flock.set(['pinSection', 'c'], { id: 'c', name: 'First', orderKey: '7F' });
  flock.set(['pinSection', 'mismatch'], { id: 'x', name: 'X', orderKey: '80' });
  flock.set(['pinSection', 'nokey'], {
    id: 'nokey',
    name: 'N',
    orderKey: 'zz',
  });
  flock.set(['agentRole', 'r1'], { id: 'r1', name: 'Role' });
  assert.deepEqual(
    pinSectionRows(flock.scan()).map((section) => section.id),
    ['c', 'a', 'b'],
  );
});

test('management needs an owned machine, or a readable one outside a local project; preferences admit the author', () => {
  const meta = { machineOwners: { mine: 'u1', theirs: 'u2' } };
  const readable = new Map([
    ['mine', { projects: [] }],
    ['theirs', { projects: [{ id: 'theirs:local:p1' }] }],
  ]);
  const check = (session) => sessionPermissions(session, meta, readable, 'u1');
  assert.deepEqual(
    check({ machineId: 'mine', projectId: 'mine:local:x', userId: 'u2' }),
    { canManage: true, canPrefer: true },
  );
  assert.deepEqual(
    check({ machineId: 'theirs', projectId: 'github:a/b', userId: 'u2' }),
    { canManage: true, canPrefer: true },
  );
  // A teammate's local project, even one their machine stream lists, may be
  // private: whether it is shared is server state the runtime cannot read.
  assert.deepEqual(
    check({ machineId: 'theirs', projectId: 'theirs:local:p1', userId: 'u2' }),
    { canManage: false, canPrefer: false },
  );
  assert.deepEqual(
    check({ machineId: 'theirs', projectId: 'theirs:local:p1', userId: 'u1' }),
    { canManage: false, canPrefer: true },
  );
  // A Project group with a local member is a local-project conversation too.
  const group = {
    machineId: 'theirs',
    projectId: 'group:g1',
    userId: 'u2',
    projectRun: {
      id: 'g1',
      name: 'G',
      members: [
        { id: 'a', path: 'a', kind: 'github', depth: 0, submodule: false },
        { id: 'b', path: 'b', kind: 'local', depth: 0, submodule: false },
      ],
    },
  };
  assert.deepEqual(check(group), { canManage: false, canPrefer: false });
  assert.deepEqual(
    check({
      ...group,
      projectRun: {
        ...group.projectRun,
        members: [group.projectRun.members[0]],
      },
    }),
    { canManage: true, canPrefer: true },
  );
  assert.deepEqual(check({ ...group, machineId: 'mine' }), {
    canManage: true,
    canPrefer: true,
  });
  assert.deepEqual(
    check({ machineId: 'unknown', projectId: 'github:a/b', userId: 'u2' }),
    { canManage: false, canPrefer: false },
  );
  assert.deepEqual(
    sessionPermissions(
      { machineId: 'mine', projectId: 'mine:unassigned', userId: '' },
      meta,
      new Map(),
      '',
    ),
    { canManage: false, canPrefer: false },
  );
});

test('server clock uses the round-trip midpoint and keeps it through bad samples', async () => {
  let wall = 1_000_000;
  let mono = 0;
  let serverTime = () => 2_000_150;
  const clock = createServerClock({
    wallNow: () => wall,
    monotonicNow: () => mono,
    fetchServerTime: async () => {
      wall += 300;
      mono += 300;
      return serverTime();
    },
  });
  assert.equal(clock.synced(), false);
  assert.equal(clock.now(), 1_000_000);
  assert.equal(await clock.sync(), true);
  // Midpoint 1_000_150 maps to server 2_000_150.
  assert.equal(clock.now(), wall + 1_000_000);
  // A wall-clock jump during the request is refused; the offset is kept.
  serverTime = () => {
    wall += 5_000;
    return 9_999_999;
  };
  assert.equal(await clock.sync(), false);
  assert.equal(clock.now(), wall + 1_000_000);
  serverTime = () => {
    throw new Error('offline');
  };
  assert.equal(await clock.sync(), false);
  assert.equal(clock.synced(), true);
});

const NOW = Date.UTC(2026, 10, 21, 12);
const session = (id, fields = {}) => ({
  id,
  machineId: 'm1',
  title: id,
  status: 'idle',
  archived: false,
  pinned: false,
  userId: 'u1',
  projectId: 'm1:unassigned',
  createdAt: new Date(NOW - 60_000).toISOString(),
  lastMessageAt: NOW - 60_000,
  lastReadAt: NOW - 60_000,
  ...fields,
});
const sources = (sessions, extra = {}) => ({
  catalog: { sessions, machineOwners: { m1: 'u1' } },
  machineCatalogs: new Map([['m1', { projects: [] }]]),
  userId: 'u1',
  readOnly: false,
  sections: [],
  sectionsLoaded: true,
  nowMs: NOW,
  ...extra,
});
const ids = (rows) => rows.map((row) => row.id);

test('Tabs fold into their conversation and lend it their activity, running and waiting state', () => {
  const state = statusViewState(
    sources([
      session('owner', { settledAt: NOW - 1000 }),
      session('tab', { parentSessionId: 'owner', status: 'running' }),
      session('side', {
        parentSessionId: 'quiet',
        childSessionPlacement: 'side-panel',
        status: 'running',
      }),
      session('quiet', { lastMessageAt: NOW - 8 * 86_400_000 }),
      session('asks', {
        awaitingUserSince: NOW - 5000,
        snoozedUntil: NOW + 3_600_000,
      }),
      session('elsewhere', {
        parentSessionId: 'other-machine-owner',
        status: 'running',
        machineId: 'm2',
      }),
      session('other-machine-owner', { lastMessageAt: NOW - 8 * 86_400_000 }),
    ]),
    'team',
  );
  assert.deepEqual(ids(state.sessions).sort(), [
    'asks',
    'other-machine-owner',
    'owner',
    'quiet',
  ]);
  const byId = Object.fromEntries(state.sessions.map((s) => [s.id, s]));
  assert.equal(byId.owner.isWorking, true);
  assert.equal(byId.quiet.isWorking, false, 'side chats do not count');
  assert.equal(
    byId['other-machine-owner'].isWorking,
    false,
    'another machine does not count',
  );
  assert.equal(byId.asks.isWaitingPermission, true);
  // As desktop's getEffectiveLatestMessageAt: every non-archived Tab or side
  // chat, on any machine, keeps its conversation's activity fresh; unread stays
  // the conversation's own.
  assert.equal(byId.quiet.activityAt, NOW - 60_000);
  assert.equal(byId.quiet.lastMessageAt, NOW - 8 * 86_400_000);
  assert.equal(byId['other-machine-owner'].activityAt, NOW - 60_000);
  const layout = buildStatusViewLayout(state);
  // Waiting ignores its snooze; an explicit settle holds until a newer message;
  // a conversation quiet for seven days stays in Focus while a Tab is active.
  assert.deepEqual(ids(layout.focus).sort(), [
    'asks',
    'other-machine-owner',
    'quiet',
  ]);
  assert.deepEqual(ids(layout.settled), ['owner']);
});

test('rows nest under their opener, through a Tab; My tasks lists only own conversations and counts hidden pinned rows', () => {
  const view = catalogStatusView(
    sources(
      [
        session('root', { userId: 'u2' }),
        session('tab', { parentSessionId: 'root', userId: 'u2' }),
        session('child', { openedBySessionId: 'tab', userId: 'u1' }),
        session('theirs', { userId: 'u2' }),
        session('theirs-pinned', {
          userId: 'u2',
          pinned: true,
          pinSectionId: 's1',
        }),
        // Carried into the Pinned area by its pinned opener.
        session('carried', {
          userId: 'u2',
          openedBySessionId: 'theirs-pinned',
        }),
        session('gone', { archived: true, userId: 'u1' }),
      ],
      { sections: [{ id: 's1', name: 'One', orderKey: '80' }] },
    ),
  );
  assert.deepEqual(ids(view.team.focus).sort(), ['root', 'theirs']);
  const root = view.team.focus.find((row) => row.id === 'root');
  assert.deepEqual(ids(root.children), ['child']);
  // As desktop's isSessionInMyScope: the user's own conversation, alone; its
  // teammate opener is not listed, so it renders top-level.
  assert.deepEqual(ids(view.mine.focus), ['child']);
  assert.deepEqual(view.mine.focus[0].children, []);
  // The scope hid the pinned row and the row it carries, under its section.
  assert.deepEqual(
    view.mine.pinned.map((s) => [s.sectionId, s.hiddenCount]),
    [
      [null, 0],
      ['s1', 2],
    ],
  );
  assert.deepEqual(
    view.team.pinned.map((s) => [s.sectionId, s.hiddenCount]),
    [
      [null, 0],
      ['s1', 0],
    ],
  );
  assert.equal(CatalogStatusView.parse(view).sectionsLoaded, true);
});

test('section management waits for the section rows', () => {
  const loading = catalogStatusView(
    sources([session('s1')], { sectionsLoaded: false }),
  );
  assert.equal(loading.team.canManageSections, false);
  assert.equal(loading.mine.canManageSections, false);
  assert.equal(
    catalogStatusView(sources([session('s1')])).team.canManageSections,
    true,
  );
});

test('read-only members get no status, pin or section actions', () => {
  const view = catalogStatusView(
    sources([session('s1')], {
      readOnly: true,
      sections: [{ id: 'a', name: 'A', orderKey: '80' }],
    }),
  );
  assert.equal(view.team.canManageSections, false);
  assert.equal(view.team.focus[0].canManage, false);
  assert.equal(view.team.focus[0].canPrefer, false);
  const readOnly = sources([session('s1')], { readOnly: true });
  for (const command of [
    { type: 'settle', sessionId: 's1', includeOpened: false },
    { type: 'setPinned', sessionId: 's1', pinned: true },
    { type: 'createSection', sectionId: 'b', name: 'B' },
  ])
    assert.deepEqual(planCommand(readOnly, command), [], command.type);
});

test('send clears Later and Settled; new conversations take the top of Focus', () => {
  const state = sources([
    session('later', { snoozedUntil: NOW + 3_600_000, orderKey: '80' }),
    session('settled', { settledAt: NOW - 1000 }),
  ]);
  assert.deepEqual(
    planCommand(state, { type: 'touchOnSend', sessionId: 'later' }),
    [
      {
        type: 'session',
        sessionId: 'later',
        access: 'manage',
        patch: { snoozedUntil: null },
      },
    ],
  );
  assert.deepEqual(
    planCommand(state, { type: 'touchOnSend', sessionId: 'settled' })[0].patch,
    { settledAt: null },
  );
  const [order] = planCommand(
    state,
    { type: 'newSessionOrder', sessionId: 'fresh' },
    'team',
    () => 0,
  );
  assert.ok(order.patch.orderKey < '80', order.patch.orderKey);
});

test('a send in a Tab or side chat clears Later and Settled on its conversation', () => {
  const sessions = [
    session('root', { snoozedUntil: NOW + 3_600_000, settledAt: NOW - 5000 }),
    session('tab', { parentSessionId: 'root' }),
    session('side', {
      parentSessionId: 'tab',
      childSessionPlacement: 'side-panel',
    }),
  ];
  assert.equal(conversationOf(sessions, 'side'), 'root');
  assert.equal(conversationOf(sessions, 'tab'), 'root');
  assert.equal(conversationOf(sessions, 'root'), 'root');
  assert.equal(conversationOf(sessions, 'unknown'), 'unknown');
  const cyclic = [
    session('a', { parentSessionId: 'b' }),
    session('b', { parentSessionId: 'a' }),
  ];
  assert.ok(['a', 'b'].includes(conversationOf(cyclic, 'a')));
  // The Tab itself is not a Status row: planning for it writes nothing.
  assert.deepEqual(
    planCommand(sources(sessions), { type: 'touchOnSend', sessionId: 'tab' }),
    [],
  );
  assert.deepEqual(
    planCommand(sources(sessions), {
      type: 'touchOnSend',
      sessionId: conversationOf(sessions, 'side'),
    }),
    [
      {
        type: 'session',
        sessionId: 'root',
        access: 'manage',
        patch: { snoozedUntil: null, settledAt: null },
      },
    ],
  );
});

test('snooze presets resolve against the given clock', () => {
  const result = SnoozePresetsResult.parse(snoozePresets(NOW));
  assert.deepEqual(
    result.presets.map((p) => p.id),
    ['oneHour', 'laterToday', 'tomorrowMorning', 'nextWeek'],
  );
  assert.equal(result.presets[0].until, NOW + 3_600_000);
  assert.ok(result.presets.every((p) => p.until > NOW));
});

const replica = (name, appended, fail = false) => {
  const flock = new Flock(name);
  return {
    flock,
    client: {
      async append({ part }) {
        if (fail) return { ok: false, result: { code: 'forbidden' } };
        appended.push({ name, body: part.body });
        return { ok: true };
      },
    },
  };
};

test('planned writes land in the meta and workspace Flocks, one append each', async () => {
  const appended = [];
  const meta = replica('meta', appended);
  meta.flock.set(['m', 'session-s1', 'snoozedUntil'], 10);
  const workspace = replica('workspace', appended);
  workspace.flock.set(['pinSection', 'old'], {
    id: 'old',
    name: 'Old',
    orderKey: '7F',
  });
  const written = await applyStatusViewWrites(
    [
      { type: 'putSection', section: { id: 'a', name: 'A', orderKey: '80' } },
      { type: 'deleteSection', sectionId: 'old' },
      {
        type: 'session',
        sessionId: 's1',
        access: 'manage',
        patch: { snoozedUntil: null, settledAt: 20 },
      },
      {
        type: 'session',
        sessionId: 's2',
        access: 'prefer',
        patch: { orderKey: '7F' },
      },
    ],
    meta,
    workspace,
  );
  assert.equal(written, 4);
  assert.deepEqual(
    appended.map((entry) => entry.name),
    ['workspace', 'meta'],
  );
  assert.equal(meta.flock.get(['m', 'session-s1', 'snoozedUntil']), undefined);
  assert.equal(meta.flock.get(['m', 'session-s1', 'settledAt']), 20);
  assert.equal(meta.flock.get(['m', 'session-s2', 'orderKey']), '7F');
  assert.deepEqual(ids(pinSectionRows(workspace.flock.scan())), ['a']);
  // The appended bytes replay into a fresh replica.
  const remote = new Flock('remote');
  remote.importJson(
    JSON.parse(new TextDecoder().decode(appended[1].body.subarray(4))),
  );
  assert.equal(remote.get(['m', 'session-s1', 'settledAt']), 20);

  await assert.rejects(
    applyStatusViewWrites(
      [{ type: 'deleteSection', sectionId: 'a' }],
      meta,
      undefined,
    ),
    /workspace_not_ready/,
  );
  await assert.rejects(
    applyStatusViewWrites(
      [
        {
          type: 'session',
          sessionId: 's1',
          access: 'manage',
          patch: { settledAt: 30 },
        },
      ],
      replica('meta', [], true),
      workspace,
    ),
    /forbidden/,
  );
});

test('the server time read honours the caller signal without AbortSignal.any', async (t) => {
  const any = AbortSignal.any;
  const previousFetch = globalThis.fetch;
  t.after(() => {
    AbortSignal.any = any;
    globalThis.fetch = previousFetch;
  });
  // iOS 16.4–17.3 WebKit has no AbortSignal.any.
  AbortSignal.any = undefined;
  let seen;
  globalThis.fetch = (url, { signal }) => {
    seen = signal;
    return new Promise((resolve, reject) => {
      if (signal.aborted) reject(signal.reason);
      signal.addEventListener('abort', () => reject(signal.reason));
      if (String(url).endsWith('/api/time') && !signal.aborted)
        queueMicrotask(() =>
          resolve(new Response(JSON.stringify({ serverTime: 42 }))),
        );
    });
  };
  const caller = new AbortController();
  assert.equal(await fetchLodyServerTime(caller.signal), 42);
  assert.equal(seen.aborted, false);
  caller.abort(new Error('scope_changed'));
  await assert.rejects(fetchLodyServerTime(caller.signal), /scope_changed/);
  assert.equal(await fetchLodyServerTime(), 42);
});
