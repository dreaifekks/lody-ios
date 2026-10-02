// Drives the bundled data runtime against a real Streams hub while the network
// misbehaves: a lost acknowledgement, a dropped connection, a dead route before
// and during a write, and an unpublished dispatch pointer.
//
//   LODY_HUB_URL=http://127.0.0.1:18799 node apps/mobile/verification/lan-hub/reconnect.mjs
//
// Point it at a loopback `loro dev --protocol http1` (create its bucket with
// `PUT /ds/lody` first). It works in a workspace of its own whose streams
// expire, and LODY_HUB_TOKEN is only read from the environment.
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { build } from 'esbuild';
import { Flock } from '@loro-dev/flock-wasm/base64';
import { LoroDoc } from 'loro-crdt/base64';
import { StreamsClient } from '@loro-dev/streams-client';

const base = (process.env.LODY_HUB_URL ?? '').replace(/\/$/, '');
if (!base) throw new Error('Set LODY_HUB_URL to a Streams hub');
const token = process.env.LODY_HUB_TOKEN ?? 'loopback';
const workspace = `lw_verify_${randomUUID().replaceAll('-', '')}`;
const machine = 'verify-machine';
const user = 'local:verify';

// The network between the runtime and the hub. `fault` decides what happens to
// a request: nothing, `hang` (a route that swallows packets), `drop` (a dead
// socket, nothing sent) or `lose` (delivered, acknowledgement lost).
const realFetch = globalThis.fetch;
const requests = [];
const hanging = new Set();
let fault = () => undefined;
globalThis.fetch = async (input, init = {}) => {
  const url = String(input);
  const path = decodeURIComponent(url.split('/ds/lody/')[1] ?? '');
  const request = {
    method: init.method ?? 'GET',
    stream: path.split('?')[0].replace(/\/bootstrap$/, ''),
    bootstrap: path.split('?')[0].endsWith('/bootstrap'),
  };
  request.mode = fault(request);
  requests.push(request);
  if (request.mode === 'hang')
    return new Promise((_, reject) => {
      const fail = (reason) => {
        hanging.delete(fail);
        reject(reason);
      };
      hanging.add(fail);
      init.signal?.addEventListener('abort', () => fail(init.signal.reason));
    });
  if (request.mode === 'drop') throw new TypeError('Load failed');
  if (request.mode === 'lose') {
    await realFetch(input, init);
    throw new TypeError('Load failed');
  }
  return realFetch(input, init);
};
/** What the app does on foreground: every stalled request fails at once. */
const resetConnections = () => {
  for (const fail of [...hanging]) fail(new TypeError('Load failed'));
};

const direct = (stream) =>
  new StreamsClient({
    url: `${base}/ds/lody/${encodeURIComponent(stream)}`,
    auth: async () => token,
    fetch: realFetch,
    retry: { maxAttempts: 1 },
  });
const frame = (bytes) => {
  const framed = new Uint8Array(bytes.length + 4);
  new DataView(framed.buffer).setUint32(0, bytes.length, false);
  framed.set(bytes, 4);
  return framed;
};
const frames = (bytes) => {
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const items = [];
  for (let offset = 0; offset < bytes.length;) {
    const length = view.getUint32(offset, false);
    items.push(bytes.subarray(offset + 4, offset + 4 + length));
    offset += 4 + length;
  }
  return items;
};
const must = (result) => {
  assert.ok(result.ok, JSON.stringify(result.result));
  return result.result;
};
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
async function until(read, ms, what) {
  const deadline = Date.now() + ms;
  for (;;) {
    const value = await read();
    if (value) return value;
    if (Date.now() > deadline) assert.fail(`timed out waiting for ${what}`);
    await sleep(50);
  }
}

// A workspace with one machine and one session per scenario.
const sessions = Object.fromEntries(
  ['plain', 'lost', 'dropped', 'dead', 'stalled', 'pointer'].map((name) => [
    name,
    randomUUID(),
  ]),
);
const seed = new Flock('verify-seed');
seed.set(['e', `machine-${machine}`], true);
seed.set(['m', `machine-${machine}`], { name: 'Verify' });
for (const [name, id] of Object.entries(sessions)) {
  seed.set(['e', `session-${id}`], true);
  seed.set(['m', `session-${id}`], {
    id,
    title: name,
    machineId: machine,
    userId: user,
    createdAt: new Date().toISOString(),
    status: { type: 'idle' },
    isArchived: false,
    cliType: 'builtin',
    agentType: 'claude',
  });
}
seed.commit();
const octets = { contentType: 'application/octet-stream', ttlSeconds: 900 };
must(await direct(`${workspace}:meta`).create(octets));
must(
  await direct(`${workspace}:meta`).append({
    part: {
      contentType: 'application/octet-stream',
      body: frame(new TextEncoder().encode(JSON.stringify(seed.exportJson()))),
    },
  }),
);
must(
  await direct(`${workspace}:rpc:req:${machine}`).create({
    contentType: 'application/json',
    ttlSeconds: 900,
  }),
);
for (const id of Object.values(sessions))
  must(await direct(`${workspace}:s:${id}`).create(octets));

// A machine that acknowledges every dispatch request.
const dispatched = [];
void (async () => {
  const inbox = direct(`${workspace}:rpc:req:${machine}`);
  let offset = '-1';
  for (;;) {
    const read = await inbox.readOnce({ offset, live: 'long-poll' });
    if (!read.ok) {
      await sleep(500);
      continue;
    }
    offset = read.result.nextOffset;
    if (!read.result.payload) continue;
    const parsed = JSON.parse(
      new TextDecoder().decode(read.result.payload.body),
    );
    for (const call of Array.isArray(parsed) ? parsed : [parsed]) {
      dispatched.push(call.params.userTurnId);
      await direct(call.replyTo).append({
        part: {
          contentType: 'application/json',
          body: JSON.stringify({
            jsonrpc: '2.0',
            id: call.id,
            result: { accepted: true },
          }),
        },
      });
    }
  }
})();

async function hubHistory(id) {
  const data = must(await direct(`${workspace}:s:${id}`).bootstrap({}));
  const doc = new LoroDoc();
  let appended = 0;
  for (const part of data.updates)
    for (const update of frames(part.body)) {
      doc.import(update);
      appended++;
    }
  return {
    appended,
    turns: (doc.toJSON().history ?? []).map((entry) => entry.id),
  };
}
/** What another client viewing the session writes when it shows a new turn. */
async function markSeen(id, turnId) {
  const data = must(await direct(`${workspace}:s:${id}`).bootstrap({}));
  const doc = new LoroDoc();
  for (const part of data.updates)
    for (const update of frames(part.body)) doc.import(update);
  const before = doc.version();
  const history = doc.getList('history');
  for (let i = 0; i < history.length; i++) {
    const entry = history.get(i);
    if (entry.get('id') !== turnId) continue;
    entry.set('status', 'seen');
    entry.set('read', true);
  }
  doc.commit();
  must(
    await direct(`${workspace}:s:${id}`).append({
      part: {
        contentType: 'application/octet-stream',
        body: frame(doc.export({ mode: 'update', from: before })),
      },
    }),
  );
}
async function hubPointer(id) {
  const data = must(await direct(`${workspace}:meta`).bootstrap({}));
  const flock = new Flock('verify-reader');
  for (const part of data.updates)
    for (const update of frames(part.body))
      flock.importJson(JSON.parse(new TextDecoder().decode(update)));
  return flock.get(['m', `session-${id}`, 'latestUserMsgId']);
}

// The runtime, as the WebView runs it.
const events = [];
globalThis.location = { origin: base };
globalThis.webkit = {
  messageHandlers: {
    dataRuntime: {
      postMessage(event) {
        events.push(event);
        if (event.type === 'grant')
          queueMicrotask(() =>
            globalThis.dataRuntime.grant({
              token,
              gatewayBaseUrl: base,
              expiresIn: 3600,
            }),
          );
      },
    },
  },
};
const bundle = await build({
  entryPoints: [
    new URL('../../modules/lody-kit/data-runtime/index.ts', import.meta.url)
      .pathname,
  ],
  bundle: true,
  format: 'esm',
  platform: 'browser',
  write: false,
  logLevel: 'silent',
});
await import(
  `data:text/javascript;base64,${Buffer.from(bundle.outputFiles[0].text).toString('base64')}`
);
const runtime = globalThis.dataRuntime;
runtime.start(workspace);
await until(
  () => events.some((event) => event.type === 'synced'),
  20000,
  'the catalog',
);
const turn = (id, text, extra = {}) =>
  runtime.sendTurn({
    sessionId: id,
    machineId: machine,
    userId: user,
    text,
    cliType: 'builtin',
    agentType: 'claude',
    ...extra,
  });
const posts = (stream) =>
  requests.filter(
    (request) => request.method === 'POST' && request.stream === stream,
  ).length;
async function check(name, run) {
  const started = Date.now();
  fault = () => undefined;
  await run(sessions[name], `${workspace}:s:${sessions[name]}`);
  fault = () => undefined;
  console.log(`ok  ${name} (${((Date.now() - started) / 1000).toFixed(1)}s)`);
}

await check('plain', async (id) => {
  await runtime.ensureSession({ sessionId: id });
  const sent = await turn(id, 'plain');
  assert.equal(sent.state, 'accepted');
  assert.deepEqual(await hubHistory(id), { appended: 1, turns: [sent.id] });
  assert.equal(await hubPointer(id), sent.id);
  assert.ok(dispatched.includes(sent.id));
});

await check('lost', async (id, stream) => {
  await runtime.ensureSession({ sessionId: id });
  let lost = false;
  fault = (request) => {
    if (lost || request.method !== 'POST' || request.stream !== stream) return;
    lost = true;
    return 'lose';
  };
  const sent = await turn(id, 'acknowledgement lost');
  assert.equal(sent.state, 'accepted', 'the repeat is acknowledged');
  assert.equal(posts(stream), 2, 'the turn was sent twice');
  assert.deepEqual(
    await hubHistory(id),
    { appended: 1, turns: [sent.id] },
    'the hub kept one copy',
  );
  assert.equal(await hubPointer(id), sent.id);
});

await check('dropped', async (id, stream) => {
  await runtime.ensureSession({ sessionId: id });
  let dropped = false;
  fault = (request) => {
    if (dropped || request.method !== 'POST' || request.stream !== stream)
      return;
    dropped = true;
    return 'drop';
  };
  const sent = await turn(id, 'dead socket');
  assert.equal(sent.state, 'accepted', 'a fresh connection carries the turn');
  assert.deepEqual(await hubHistory(id), { appended: 1, turns: [sent.id] });
});

await check('dead', async (id) => {
  await runtime.ensureSession({ sessionId: id });
  // The tunnel is down: every request disappears.
  fault = () => 'hang';
  await sleep(3500);
  const started = Date.now();
  const refused = await turn(id, 'route is dead');
  assert.deepEqual(
    { state: refused.state, reason: refused.reason },
    { state: 'not_sent', reason: 'session_not_ready' },
  );
  assert.ok(Date.now() - started < 8000, 'the route is judged within seconds');
  assert.deepEqual(
    await hubHistory(id),
    { appended: 0, turns: [] },
    'nothing was written',
  );
  // The tunnel is back and the app returns to the foreground.
  fault = () => undefined;
  resetConnections();
  // What the app does before every send: wait for the replica to be read again.
  await runtime.ensureSession({ sessionId: id });
  const sent = await turn(id, 'route is dead', { id: refused.id });
  assert.equal(sent.state, 'accepted', 'the same message goes by itself');
  assert.deepEqual(await hubHistory(id), { appended: 1, turns: [refused.id] });
  assert.equal(await hubPointer(id), refused.id);
});

await check('stalled', async (id, stream) => {
  await runtime.ensureSession({ sessionId: id });
  // Reads keep answering, so nothing warns the runtime; only the write stalls.
  fault = (request) =>
    request.method === 'POST' && request.stream === stream ? 'hang' : undefined;
  const lost = await turn(id, 'write stalls');
  assert.equal(lost.state, 'unknown');
  fault = () => undefined;
  const verdict = await until(
    async () => {
      const value = await runtime.confirmTurn({ sessionId: id, id: lost.id });
      return value.state === 'pending' ? undefined : value;
    },
    30000,
    'the lost turn to settle',
  );
  assert.equal(verdict.state, 'absent');
  assert.deepEqual(await hubHistory(id), { appended: 0, turns: [] });
  const repeated = await turn(id, 'write stalls', { id: lost.id });
  assert.equal(repeated.reason, 'turn_already_exists');
  const sent = await turn(id, 'write stalls', { id: verdict.retryId });
  assert.equal(sent.state, 'accepted');
  assert.deepEqual(await hubHistory(id), {
    appended: 1,
    turns: [verdict.retryId],
  });
});

await check('pointer', async (id) => {
  await runtime.ensureSession({ sessionId: id });
  fault = (request) =>
    request.method === 'POST' && request.stream === `${workspace}:meta`
      ? 'drop'
      : undefined;
  const sent = await turn(id, 'pointer is lost');
  assert.equal(sent.state, 'uploaded', 'the turn is on the hub, undispatched');
  assert.equal(await hubPointer(id), undefined);
  assert.ok(!dispatched.includes(sent.id));
  // A desktop with the session open marks the turn read; the machine has not seen it.
  await markSeen(id, sent.id);
  await until(
    () =>
      events.some(
        (event) =>
          event.sessionId === id &&
          typeof event.session === 'string' &&
          JSON.parse(event.session).entries?.some(
            (entry) => entry.id === sent.id && entry.status === 'seen',
          ),
      ),
    10000,
    'the replica to see the turn marked read',
  );
  fault = () => undefined;
  assert.deepEqual(await runtime.confirmTurn({ sessionId: id, id: sent.id }), {
    state: 'uploaded',
    undispatched: true,
  });
  assert.equal(
    await hubPointer(id),
    sent.id,
    'the machine can now find the turn',
  );
});

// A catalog read that fails resumes from its cursor.
{
  const stream = `${workspace}:meta`;
  const bootstraps = () =>
    requests.filter((request) => request.bootstrap && request.stream === stream)
      .length;
  const before = bootstraps();
  const errors = events.filter((event) => event.type === 'syncError').length;
  let dropped = false;
  fault = (request) => {
    if (dropped || request.method !== 'GET' || request.stream !== stream)
      return;
    dropped = true;
    return 'drop';
  };
  await until(
    () => events.filter((event) => event.type === 'syncError').length > errors,
    10000,
    'the catalog to notice',
  );
  fault = () => undefined;
  const synced = events.length;
  await until(
    () => events.slice(synced).some((event) => event.type === 'synced'),
    10000,
    'the catalog to recover',
  );
  assert.equal(bootstraps(), before, 'no catalog was downloaded again');
  console.log('ok  catalog resumes from its cursor');
}

console.log('LAN reconnect: all checks passed');
process.exit(0);
