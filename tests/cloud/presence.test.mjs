import assert from 'node:assert/strict';
import test from 'node:test';
import { EphemeralStore } from 'loro-crdt/base64';
import {
  createPresence,
  onlineMachineIds,
  PRESENCE_TTL_MS,
} from '../../packages/cloud-runtime/src/runtime/presence.ts';

const base64 = (bytes) => Buffer.from(bytes).toString('base64');
const heartbeat = (machineId, updatedAt) => {
  const store = new EphemeralStore(PRESENCE_TTL_MS);
  store.set(`machine:${machineId}:instance`, {
    kind: 'machine',
    machineId,
    instanceId: 'instance',
    updatedAt,
  });
  const bytes = store.encodeAll();
  store.destroy();
  return bytes;
};
const sse = (events) =>
  new Response(
    new ReadableStream({
      start(controller) {
        const text = events
          .map(([event, bytes]) => `event: ${event}\ndata:${base64(bytes)}\n\n`)
          .join(': keepalive\n\n');
        // Split mid-event, as a network read would.
        const encoded = new TextEncoder().encode(text);
        controller.enqueue(encoded.slice(0, 20));
        controller.enqueue(encoded.slice(20));
      },
    }),
    {
      headers: {
        'Content-Type': 'text/event-stream',
        'Stream-SSE-Data-Encoding': 'base64',
      },
    },
  );

test('only machines with a fresh heartbeat are online', () => {
  const now = 1_000_000;
  const online = onlineMachineIds(
    {
      a: { kind: 'machine', machineId: 'fresh', updatedAt: now - 30_000 },
      b: { kind: 'machine', machineId: 'stale', updatedAt: now - 91_000 },
      c: { kind: 'session', machineId: 'session', updatedAt: now },
      d: null,
    },
    now,
  );
  assert.deepEqual([...online], ['fresh']);
});

test('the presence channel reports heartbeats from its bootstrap and later data', async () => {
  const now = Date.now();
  const opened = [];
  const presence = createPresence(async (signal) => {
    opened.push(signal);
    return sse([
      ['bootstrap', heartbeat('home', now)],
      ['data', heartbeat('mac', now)],
      ['data', heartbeat('old', now - PRESENCE_TTL_MS - 1)],
    ]);
  });
  try {
    const online = await presence.online();
    assert.ok(online?.has('home'));
    assert.ok(!online?.has('old'));
    await new Promise((resolve) => setTimeout(resolve, 10));
    assert.ok((await presence.online())?.has('mac'));
    assert.equal(opened.length >= 1, true);
  } finally {
    presence.stop();
  }
  assert.ok(
    opened.every((signal) => signal.aborted),
    'stop closes the read',
  );
});

test('a channel that does not open says nothing rather than offline', async () => {
  const presence = createPresence(
    async () => new Response('no', { status: 400 }),
  );
  try {
    assert.equal(await presence.online(), undefined);
  } finally {
    presence.stop();
  }
});

test('LAN availability uses one SSE owner, accepts legacy heartbeat identity and becomes unknown on stop', async (t) => {
  const { build } = await import('esbuild');
  const previousLocation = globalThis.location;
  globalThis.location = { protocol: 'lody-hub:' };
  t.after(() => {
    globalThis.location = previousLocation;
  });
  const requests = [];
  const store = new EphemeralStore(PRESENCE_TTL_MS);
  store.set('legacy', {
    kind: 'machine',
    machineId: 'lan-member',
    updatedAt: Date.now(),
  });
  const bytes = store.encodeAll();
  store.destroy();
  t.mock.method(globalThis, 'fetch', async (url, options) => {
    requests.push({ url, options });
    return sse([['bootstrap', bytes]]);
  });
  const bundle = await build({
    entryPoints: ['packages/cloud-runtime/src/runtime/machine-presence.ts'],
    bundle: true,
    format: 'esm',
    platform: 'browser',
    write: false,
    plugins: [
      {
        name: 'no-cloud-presence',
        setup(b) {
          b.onResolve({ filter: /^@loro-dev\/streams-crdt\/loro$/ }, () => ({
            path: 'offline',
            namespace: 'fixture',
          }));
          b.onLoad({ filter: /.*/, namespace: 'fixture' }, () => ({
            contents:
              'export const EphemeralStoreAdaptor = s => s; export class EphemeralStreamCrdt { constructor() { throw new Error("duplicate Cloud owner"); } }',
          }));
        },
      },
    ],
  });
  const runtime = await import(
    `data:text/javascript;base64,${Buffer.from(bundle.outputFiles[0].text).toString('base64')}`
  );
  const seen = [];
  const ready = Promise.withResolvers();
  const stop = runtime.watchMachinePresence(
    'w',
    async () => ({
      gatewayBaseUrl: 'lody-hub://hub',
      token: 'fixture',
      shardHostSuffix: 'example.invalid',
    }),
    (value) => {
      seen.push(value);
      if (value.state === 'live') ready.resolve();
    },
  );
  t.after(stop);
  await ready.promise;
  assert.deepEqual(seen.at(-1), {
    state: 'live',
    onlineMachineIds: ['lan-member'],
  });
  assert.equal(requests.length, 1);
  assert.equal(
    requests[0].url,
    'lody-hub://hub/ds/lody/w%3Ameta?ephemeral=presence&live=sse',
  );
  stop();
  assert.equal(requests[0].options.signal.aborted, true);
  assert.deepEqual(seen.at(-1), { state: 'unknown', onlineMachineIds: [] });
});
