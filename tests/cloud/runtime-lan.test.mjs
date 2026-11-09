import assert from 'node:assert/strict';
import test from 'node:test';
import { build } from 'esbuild';
import { Flock } from '@loro-dev/flock-wasm/base64';
import { LoroDoc } from 'loro-crdt/base64';

const settle = () => new Promise((resolve) => setImmediate(resolve));
async function until(check) {
  const deadline = Date.now() + 5000;
  while (!check()) {
    if (Date.now() > deadline) assert.fail('runtime condition timed out');
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
}
const ok = (result) => ({ ok: true, result });
const failure = (code) => ({ ok: false, result: { code } });
async function harness({
  meta = new Flock('catalog'),
  history = new LoroDoc(),
  machine = new Flock('machine'),
  onRead,
  onAppend,
} = {}) {
  const events = [],
    reads = [],
    bootstraps = [],
    appends = [],
    replies = new Map();
  const snapshot = meta.exportFile();
  globalThis.__lanRuntimeClient = class {
    constructor({ url }) {
      this.stream = decodeURIComponent(url).split('/ds/lody/')[1];
    }
    async bootstrap() {
      bootstraps.push(this.stream);
      let body = snapshot;
      if (this.stream.includes(':s:'))
        body = history.export({ mode: 'snapshot' });
      else if (this.stream.includes(':mf:')) body = machine.exportFile();
      return ok({
        snapshotOffset: '7',
        snapshot: { body },
        updates: [],
        nextOffset: '7',
        cursor: 'cursor-7',
        upToDate: true,
      });
    }
    async readOnce(request) {
      const item = { ...request, stream: this.stream };
      reads.push(item);
      if (this.stream.endsWith(':meta') && onRead)
        return onRead(
          item,
          reads.filter((r) => r.stream === this.stream).length,
        );
      return new Promise(() => {});
    }
    async create() {
      return ok({});
    }
    async append(request) {
      appends.push(request);
      return onAppend ? onAppend(request) : ok({});
    }
  };
  globalThis.webkit = {
    messageHandlers: {
      dataRuntime: {
        postMessage(event) {
          if (event.type !== 'envelope') return;
          const message = JSON.parse(event.envelope);
          events.push(message);
          if (message.kind === 'request' && message.method === 'grant') {
            queueMicrotask(() =>
              receive({
                ...message,
                kind: 'result',
                payload: {
                  token: 'fixture',
                  gatewayBaseUrl: 'https://example.invalid',
                  expiresIn: 3600,
                },
              }),
            );
          } else if (message.kind === 'result' || message.kind === 'error')
            replies.get(message.id)?.(message);
        },
      },
    },
  };
  const bundle = await build({
    entryPoints: ['packages/cloud-runtime/src/runtime/index.ts'],
    bundle: true,
    format: 'esm',
    platform: 'browser',
    write: false,
    plugins: [
      {
        name: 'offline-streams',
        setup(b) {
          b.onResolve({ filter: /^@loro-dev\/streams-crdt\/loro$/ }, () => ({
            path: 'presence',
            namespace: 'presence-fixture',
          }));
          b.onLoad({ filter: /.*/, namespace: 'presence-fixture' }, () => ({
            contents:
              'export const EphemeralStoreAdaptor = s => s; export class EphemeralStreamCrdt { join() { throw new Error("presence must stay offline"); } }',
          }));
          b.onResolve({ filter: /^@loro-dev\/streams-client$/ }, () => ({
            path: 'client',
            namespace: 'fixture',
          }));
          b.onLoad({ filter: /.*/, namespace: 'fixture' }, () => ({
            contents:
              'export const StreamsClient = globalThis.__lanRuntimeClient;',
          }));
        },
      },
    ],
  });
  await import(
    `data:text/javascript;base64,${Buffer.from(bundle.outputFiles[0].text + `\n// ${crypto.randomUUID()}`).toString('base64')}`
  );
  const receive = (message) =>
    globalThis.dataRuntime.receive(JSON.stringify(message));
  let next = 0;
  const call = (method, payload = {}) => {
    const id = `req-${++next}`;
    const result = new Promise((resolve) => replies.set(id, resolve));
    receive({ v: 1, gen: 1, kind: 'request', id, method, payload });
    return result;
  };
  await call('hello', { protocol: 1, gen: 1 });
  await call('start', { workspaceId: 'w', userId: 'local:hub', active: false });
  await until(() => events.some((e) => e.method === 'synced'));
  return { call, events, reads, bootstraps, appends };
}

test('catalog transport failures keep the replica and cursor, leave live after grace, and resume without bootstrap', async (t) => {
  let second, third;
  let now = Date.now();
  t.mock.method(Date, 'now', () => now);
  const f = await harness({
    onRead(request, n) {
      if (n === 1) return failure('network_error');
      if (n === 2)
        return new Promise((resolve) => {
          second = resolve;
        });
      if (n === 3)
        return new Promise((resolve) => {
          third = resolve;
        });
      return new Promise(() => {});
    },
  });
  await until(() => second);
  assert.equal(f.events.filter((e) => e.method === 'syncError').length, 0);
  now += 16000;
  second(failure('timeout'));
  await until(() => f.events.some((e) => e.method === 'syncError'));
  await until(() => third);
  const previousSynced = f.events.filter((e) => e.method === 'synced').length;
  third(
    ok({ nextOffset: '8', cursor: 'cursor-8', upToDate: true, closed: false }),
  );
  await until(
    () => f.events.filter((e) => e.method === 'synced').length > previousSynced,
  );
  assert.deepEqual(f.bootstraps, ['w:meta']);
  assert.deepEqual(
    f.reads.slice(0, 3).map((r) => [r.offset, r.cursor]),
    Array(3).fill(['7', 'cursor-7']),
  );
  assert.deepEqual(
    [f.reads.at(-1).offset, f.reads.at(-1).cursor],
    ['8', 'cursor-8'],
  );
  assert.equal(f.appends.length, 0);
});

test('a thrown catalog transport error keeps the same cursor; a gone cursor bootstraps instead', async () => {
  let recover;
  const f = await harness({
    onRead(_request, n) {
      if (n === 1) throw new Error('connection closed');
      if (n === 2) return failure('gone');
      recover = true;
      return new Promise(() => {});
    },
  });
  await until(() => recover);
  assert.deepEqual(f.bootstraps, ['w:meta', 'w:meta']);
  assert.deepEqual(
    f.reads.map((r) => r.cursor),
    ['cursor-7', 'cursor-7', 'cursor-7'],
  );
});

test('a live catalog crossing 8 MiB retains its display and reports non-live until a fresh snapshot catches up', async () => {
  let restart;
  const f = await harness({
    onRead(_request, n) {
      if (n === 1)
        return ok({
          payload: { body: new Uint8Array(8 * 1024 * 1024) },
          nextOffset: '8',
          upToDate: true,
        });
      restart = true;
      return new Promise(() => {});
    },
  });
  await until(() => restart);
  assert.equal(f.events.filter((e) => e.method === 'catalog').length, 1);
  const error = f.events.findIndex(
    (e) => e.method === 'syncError' && e.payload.reason === 'catalog_limit',
  );
  assert.ok(error >= 0);
  assert.ok(
    f.events
      .slice(error + 1)
      .some(
        (e) => e.method === 'diagnostic' && e.payload.stage === 'bootstrap',
      ),
  );
  assert.deepEqual(f.bootstraps, ['w:meta', 'w:meta']);
});

test('typed confirmation repairs a seen turn pointer only after ACK and appends a producer tuple', async () => {
  const meta = new Flock('meta-pointer');
  meta.set(['e', 'session-s'], true);
  meta.set(['m', 'session-s'], { machineId: 'm', userId: 'local:hub' });
  meta.commit();
  const history = new LoroDoc();
  history
    .getList('history')
    .push({ id: 't', role: 'user', status: 'seen', items: [] });
  history.commit();
  const pending = [];
  const f = await harness({
    meta,
    history,
    onAppend(request) {
      assert.ok(request.producer.producerId);
      assert.deepEqual([request.producer.epoch, request.producer.seq], [0, 0]);
      const copy = new Flock(`candidate-${pending.length}`);
      copy.importFile(meta.exportFile());
      copy.importJson(
        JSON.parse(new TextDecoder().decode(request.part.body.subarray(4))),
      );
      assert.equal(copy.get(['m', 'session-s', 'latestUserMsgId']), 't');
      return new Promise((resolve) => pending.push(resolve));
    },
  });
  await f.call('ensureSession', { sessionId: 's' });
  const first = f.call('confirmSessionTurn', { sessionId: 's', id: 't' });
  await until(() => pending.length === 1);
  const second = f.call('confirmSessionTurn', { sessionId: 's', id: 't' });
  await until(() => pending.length === 2);
  // A second confirmation still appends while the first pointer is unacknowledged.
  pending.splice(0).forEach((resolve) => resolve(ok({})));
  assert.deepEqual((await first).payload, {
    state: 'seen',
    delivery: 'uploaded',
  });
  assert.deepEqual((await second).payload, {
    state: 'seen',
    delivery: 'uploaded',
  });
  assert.deepEqual(
    (await f.call('confirmSessionTurn', { sessionId: 's', id: 't' })).payload,
    { state: 'seen', delivery: 'uploaded' },
  );
  assert.equal(f.appends.length, 2);
  const absent = (
    await f.call('confirmSessionTurn', { sessionId: 's', id: 'absent' })
  ).payload;
  assert.equal(absent.state, 'absent');
  assert.match(absent.retryId, /^[0-9a-f-]{36}$/);
  assert.deepEqual(
    (
      await f.call('confirmSessionCreation', {
        workspaceId: 'w',
        sessionId: 's',
      })
    ).payload,
    { state: 'seen' },
  );
});

test('creation confirmation waits for a read issued after the uncertain attempt ended', async () => {
  const meta = new Flock('creation-meta'),
    machine = new Flock('creation-machine');
  meta.set(['e', 'machine-m'], true);
  meta.set(['m', 'machine-m'], { name: 'Fixture' });
  meta.commit();
  machine.set(['agentConfig', 'a'], {
    id: 'a',
    machineId: 'm',
    name: 'Agent',
    cliType: 'builtin',
    agentType: 'codex',
  });
  machine.commit();
  const waiting = [];
  const f = await harness({
    meta,
    machine,
    onRead() {
      return new Promise((resolve) => waiting.push(resolve));
    },
    onAppend: () => failure('timeout'),
  });
  const sessionId = crypto.randomUUID();
  const args = {
    workspaceId: 'w',
    sessionId,
    machineId: 'm',
    agentConfigId: 'a',
    userId: 'local:hub',
    title: 'Fixture',
    billingEntitlement: null,
  };
  assert.equal((await f.call('createSession', args)).payload.state, 'unknown');
  const confirm = () =>
    f.call('confirmSessionCreation', { workspaceId: 'w', sessionId });
  assert.deepEqual((await confirm()).payload, { state: 'pending' });
  waiting[0](ok({ nextOffset: '8', cursor: 'cursor-8', upToDate: true }));
  await until(() => waiting.length === 2);
  assert.deepEqual(
    (await confirm()).payload,
    { state: 'pending' },
    'the delayed old poll cannot prove absence',
  );
  const synced = f.events.filter((e) => e.method === 'synced').length;
  waiting[1](ok({ nextOffset: '9', cursor: 'cursor-9', upToDate: true }));
  await until(
    () => f.events.filter((e) => e.method === 'synced').length > synced,
  );
  assert.deepEqual((await confirm()).payload, { state: 'absent' });
  assert.equal(
    (await f.call('createSession', args)).payload.state,
    'unknown',
    'proved absence releases the attempted creation ID',
  );
  assert.equal(f.appends.length, 2);
});
