import assert from 'node:assert/strict';
import test from 'node:test';
import { EphemeralStore } from 'loro-crdt/base64';
import {
  createPresence,
  onlineMachineIds,
  PRESENCE_TTL_MS,
} from '../../modules/lody-kit/data-runtime/presence.ts';

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
