import assert from 'node:assert/strict';
import test from 'node:test';
import { build } from 'esbuild';
import { Flock } from '@loro-dev/flock-wasm/base64';

const DAY = 86_400_000;

// The production runtime bundle over synthetic streams: meta, the workspace
// settings Flock and one machine. Nothing reaches the network.
async function runtimeFixture({
  signal,
  serverOffset,
  workspaceMissing = false,
  failAppend = () => false,
  serverTime = () => Date.now() + serverOffset,
}) {
  const now = Date.now();
  const meta = new Flock('meta');
  meta.set(['e', 'machine-m1'], true);
  meta.set(['m', 'machine-m1'], { name: 'Mac', ownerUserId: 'u1' });
  for (const [id, fields] of [
    // Quiet for a day on the device clock, eleven days on the server's.
    ['recent', { lastMessageAt: now - DAY }],
    ['other', { lastMessageAt: now + serverOffset - 60_000 }],
  ]) {
    meta.set(['e', `session-${id}`], true);
    meta.set(['m', `session-${id}`], {
      id,
      machineId: 'm1',
      userId: 'u1',
      title: id,
      status: { type: 'idle' },
      createdAt: new Date(now - 2 * DAY).toISOString(),
      lastReadAt: now + serverOffset,
      ...fields,
    });
  }
  const workspace = new Flock('workspace');
  workspace.set(['pinSection', 's1'], {
    id: 's1',
    name: 'One',
    orderKey: '80',
  });
  const snapshots = {
    'w1:meta': meta.exportFile(),
    ...(workspaceMissing ? {} : { 'w1:wf:workspace': workspace.exportFile() }),
    'w1:mf:m1': new Flock('machine').exportFile(),
  };
  // A stream is its snapshot plus every accepted append, as the server keeps it.
  const accepted = new Map();
  const created = [];
  const appends = [];
  const bootstraps = [];
  globalThis.__statusClient = class {
    constructor({ url }) {
      this.stream = decodeURIComponent(url.split('/ds/lody/')[1]);
    }
    async bootstrap() {
      bootstraps.push(this.stream);
      const body = snapshots[this.stream];
      const parts = accepted.get(this.stream) ?? [];
      if (!body && !created.includes(this.stream))
        return { ok: false, result: { code: 'not_found' } };
      return {
        ok: true,
        result: {
          snapshotOffset: body ? '1' : '-1',
          nextOffset: String(1 + parts.length),
          upToDate: true,
          ...(body ? { snapshot: { body } } : {}),
          updates: parts.map((part) => ({ body: part })),
        },
      };
    }
    readOnce() {
      return new Promise(() => {});
    }
    async create() {
      const exists = !!snapshots[this.stream] || created.includes(this.stream);
      if (!exists) created.push(this.stream);
      return { ok: true, result: { created: !exists } };
    }
    async append({ part }) {
      const update = JSON.parse(
        new TextDecoder().decode(part.body.subarray(4)),
      );
      if (failAppend(this.stream, update))
        return { ok: false, result: { code: 'network_error' } };
      if (!snapshots[this.stream] && !created.includes(this.stream))
        return { ok: false, result: { code: 'not_found' } };
      appends.push({ stream: this.stream, update });
      accepted.set(this.stream, [
        ...(accepted.get(this.stream) ?? []),
        part.body,
      ]);
      return { ok: true };
    }
  };
  const previousFetch = globalThis.fetch;
  globalThis.fetch = async (url) => {
    assert.match(String(url), /\/api\/time$/);
    return new Response(JSON.stringify({ serverTime: serverTime() }));
  };
  const catalogs = [];
  const waiters = [];
  const replies = new Map();
  const events = [];
  globalThis.webkit = {
    messageHandlers: {
      dataRuntime: {
        postMessage(event) {
          if (event.type !== 'envelope') return;
          const message = JSON.parse(event.envelope);
          if (message.kind === 'event') events.push(message);
          replies.get(message.id)?.(message);
          if (message.kind === 'request' && message.method === 'grant')
            queueMicrotask(() =>
              globalThis.dataRuntime.receive(
                JSON.stringify({
                  v: 1,
                  gen: message.gen,
                  kind: 'result',
                  id: message.id,
                  method: 'grant',
                  payload: {
                    token: 'synthetic',
                    gatewayBaseUrl: 'https://example.invalid',
                    expiresIn: 3600,
                  },
                }),
              ),
            );
          if (message.kind === 'event' && message.method === 'catalog') {
            const catalog = JSON.parse(message.payload.catalog);
            catalogs.push(catalog);
            for (const waiter of [...waiters])
              if (waiter.match(catalog)) {
                waiters.splice(waiters.indexOf(waiter), 1);
                waiter.resolve(catalog);
              }
          }
        },
      },
    },
  };
  const root = new URL('../../../../', import.meta.url).pathname;
  const bundle = await build({
    absWorkingDir: root,
    entryPoints: ['packages/cloud-runtime/src/runtime/index.ts'],
    bundle: true,
    format: 'esm',
    platform: 'browser',
    write: false,
    plugins: [
      {
        name: 'synthetic-streams',
        setup(build) {
          build.onResolve({ filter: /^loro-crdt$/ }, () =>
            build.resolve('loro-crdt/base64', {
              resolveDir: root,
              kind: 'import-statement',
            }),
          );
          build.onResolve(
            { filter: /^@loro-dev\/streams-crdt\/loro$/ },
            () => ({ path: 'presence', namespace: 'status-test' }),
          );
          build.onResolve({ filter: /^@loro-dev\/streams-client$/ }, () => ({
            path: 'client',
            namespace: 'status-test',
          }));
          build.onLoad({ filter: /.*/, namespace: 'status-test' }, (args) => ({
            contents:
              args.path === 'client'
                ? 'export const StreamsClient = globalThis.__statusClient;'
                : `export const EphemeralStoreAdaptor = store => store;
                   export class EphemeralStreamCrdt {
                     async join({ onStatusChange }) {
                       onStatusChange('joined');
                       return { ok: true, value: { unsubscribe() {} } };
                     }
                     async close() {}
                   }`,
          }));
        },
      },
    ],
  });
  const previousBroadcastChannel = globalThis.BroadcastChannel;
  globalThis.BroadcastChannel = undefined;
  await import(
    `data:text/javascript;base64,${Buffer.from(`${bundle.outputFiles[0].text}\n// ${crypto.randomUUID()}`).toString('base64')}`
  );
  let next = 0;
  const call = (method, payload = {}) => {
    const id = `call-${++next}`;
    const reply = new Promise((resolve) => replies.set(id, resolve));
    globalThis.dataRuntime.receive(
      JSON.stringify({ v: 1, gen: 1, kind: 'request', id, method, payload }),
    );
    return reply;
  };
  // Waits end with the test: a missing catalog fails the test, never hangs it.
  const catalog = (match) =>
    catalogs.find(match) ??
    new Promise((resolve, reject) => {
      waiters.push({ match, resolve });
      signal?.addEventListener('abort', () => reject(signal.reason), {
        once: true,
      });
    });
  return {
    call,
    catalog,
    appends,
    created,
    bootstraps,
    catalogs,
    events,
    dispose() {
      delete globalThis.webkit;
      delete globalThis.__statusClient;
      delete globalThis.dataRuntime;
      globalThis.fetch = previousFetch;
      globalThis.BroadcastChannel = previousBroadcastChannel;
    },
  };
}

test(
  'the runtime publishes the Status view on the server clock and applies commands to both Flocks',
  { timeout: 30_000 },
  async (t) => {
    const serverOffset = 10 * DAY;
    const runtime = await runtimeFixture({ signal: t.signal, serverOffset });
    try {
      await runtime.call('hello', { protocol: 1, gen: 1 });
      await runtime.call('start', {
        workspaceId: 'w1',
        userId: 'u1',
        active: true,
      });
      const ready = await runtime.catalog(
        (c) =>
          c.statusView?.sectionsLoaded &&
          c.statusView.team.settled.some((row) => row.id === 'recent'),
      );
      // Eleven quiet days on the server clock settle a row the device sees as recent.
      assert.ok(ready.statusView.nowMs >= Date.now() + serverOffset - 60_000);
      assert.deepEqual(
        ready.pinSections.map((s) => s.id),
        ['s1'],
      );
      assert.deepEqual(
        ready.statusView.team.pinned.map((s) => s.sectionId),
        [null, 's1'],
      );
      assert.deepEqual(
        ready.statusView.mine.focus.map((row) => [row.id, row.canManage]),
        [['other', true]],
      );
      assert.equal(ready.statusView.team.canManageSections, true);

      const created = await runtime.call('statusViewCommand', {
        workspaceId: 'w1',
        command: { type: 'createSection', sectionId: 's2', name: 'Two' },
      });
      assert.deepEqual(created.payload, { writes: 1 });
      assert.deepEqual(
        runtime.appends.map((a) => a.stream),
        ['w1:wf:workspace'],
      );
      await runtime.catalog((c) => c.pinSections.some((s) => s.id === 's2'));

      const moved = await runtime.call('statusViewCommand', {
        workspaceId: 'w1',
        scope: 'mine',
        command: {
          type: 'move',
          sessionId: 'other',
          to: { area: 'pinned', sectionId: 's2' },
          beforeId: null,
        },
      });
      assert.deepEqual(moved.payload, { writes: 1 });
      assert.equal(runtime.appends.at(-1).stream, 'w1:meta');
      const pinned = await runtime.catalog(
        (c) =>
          c.statusView?.team.pinned.find((s) => s.sectionId === 's2')?.rows[0]
            ?.id === 'other',
      );
      assert.equal(
        pinned.sessions.find((s) => s.id === 'other').pinSectionId,
        's2',
      );

      // A command the planner refuses writes nothing.
      const refused = await runtime.call('statusViewCommand', {
        workspaceId: 'w1',
        command: {
          type: 'snooze',
          sessionId: 'other',
          until: 1,
          includeOpened: false,
        },
      });
      assert.deepEqual(refused.payload, { writes: 0 });
      const wrong = await runtime.call('statusViewCommand', {
        workspaceId: 'w2',
        command: { type: 'deleteSection', sectionId: 's2' },
      });
      assert.equal(wrong.kind, 'error');

      const presets = await runtime.call('snoozePresets');
      assert.ok(presets.payload.nowMs >= Date.now() + serverOffset - 60_000);
      assert.equal(
        presets.payload.presets[0].until,
        presets.payload.nowMs + 3_600_000,
      );
      // The settings stream is not a workspace sync failure.
      assert.equal(
        runtime.events.some((e) => e.method === 'syncError'),
        false,
      );
    } finally {
      await runtime.call('setActive', { active: false });
      runtime.dispose();
    }
  },
);

// Event-loop turns only, bounded: the runtime's own work settles in microtasks
// and zero-delay checkpoints.
async function until(condition, turns = 2000) {
  for (let turn = 0; turn < turns; turn++) {
    if (condition()) return;
    await new Promise((resolve) => setImmediate(resolve));
  }
  throw new Error('condition not reached');
}

test(
  'the first pin section in a workspace without a settings stream creates that stream',
  { timeout: 30_000 },
  async (t) => {
    const runtime = await runtimeFixture({
      signal: t.signal,
      serverOffset: 0,
      workspaceMissing: true,
    });
    try {
      await runtime.call('hello', { protocol: 1, gen: 1 });
      await runtime.call('start', {
        workspaceId: 'w1',
        userId: 'u1',
        active: true,
      });
      const empty = await runtime.catalog(
        (c) =>
          c.statusView?.sectionsLoaded && c.statusView.team.canManageSections,
      );
      assert.deepEqual(empty.pinSections, []);
      const first = await runtime.call('statusViewCommand', {
        workspaceId: 'w1',
        command: { type: 'createSection', sectionId: 's9', name: 'New' },
      });
      assert.deepEqual(first.payload, { writes: 1 });
      assert.deepEqual(runtime.created, ['w1:wf:workspace']);
      assert.equal(runtime.appends.at(-1).stream, 'w1:wf:workspace');
      await runtime.catalog((c) => c.pinSections.some((s) => s.id === 's9'));
      // The read restarts at once and gets the section back from the stream.
      await until(
        () =>
          runtime.bootstraps.filter((s) => s === 'w1:wf:workspace').length >= 2,
      );
      const second = await runtime.call('statusViewCommand', {
        workspaceId: 'w1',
        command: { type: 'createSection', sectionId: 's10', name: 'Next' },
      });
      assert.deepEqual(second.payload, { writes: 1 });
      assert.deepEqual(runtime.created, ['w1:wf:workspace'], 'created once');
      const both = await runtime.catalog((c) => c.pinSections.length === 2);
      assert.deepEqual(
        both.pinSections.map((s) => s.id),
        ['s9', 's10'],
      );
    } finally {
      await runtime.call('setActive', { active: false });
      runtime.dispose();
    }
  },
);

test(
  'a failed append drops its unsent commit: the replica is read again and never shows it',
  { timeout: 30_000 },
  async (t) => {
    let failing = true;
    const runtime = await runtimeFixture({
      signal: t.signal,
      serverOffset: 0,
      failAppend: (stream) => failing && stream === 'w1:meta',
    });
    try {
      await runtime.call('hello', { protocol: 1, gen: 1 });
      await runtime.call('start', {
        workspaceId: 'w1',
        userId: 'u1',
        active: true,
      });
      await runtime.catalog((c) =>
        c.statusView?.team.focus.some((row) => row.id === 'other'),
      );
      const refused = await runtime.call('statusViewCommand', {
        workspaceId: 'w1',
        command: { type: 'settle', sessionId: 'other', includeOpened: false },
      });
      assert.equal(refused.kind, 'error');
      await until(
        () => runtime.bootstraps.filter((s) => s === 'w1:meta').length >= 2,
      );
      failing = false;
      // A later, successful write republishes from the rebuilt replica (retried
      // over event-loop turns while that replica is still being read).
      const pin = () =>
        runtime.call('statusViewCommand', {
          workspaceId: 'w1',
          command: { type: 'setPinned', sessionId: 'recent', pinned: true },
        });
      let reply = await pin();
      for (
        let attempt = 0;
        reply.kind === 'error' && attempt < 200;
        attempt++
      ) {
        await new Promise((resolve) => setImmediate(resolve));
        reply = await pin();
      }
      assert.deepEqual(reply.payload, { writes: 1 });
      const after = await runtime.catalog((c) =>
        c.sessions.some((s) => s.id === 'recent' && s.pinned),
      );
      assert.equal(
        after.sessions.find((s) => s.id === 'other').settledAt,
        undefined,
      );
      assert.ok(after.statusView.team.focus.some((row) => row.id === 'other'));
      assert.ok(
        runtime.catalogs.every((c) =>
          c.sessions.every(
            (s) => s.id !== 'other' || s.settledAt === undefined,
          ),
        ),
      );
    } finally {
      await runtime.call('setActive', { active: false });
      runtime.dispose();
    }
  },
);

test(
  'a new server-clock calibration republishes the catalog even when nothing else changed',
  { timeout: 30_000 },
  async (t) => {
    let offset = 10 * 60_000;
    const runtime = await runtimeFixture({
      signal: t.signal,
      serverOffset: offset,
      serverTime: () => Date.now() + offset,
    });
    try {
      await runtime.call('hello', { protocol: 1, gen: 1 });
      await runtime.call('start', {
        workspaceId: 'w1',
        userId: 'u1',
        active: true,
      });
      const first = await runtime.catalog(
        (c) =>
          c.statusView?.sectionsLoaded &&
          c.statusView.nowMs - Date.now() > 9 * 60_000,
      );
      assert.ok(first.statusView.nowMs - Date.now() < 11 * 60_000);
      offset = 20 * 60_000;
      // A device clock adjustment invalidates the recent calibration on resume.
      const wallNow = Date.now.bind(Date);
      t.mock.method(Date, 'now', () => wallNow() + 5_000);
      await runtime.call('setActive', { active: true });
      const second = await runtime.catalog(
        (c) => c.statusView && c.statusView.nowMs - Date.now() > 19 * 60_000,
      );
      assert.deepEqual(second.statusView.team, first.statusView.team);
    } finally {
      await runtime.call('setActive', { active: false });
      runtime.dispose();
    }
  },
);
