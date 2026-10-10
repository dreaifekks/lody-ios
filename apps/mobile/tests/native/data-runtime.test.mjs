import assert from 'node:assert/strict';
import test from 'node:test';
import { build } from 'esbuild';
import { Flock } from '@loro-dev/flock-wasm/base64';
import { LoroDoc } from 'loro-crdt/base64';

// These runtimes start inactive, so presence is never joined; the real
// transport would import the Streams client this file replaces.
const presenceUnused = {
  name: 'presence-unused',
  setup(build) {
    build.onResolve({ filter: /^@loro-dev\/streams-crdt\/loro$/ }, () => ({
      path: 'presence',
      namespace: 'presence-unused',
    }));
    build.onLoad({ filter: /.*/, namespace: 'presence-unused' }, () => ({
      contents:
        'export const EphemeralStoreAdaptor = undefined, EphemeralStreamCrdt = undefined;',
    }));
  },
};

test('persistent runtime applies live increments to the existing replica and advances the cursor', async () => {
  const flock = new Flock('synthetic');
  flock.set(['e', 'session-s1'], true, 1);
  flock.set(['e', 'machine-m1'], true, 1);
  flock.set(['m', 'machine-m1'], { name: 'Synthetic Mac' }, 1);
  flock.set(['m', 'session-s1'], { title: 'Before', machineId: 'm1' }, 2);
  const snapshot = flock.exportFile(),
    version = flock.version();
  flock.set(['m', 'session-s1', 'title'], 'After', 3);
  flock.set(['m', 'session-s1', 'parentSessionId'], 'parent', 4);
  const update = new TextEncoder().encode(
    JSON.stringify(flock.exportJson(version)),
  );
  const events = [];
  let nextEvent;
  const catalogEvent = () =>
    new Promise((resolve) => {
      nextEvent = resolve;
    });
  const requests = [];
  let respond;
  globalThis.__runtimeTestClient = class {
    constructor({ url }) {
      this.isMeta = decodeURIComponent(url).endsWith(':meta');
    }
    async bootstrap() {
      return {
        ok: true,
        result: {
          snapshotOffset: '1',
          nextOffset: '1',
          upToDate: true,
          snapshot: { body: snapshot },
          updates: [],
        },
      };
    }
    readOnce(request) {
      if (!this.isMeta) return new Promise(() => {});
      requests.push(request);
      return new Promise((resolve) => {
        respond = resolve;
      });
    }
  };
  globalThis.webkit = {
    messageHandlers: {
      dataRuntime: {
        postMessage(event) {
          events.push(event);
          if (event.type === 'grant')
            queueMicrotask(() =>
              globalThis.dataRuntime.grant({
                token: 'synthetic',
                gatewayBaseUrl: 'https://example.invalid',
                expiresIn: 3600,
              }),
            );
          if (event.type === 'catalog') nextEvent?.(event);
        },
      },
    },
  };
  const bundle = await build({
    entryPoints: ['apps/mobile/modules/lody-kit/data-runtime/index.ts'],
    bundle: true,
    format: 'esm',
    platform: 'browser',
    write: false,
    plugins: [
      {
        name: 'synthetic-stream',
        setup(build) {
          build.onResolve(
            { filter: /^@loro-dev\/streams-crdt\/loro$/ },
            () => ({ path: 'presence', namespace: 'presence-test' }),
          );
          build.onLoad({ filter: /.*/, namespace: 'presence-test' }, () => ({
            contents: `
              export const EphemeralStoreAdaptor = store => store;
              export class EphemeralStreamCrdt {
                constructor({ adaptor }) { this.store = adaptor; globalThis.__runtimePresence = this; }
                async join({ onStatusChange }) {
                  onStatusChange('joined');
                  return { ok: true, value: { unsubscribe() {} } };
                }
                async close() { this.closed = true; }
              }
            `,
          }));
          build.onResolve({ filter: /^\.\/files$/ }, () => ({
            path: 'files',
            namespace: 'file-test',
          }));
          build.onLoad({ filter: /.*/, namespace: 'file-test' }, () => ({
            contents: `
              export const readFile = (ctx, args) => ({ ctx, args });
              export const fileDiff = readFile;
              export const workspaceChanges = readFile;
              export const turnDiff = readFile;
              export const listDir = readFile;
            `,
          }));
          build.onResolve({ filter: /^@loro-dev\/streams-client$/ }, () => ({
            path: 'client',
            namespace: 'test',
          }));
          build.onLoad({ filter: /.*/, namespace: 'test' }, () => ({
            contents:
              'export const StreamsClient = globalThis.__runtimeTestClient;',
          }));
        },
      },
    ],
  });
  globalThis.location = { origin: 'https://example.invalid' };
  await import(
    `data:text/javascript;base64,${Buffer.from(bundle.outputFiles[0].text).toString('base64')}`
  );
  assert.deepEqual(
    await globalThis.dataRuntime.sendTurn({ sessionId: 's1', text: 'hello' }),
    { state: 'not_sent', reason: 'metadata_not_ready' },
  );
  const first = catalogEvent();
  globalThis.dataRuntime.start('synthetic-workspace');
  assert.equal(JSON.parse((await first).catalog).sessions[0].title, 'Before');
  assert.equal(requests[0].live, 'long-poll');
  const fileArgs = { sessionId: 's1', path: 'README.md', entryId: 'turn' };
  for (const method of [
    'readFile',
    'fileDiff',
    'turnDiff',
    'workspaceChanges',
  ]) {
    const request = globalThis.dataRuntime[method](fileArgs);
    assert.equal(request.ctx.ownerSessionId, 's1');
    assert.equal(request.args.sessionId, 's1');
  }
  const second = catalogEvent();
  respond({
    ok: true,
    result: {
      nextOffset: '2',
      upToDate: true,
      closed: false,
      payload: { body: update },
    },
  });
  const changed = await second;
  assert.equal(JSON.parse(changed.catalog).sessions[0].title, 'After');
  assert.equal(changed.revision, 2);
  assert.equal(
    JSON.parse(changed.catalog).sessions[0].parentSessionId,
    'parent',
  );
  // No session document was opened: ownership must come from live Meta Flock.
  for (const method of [
    'readFile',
    'fileDiff',
    'turnDiff',
    'workspaceChanges',
  ]) {
    const request = globalThis.dataRuntime[method](fileArgs);
    assert.equal(request.ctx.ownerSessionId, 'parent');
    assert.equal(request.args.sessionId, 's1');
  }
  assert.equal(requests[1].offset, '2');
  assert.equal(events.filter((e) => e.type === 'grant').length, 1);
  assert.equal(globalThis.dataRuntime.ping(), true);
  globalThis.__runtimePresence.store.set('machine:m1', {
    kind: 'machine',
    machineId: 'm1',
    instanceId: 'test',
    updatedAt: Date.now(),
  });
  await new Promise((resolve) => setTimeout(resolve, 0));
  assert.deepEqual(
    JSON.parse(
      events.filter((e) => e.type === 'machinePresence').at(-1).presence,
    ),
    {
      state: 'live',
      onlineMachineIds: ['m1'],
    },
  );
  globalThis.dataRuntime.setActive(false);
  assert.equal(globalThis.__runtimePresence.closed, true);
  assert.equal(
    JSON.parse(
      events.filter((e) => e.type === 'machinePresence').at(-1).presence,
    ).state,
    'unknown',
  );
  delete globalThis.__runtimePresence;
  delete globalThis.webkit;
  delete globalThis.location;
  delete globalThis.__runtimeTestClient;
  delete globalThis.dataRuntime;
});

test('lost results settle from reads issued after the attempt; an upload left undispatched gets its pointer', async () => {
  const turnId = '22222222-2222-4222-8222-222222222222';
  const flock = new Flock('synthetic');
  flock.set(['e', 'session-s1'], true, 1);
  flock.set(['e', 'machine-m1'], true, 1);
  flock.set(['m', 'machine-m1'], { name: 'Synthetic Mac' }, 1);
  flock.set(['m', 'session-s1'], { title: 'One', machineId: 'm1' }, 2);
  const snapshot = flock.exportFile();
  const rename = (title, clock) => {
    const version = flock.version();
    flock.set(['m', 'session-s1', 'title'], title, clock);
    return new TextEncoder().encode(JSON.stringify(flock.exportJson(version)));
  };
  const history = new LoroDoc();
  history
    .getList('history')
    .push({ id: turnId, role: 'user', status: 'pending', items: [] });
  history.commit();
  let nextEvent;
  const catalogEvent = () =>
    new Promise((resolve) => {
      nextEvent = resolve;
    });
  let respond;
  let reachable = true;
  const pointers = [];
  globalThis.__runtimeTestClient = class {
    constructor({ url }) {
      this.stream = decodeURIComponent(url).split('/ds/lody/')[1];
    }
    async bootstrap() {
      return {
        ok: true,
        result: {
          snapshotOffset: '1',
          nextOffset: '1',
          upToDate: true,
          snapshot: {
            body: this.stream.includes(':s:')
              ? history.export({ mode: 'snapshot' })
              : snapshot,
          },
          updates: [],
        },
      };
    }
    readOnce() {
      if (!this.stream.endsWith(':meta')) return new Promise(() => {});
      return new Promise((resolve) => {
        respond = (body) =>
          resolve({
            ok: true,
            result: {
              nextOffset: '2',
              upToDate: true,
              closed: false,
              payload: { body },
            },
          });
      });
    }
    async append({ part }) {
      assert.ok(
        this.stream.endsWith(':meta'),
        'a confirmation never writes history',
      );
      if (!reachable) return { ok: false, result: { code: 'timeout' } };
      const update = JSON.parse(
        new TextDecoder().decode(part.body.subarray(4)),
      );
      pointers.push(update.entries['["m","session-s1","latestUserMsgId"]']?.d);
      return { ok: true, result: {} };
    }
  };
  globalThis.webkit = {
    messageHandlers: {
      dataRuntime: {
        postMessage(event) {
          if (event.type === 'grant')
            queueMicrotask(() =>
              globalThis.dataRuntime.grant({
                token: 'synthetic',
                gatewayBaseUrl: 'https://example.invalid',
                expiresIn: 3600,
              }),
            );
          if (event.type === 'catalog') nextEvent?.(event);
        },
      },
    },
  };
  globalThis.location = { origin: 'https://example.invalid' };
  const bundle = await build({
    entryPoints: ['apps/mobile/modules/lody-kit/data-runtime/index.ts'],
    bundle: true,
    format: 'esm',
    platform: 'browser',
    write: false,
    plugins: [
      presenceUnused,
      {
        name: 'synthetic-stream',
        setup(build) {
          build.onResolve({ filter: /^@loro-dev\/streams-client$/ }, () => ({
            path: 'client',
            namespace: 'test',
          }));
          build.onLoad({ filter: /.*/, namespace: 'test' }, () => ({
            contents:
              'export const StreamsClient = globalThis.__runtimeTestClient;',
          }));
        },
      },
    ],
  });
  await import(
    `data:text/javascript;base64,${Buffer.from(bundle.outputFiles[0].text + '\n// settle').toString('base64')}`
  );
  const runtime = globalThis.dataRuntime;
  const pause = () => new Promise((resolve) => setTimeout(resolve, 5));
  const workspaceId = 'synthetic-workspace';
  const missing = 'aaaaaaaa-0000-4000-8000-000000000002';
  assert.deepEqual(
    runtime.confirmSession({ workspaceId, sessionId: missing }),
    { state: 'pending' },
    'no catalog has been read yet',
  );
  const first = catalogEvent();
  runtime.start(workspaceId, undefined, false);
  await first;
  assert.deepEqual(runtime.confirmSession({ workspaceId, sessionId: 's1' }), {
    state: 'created',
  });
  assert.deepEqual(
    runtime.confirmSession({ workspaceId, sessionId: 'other' }),
    { state: 'absent' },
    'a catalog read by this runtime postdates every earlier attempt',
  );

  await pause();
  const attempt = await runtime.createSession({
    workspaceId,
    sessionId: missing,
    machineId: 'm1',
    agentConfigId: 'none',
    userId: 'u1',
    title: 'Lost',
  });
  assert.equal(attempt.state, 'rejected');
  await pause();
  const stale = catalogEvent();
  respond(rename('Two', 3));
  await stale;
  assert.deepEqual(
    runtime.confirmSession({ workspaceId, sessionId: missing }),
    { state: 'pending' },
    'a read issued before the attempt ended proves nothing',
  );
  const fresh = catalogEvent();
  respond(rename('Three', 4));
  await fresh;
  assert.deepEqual(
    runtime.confirmSession({ workspaceId, sessionId: missing }),
    {
      state: 'absent',
    },
  );

  await runtime.ensureSession({ sessionId: 's1' });
  const verdict = { state: 'uploaded', undispatched: true };
  reachable = false;
  await assert.rejects(runtime.confirmTurn({ sessionId: 's1', id: turnId }));
  reachable = true;
  assert.deepEqual(
    await runtime.confirmTurn({ sessionId: 's1', id: turnId }),
    verdict,
  );
  assert.deepEqual(
    pointers,
    [turnId],
    'a pointer the hub refused is not remembered as published',
  );
  assert.deepEqual(
    await runtime.confirmTurn({ sessionId: 's1', id: turnId }),
    verdict,
  );
  assert.deepEqual(
    pointers,
    [turnId],
    'a published pointer is not written twice',
  );
  delete globalThis.webkit;
  delete globalThis.location;
  delete globalThis.__runtimeTestClient;
  delete globalThis.dataRuntime;
});

test('a catalog read that fails on the network resumes from its cursor instead of reading every catalog again', async () => {
  const flock = new Flock('synthetic');
  flock.set(['e', 'session-s1'], true, 1);
  flock.set(['e', 'machine-m1'], true, 1);
  flock.set(['m', 'machine-m1'], { name: 'Synthetic Mac' }, 1);
  flock.set(['m', 'session-s1'], { title: 'Before', machineId: 'm1' }, 2);
  const snapshot = flock.exportFile(),
    version = flock.version();
  flock.set(['m', 'session-s1', 'title'], 'After', 3);
  const update = new TextEncoder().encode(
    JSON.stringify(flock.exportJson(version)),
  );
  const events = [];
  let nextEvent;
  const catalogEvent = () =>
    new Promise((resolve) => {
      nextEvent = resolve;
    });
  const requests = [];
  let bootstraps = 0;
  let respond;
  globalThis.__runtimeTestClient = class {
    constructor({ url }) {
      this.isMeta = decodeURIComponent(url).endsWith(':meta');
    }
    async bootstrap() {
      bootstraps++;
      return {
        ok: true,
        result: {
          snapshotOffset: '1',
          nextOffset: '1',
          upToDate: true,
          snapshot: { body: snapshot },
          updates: [],
        },
      };
    }
    readOnce(request) {
      if (!this.isMeta) return new Promise(() => {});
      requests.push(request);
      return new Promise((resolve) => {
        respond = resolve;
      });
    }
  };
  globalThis.webkit = {
    messageHandlers: {
      dataRuntime: {
        postMessage(event) {
          events.push(event);
          if (event.type === 'grant')
            queueMicrotask(() =>
              globalThis.dataRuntime.grant({
                token: 'synthetic',
                gatewayBaseUrl: 'https://example.invalid',
                expiresIn: 3600,
              }),
            );
          if (event.type === 'catalog') nextEvent?.(event);
        },
      },
    },
  };
  globalThis.location = { origin: 'https://example.invalid' };
  const bundle = await build({
    entryPoints: ['apps/mobile/modules/lody-kit/data-runtime/index.ts'],
    bundle: true,
    format: 'esm',
    platform: 'browser',
    write: false,
    plugins: [
      presenceUnused,
      {
        name: 'synthetic-stream',
        setup(build) {
          build.onResolve({ filter: /^@loro-dev\/streams-client$/ }, () => ({
            path: 'client',
            namespace: 'test',
          }));
          build.onLoad({ filter: /.*/, namespace: 'test' }, () => ({
            contents:
              'export const StreamsClient = globalThis.__runtimeTestClient;',
          }));
        },
      },
    ],
  });
  await import(
    `data:text/javascript;base64,${Buffer.from(bundle.outputFiles[0].text + '\n// resume').toString('base64')}`
  );
  const runtime = globalThis.dataRuntime;
  const workspaceId = 'synthetic-workspace';
  const first = catalogEvent();
  runtime.start(workspaceId, undefined, false);
  await first;
  assert.equal(bootstraps, 2, 'the catalog and its one machine');
  const errors = () => events.filter((event) => event.type === 'syncError');
  assert.equal(errors().length, 0);

  const realNow = Date.now;
  let skew = 0;
  Date.now = () => realNow() + skew;
  const readsAfter = async (count) => {
    for (let i = 0; i < 400 && requests.length < count; i++)
      await new Promise((resolve) => setTimeout(resolve, 5));
    assert.equal(requests.length, count, 'the read goes again after a pause');
  };
  respond({ ok: false, result: { code: 'network_error' } });
  await readsAfter(2);
  assert.equal(requests[1].offset, requests[0].offset);
  assert.equal(bootstraps, 2, 'no catalog is downloaded again');
  assert.equal(errors().length, 0, 'one dropped read does not flap the sync');

  skew = 16_000;
  respond({ ok: false, result: { code: 'network_error' } });
  await readsAfter(3);
  assert.equal(requests[2].offset, requests[0].offset);
  assert.equal(bootstraps, 2, 'no catalog is downloaded again');
  assert.deepEqual(
    errors().map((event) => event.stream),
    ['meta'],
    'a catalog that stays unreadable is not reported as live',
  );
  assert.deepEqual(
    runtime.confirmSession({ workspaceId, sessionId: 's1' }),
    { state: 'created' },
    'the replica is kept while its tail is unknown',
  );
  assert.deepEqual(
    await runtime.createSession({
      workspaceId,
      sessionId: 'aaaaaaaa-0000-4000-8000-000000000003',
    }),
    { state: 'rejected', reason: 'metadata_not_ready' },
    'a creation refused while reconnecting is refused as retryable',
  );
  Date.now = realNow;

  const synced = events.filter((event) => event.type === 'synced').length;
  const recovered = catalogEvent();
  respond({
    ok: true,
    result: {
      nextOffset: '2',
      upToDate: true,
      closed: false,
      payload: { body: update },
    },
  });
  assert.equal(
    JSON.parse((await recovered).catalog).sessions[0].title,
    'After',
  );
  assert.ok(
    events.filter((event) => event.type === 'synced').length > synced,
    'a read that succeeds reports the catalog live again',
  );
  assert.equal(bootstraps, 2);
  assert.equal(errors().length, 1);

  // Days of live updates outgrow the 8 MiB ceiling: the catalog reads its
  // compacted snapshot again instead of stopping for good.
  const reads = requests.length;
  for (let i = 0; i < 400 && requests.length === reads; i++)
    await new Promise((resolve) => setTimeout(resolve, 5));
  respond({
    ok: true,
    result: {
      nextOffset: '3',
      upToDate: true,
      closed: false,
      payload: { body: new Uint8Array(8 * 1024 * 1024 + 1) },
    },
  });
  for (let i = 0; i < 400 && bootstraps < 3; i++)
    await new Promise((resolve) => setTimeout(resolve, 5));
  assert.equal(bootstraps, 3, 'the catalog bootstraps again');
  assert.equal(errors().length, 1, 'and is never reported offline for it');
  delete globalThis.webkit;
  delete globalThis.location;
  delete globalThis.__runtimeTestClient;
  delete globalThis.dataRuntime;
});
