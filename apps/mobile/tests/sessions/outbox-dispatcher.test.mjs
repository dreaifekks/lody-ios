import test from 'node:test';
import assert from 'node:assert/strict';
import { build } from 'esbuild';

const tick = () => new Promise((resolve) => setImmediate(resolve));
function deferred() {
  let resolve;
  const promise = new Promise((done) => {
    resolve = done;
  });
  return { promise, resolve };
}
function harness() {
  const cells = [];
  let cursor = 0,
    hook,
    input,
    result,
    mounted = true,
    queued = false;
  const effects = [];
  const schedule = () => {
    if (queued) return;
    queued = true;
    queueMicrotask(() => {
      queued = false;
      render();
    });
  };
  function render() {
    if (!mounted) return;
    cursor = 0;
    result = hook(input);
    effects.splice(0).forEach((effect) => effect());
  }
  return {
    react: {
      useRef(value) {
        const index = cursor++;
        return (cells[index] ??= { current: value });
      },
      useState(value) {
        const index = cursor++;
        if (!(index in cells)) cells[index] = value;
        return [
          cells[index],
          (next) => {
            const updated =
              typeof next === 'function' ? next(cells[index]) : next;
            if (Object.is(cells[index], updated)) return;
            cells[index] = updated;
            schedule();
          },
        ];
      },
      useEffect(effect, deps) {
        const index = cursor++;
        if (
          cells[index] &&
          deps.every((dep, i) => Object.is(dep, cells[index].deps[i]))
        )
          return;
        const previous = cells[index];
        const current = { deps };
        cells[index] = current;
        effects.push(() => {
          previous?.cleanup?.();
          current.cleanup = effect();
        });
      },
    },
    start(fn, args) {
      hook = fn;
      input = args;
      render();
    },
    update(change) {
      Object.assign(input, change);
      schedule();
    },
    unmount() {
      mounted = false;
      cells.forEach((cell) => cell?.cleanup?.());
    },
  };
}

const session = {
  id: 's1',
  machineId: 'm1',
  cliType: 'builtin',
  agentType: 'codex',
  archived: false,
  status: 'idle',
};
const draft = {
  id: 'BFBAD3D5-3B07-4E9A-BA66-FC3002179887',
  text: 'hello',
  startedAt: 1_780_000_000_000,
  attachments: [],
  choice: {},
  phase: 'waiting',
};

async function load(hooks, native) {
  globalThis.__outboxHooks = hooks;
  globalThis.__outboxNative = native;
  const bundle = await build({
    entryPoints: [
      new URL('../../src/cloud/send/outboxDispatcher.ts', import.meta.url)
        .pathname,
    ],
    bundle: true,
    format: 'esm',
    write: false,
    plugins: [
      {
        name: 'hooks',
        setup(b) {
          b.onResolve(
            { filter: /^(react|react-native|@lody-ios\/kit)$/ },
            ({ path }) => ({ path, namespace: 'mock' }),
          );
          b.onLoad({ filter: /.*/, namespace: 'mock' }, ({ path }) => ({
            contents: {
              react:
                'export const {useEffect,useRef,useState}=globalThis.__outboxHooks;',
              'react-native': 'export const Alert={alert(){}};',
              '@lody-ios/kit':
                'export const {createSession,sendSessionTurn,confirmSessionCreation,confirmSessionTurn,ensureSession,releaseReserve}=globalThis.__outboxNative;',
            }[path],
          }));
        },
      },
    ],
  });
  return import(
    `data:text/javascript;base64,${Buffer.from(bundle.outputFiles[0].text + `\n// ${Math.random()}`).toString('base64')}`
  );
}

async function setup(records, native, extras = {}) {
  const hooks = harness();
  const { useOutboxDispatcher, MAX_SESSION_RESERVES } = await load(
    hooks.react,
    native,
  );
  const outbox = {
    ready: true,
    records,
    getSnapshot() {
      return { records: outbox.records, ready: true };
    },
    put(record) {
      outbox.records = [
        ...outbox.records.filter(
          (item) => item.session.id !== record.session.id,
        ),
        record,
      ];
      hooks.update({ records: outbox.records });
      return Promise.resolve();
    },
    async remove(sessionId) {
      outbox.records = outbox.records.filter(
        (item) => item.session.id !== sessionId,
      );
      hooks.update({ records: outbox.records });
    },
  };
  hooks.start(useOutboxDispatcher, {
    outbox,
    userId: 'u1',
    connected: extras.connected ?? true,
    serverSessions: extras.serverSessions ?? [],
    foregroundSessionId: extras.foregroundSessionId ?? '',
    services: native,
  });
  await tick();
  return { hooks, outbox, MAX_SESSION_RESERVES };
}

test('a waiting send without MessageList is ensured then dispatched', async () => {
  const ensured = [];
  const sent = [];
  const { outbox } = await setup([{ session, send: draft }], {
    async ensureSession(id) {
      ensured.push(id);
    },
    async sendSessionTurn(payload) {
      sent.push(JSON.parse(payload));
      return JSON.stringify({ state: 'accepted' });
    },
    async createSession() {
      throw Error('must not create');
    },
    async releaseReserve() {},
  });
  await tick();
  assert.deepEqual(ensured, ['s1']);
  assert.equal(sent.length, 1);
  assert.equal(sent[0].id, draft.id);
  assert.equal(outbox.records[0].send.phase, 'accepted');
});

test('the foreground session is left to MessageList and does not consume a reserve slot', async () => {
  const ensured = [];
  await setup(
    [{ session, send: draft }],
    {
      async ensureSession(id) {
        ensured.push(id);
      },
      async sendSessionTurn() {
        throw Error('dispatcher must not send the open session');
      },
      async createSession() {
        throw Error('must not create');
      },
      async releaseReserve() {},
    },
    { foregroundSessionId: 's1' },
  );
  await tick();
  assert.deepEqual(ensured, []);
});

test('accepted and failed records release reserve; unknown waits for catalog evidence', async () => {
  const released = [];
  let sends = 0;
  const { outbox, hooks } = await setup(
    [{ session, send: { ...draft, phase: 'accepted' } }],
    {
      async ensureSession() {},
      async sendSessionTurn() {
        sends++;
        return JSON.stringify({ state: 'accepted' });
      },
      async createSession() {
        throw Error('must not create');
      },
      async releaseReserve(id) {
        released.push(id);
      },
    },
  );
  await tick();
  assert.deepEqual(released, ['s1']);
  assert.equal(sends, 0);

  await outbox.put({ session, send: { ...draft, phase: 'failed' } });
  await tick();
  assert.deepEqual(released, ['s1', 's1']);

  await outbox.put({ session, send: { ...draft, phase: 'unknown' } });
  await tick();
  assert.equal(sends, 0);
  assert.equal(outbox.records[0].send.phase, 'unknown');
  hooks.update({
    serverSessions: [{ id: 's1', latestUserMsgId: draft.id }],
  });
  await tick();
  assert.equal(outbox.records.length, 0);
});

test('the ninth background waiting send is not ensured', async () => {
  const { MAX_SESSION_RESERVES } = await load(harness().react, {
    async ensureSession() {},
    async sendSessionTurn() {
      return JSON.stringify({ state: 'accepted' });
    },
    async createSession() {
      throw Error('must not create');
    },
    async releaseReserve() {},
  });
  assert.equal(MAX_SESSION_RESERVES, 8);
  const records = Array.from({ length: MAX_SESSION_RESERVES + 1 }, (_, i) => ({
    session: { ...session, id: `s${i}` },
    send: { ...draft, id: `00000000-0000-0000-0000-00000000000${i}` },
  }));
  const ensured = [];
  const blocked = deferred();
  const { outbox } = await setup(records, {
    async ensureSession(id) {
      ensured.push(id);
    },
    sendSessionTurn: () => blocked.promise,
    async createSession() {
      throw Error('must not create');
    },
    async releaseReserve() {},
  });
  await tick();
  await tick();
  assert.equal(ensured.length, MAX_SESSION_RESERVES);
  assert.ok(!ensured.includes('s8'));
  assert.equal(
    outbox.records.find((item) => item.session.id === 's8')?.send.phase,
    'waiting',
  );
  blocked.resolve(JSON.stringify({ state: 'accepted' }));
});

test('create then first turn still run after the session page is gone', async () => {
  const ensured = [];
  const { outbox } = await setup(
    [{ session, send: { ...draft, creation: '{"sessionId":"s1"}' } }],
    {
      async createSession() {
        return JSON.stringify({ state: 'created', session });
      },
      async ensureSession(id) {
        ensured.push(id);
      },
      async sendSessionTurn() {
        return JSON.stringify({ state: 'accepted' });
      },
      async releaseReserve() {},
    },
  );
  await tick();
  await tick();
  await tick();
  assert.deepEqual(ensured, ['s1']);
  assert.equal(outbox.records[0].send.phase, 'accepted');
  assert.equal(outbox.records[0].send.creation, undefined);
});

test('unmount does not cancel an in-flight sendTurn', async () => {
  const ack = deferred();
  const { hooks, outbox } = await setup([{ session, send: draft }], {
    async ensureSession() {},
    sendSessionTurn: () => ack.promise,
    async createSession() {
      throw Error('must not create');
    },
    async releaseReserve() {},
  });
  await tick();
  hooks.unmount();
  ack.resolve(JSON.stringify({ state: 'accepted' }));
  await tick();
  await tick();
  assert.equal(outbox.records[0].send.phase, 'accepted');
});

test('a background session that cannot open waits and goes again; three failures hand the draft back', async (t) => {
  t.mock.timers.enable({ apis: ['setTimeout'] });
  let ready = false;
  let ensures = 0;
  let sends = 0;
  const released = [];
  const { outbox, hooks } = await setup([{ session, send: draft }], {
    async ensureSession() {
      ensures++;
      if (!ready) throw new Error('runtime_replaced');
    },
    async sendSessionTurn() {
      sends++;
      return JSON.stringify({ state: 'accepted' });
    },
    async createSession() {
      throw new Error('unexpected');
    },
    async releaseReserve(id) {
      released.push(id);
    },
  });
  await tick();
  assert.equal(ensures, 1);
  assert.equal(outbox.records[0].send.phase, 'sending');
  for (const attempts of [2, 3]) {
    t.mock.timers.tick(1500);
    await tick();
    await tick();
    assert.equal(ensures, attempts);
  }
  assert.equal(sends, 0);
  assert.equal(outbox.records[0].send.phase, 'failed');
  assert.equal(outbox.records[0].send.text, draft.text);
  assert.deepEqual(released, ['s1']);
  ready = true;
  await outbox.put({
    session,
    send: { ...outbox.records[0].send, phase: 'waiting' },
  });
  await tick();
  assert.equal(sends, 1);
  assert.equal(outbox.records[0].send.phase, 'accepted');
  hooks.unmount();
});

test('a background send refused before writing goes again by itself and keeps its identity', async (t) => {
  t.mock.timers.enable({ apis: ['setTimeout'] });
  const replies = [
    { state: 'not_sent', reason: 'session_not_ready' },
    { state: 'not_sent', reason: 'starting', retryable: true },
    { state: 'accepted' },
  ];
  const sent = [];
  const { outbox, hooks } = await setup([{ session, send: draft }], {
    async ensureSession() {},
    async sendSessionTurn(payload) {
      sent.push(JSON.parse(payload).id);
      return JSON.stringify(replies[sent.length - 1]);
    },
    async createSession() {
      throw new Error('unexpected');
    },
    async releaseReserve() {},
  });
  await tick();
  for (const attempts of [2, 3]) {
    assert.equal(outbox.records[0].send.phase, 'sending');
    t.mock.timers.tick(1500);
    await tick();
    await tick();
    assert.equal(sent.length, attempts);
  }
  assert.deepEqual(sent, [draft.id, draft.id, draft.id]);
  assert.equal(outbox.records[0].send.phase, 'accepted');
  hooks.unmount();
});

test('a guide submitted on the page keeps its intent when the background dispatcher takes over', async () => {
  const sent = [];
  await setup([{ session, send: { ...draft, guide: true } }], {
    async ensureSession() {},
    async sendSessionTurn(payload) {
      sent.push(JSON.parse(payload));
      return JSON.stringify({ state: 'accepted' });
    },
    async createSession() {
      throw new Error('unexpected');
    },
    async releaseReserve() {},
  });
  await tick();
  assert.equal(sent.length, 1);
  assert.equal(sent[0].guide, true);
  assert.equal(sent[0].queue, false);
});

test('a lost turn result is settled against the hub and never sent again by itself', async (t) => {
  t.mock.timers.enable({ apis: ['setInterval'] });
  const retryId = 'AAAAAAAA-0000-4000-8000-000000000001';
  const asked = [];
  const released = [];
  let verdict = { state: 'pending' };
  let sends = 0;
  const { outbox, hooks } = await setup(
    [{ session, send: { ...draft, phase: 'unknown' } }],
    {
      async ensureSession() {},
      async sendSessionTurn() {
        sends++;
        return JSON.stringify({ state: 'accepted' });
      },
      async createSession() {
        throw Error('must not create');
      },
      async releaseReserve(id) {
        released.push(id);
      },
      async confirmSessionCreation() {
        throw Error('not a creation');
      },
      async confirmSessionTurn(payload) {
        asked.push(JSON.parse(payload));
        return JSON.stringify(verdict);
      },
    },
  );
  await tick();
  assert.deepEqual(asked, [{ sessionId: 's1', id: draft.id }]);
  assert.equal(outbox.records[0].send.phase, 'unknown');

  verdict = { state: 'absent', retryId };
  t.mock.timers.tick(5000);
  await tick();
  await tick();
  assert.equal(asked.length, 2, 'an unsettled result is asked about again');
  assert.equal(outbox.records[0].send.phase, 'failed');
  assert.equal(outbox.records[0].send.id, retryId);
  assert.equal(outbox.records[0].send.text, draft.text);
  assert.deepEqual(released, ['s1']);
  assert.equal(
    sends,
    0,
    'only the user retries a message that was not delivered',
  );
  t.mock.timers.tick(5000);
  await tick();
  assert.equal(asked.length, 2, 'a settled result is not asked about again');

  await outbox.put({ session, send: { ...draft, phase: 'unknown' } });
  verdict = { state: 'uploaded', undispatched: false };
  await tick();
  await tick();
  assert.equal(outbox.records[0].send.phase, 'uploaded');
  assert.equal(outbox.records[0].send.id, draft.id);
  assert.equal(sends, 0);
  hooks.unmount();
});

test('a lost creation result is settled by the catalog replica', async () => {
  const creation = JSON.stringify({ workspaceId: 'w1', sessionId: 's1' });
  const asked = [];
  const sent = [];
  let verdict = { state: 'absent' };
  const { outbox, hooks } = await setup(
    [{ session, send: { ...draft, creation, phase: 'unknown' } }],
    {
      async ensureSession() {},
      async sendSessionTurn(payload) {
        sent.push(JSON.parse(payload));
        return JSON.stringify({ state: 'accepted' });
      },
      async createSession() {
        throw Error('only the user retries a creation');
      },
      async releaseReserve() {},
      async confirmSessionCreation(payload) {
        asked.push(payload);
        return JSON.stringify(verdict);
      },
      async confirmSessionTurn() {
        throw Error('the session does not exist yet');
      },
    },
  );
  await tick();
  await tick();
  assert.deepEqual(asked, [creation]);
  assert.equal(outbox.records[0].send.phase, 'failed');
  assert.equal(outbox.records[0].send.id, draft.id);
  assert.equal(outbox.records[0].send.creation, creation);

  verdict = { state: 'created' };
  await outbox.put({ session, send: { ...draft, creation, phase: 'unknown' } });
  await tick();
  await tick();
  await tick();
  assert.equal(sent.length, 1, 'the first turn follows a confirmed creation');
  assert.equal(sent[0].id, draft.id);
  assert.equal(outbox.records[0].send.creation, undefined);
  assert.equal(outbox.records[0].send.phase, 'accepted');
  hooks.unmount();
});

test('an uploaded turn is asked about until its dispatch pointer is known, then left alone', async (t) => {
  t.mock.timers.enable({ apis: ['setInterval'] });
  const asked = [];
  let verdict = { state: 'pending' };
  const { outbox, hooks } = await setup(
    [{ session, send: { ...draft, phase: 'uploaded' } }],
    {
      async ensureSession() {},
      async sendSessionTurn() {
        throw Error('an uploaded turn is never sent again');
      },
      async createSession() {
        throw Error('must not create');
      },
      async releaseReserve() {},
      async confirmSessionCreation() {
        throw Error('not a creation');
      },
      async confirmSessionTurn(payload) {
        asked.push(JSON.parse(payload).id);
        return JSON.stringify(verdict);
      },
    },
  );
  await tick();
  assert.deepEqual(asked, [draft.id]);
  verdict = { state: 'uploaded', undispatched: true };
  t.mock.timers.tick(5000);
  await tick();
  assert.equal(asked.length, 2);
  t.mock.timers.tick(5000);
  await tick();
  assert.equal(asked.length, 2, 'a published pointer is not asked about again');
  assert.equal(outbox.records[0].send.phase, 'uploaded');
  assert.equal(outbox.records[0].send.id, draft.id);
  hooks.update({ serverSessions: [{ id: 's1', latestUserMsgId: draft.id }] });
  await tick();
  assert.equal(
    outbox.records.length,
    0,
    'the catalog pointer retires the record',
  );
  hooks.unmount();
});
