import assert from 'node:assert/strict';
import test from 'node:test';
import { spawn } from 'node:child_process';
import {
  checkedFetch,
  faultFetch,
  loopbackHub,
  openRuntime,
  runtimeBundle,
  reconnectHistory,
} from '../../verification/lan-hub/reconnect.mjs';

const command = new URL(
  '../../verification/lan-hub/reconnect.mjs',
  import.meta.url,
);

test('loopback guard rejects real hubs, credential URLs, paths, alternate hosts and real tokens before networking', async () => {
  for (const input of [
    undefined,
    '',
    'https://example.com',
    'http://192.168.1.1:18799',
    'http://127.0.0.2',
    'http://127.0.0.1.example.com',
    'http://user:secret@127.0.0.1',
    'http://127.0.0.1/ds',
    'http://localhost?hub=real',
    'http://localhost#fragment',
    'http://2130706433',
    'http://0x7f000001',
    'file://localhost',
    'http://[::ffff:127.0.0.1]',
  ])
    assert.throws(() => loopbackHub(input), /LODY_HUB_URL/);
  assert.throws(
    () => loopbackHub('http://127.0.0.1:18799', 'credential'),
    /LODY_HUB_TOKEN/,
  );
  for (const input of [
    'http://127.0.0.1:18799/',
    'https://localhost:18799',
    'http://[::1]:18799',
  ])
    assert.equal(loopbackHub(input, 'loopback'), new URL(input).origin);
  let calls = 0;
  const signal = new AbortController();
  const fetcher = checkedFetch(
    'http://127.0.0.1:18799',
    async (_input, options) => {
      ++calls;
      assert.equal(options.redirect, 'error');
      return new Response();
    },
    signal.signal,
  );
  assert.throws(() => fetcher('https://example.com/ds/lody'), /escaped/);
  await fetcher('http://127.0.0.1:18799/ds/lody');
  assert.equal(calls, 1);
});

test('CLI refuses a non-loopback hub with a bounded nonzero exit and no token disclosure', async () => {
  const child = spawn(
    process.execPath,
    ['--experimental-strip-types', command.pathname],
    {
      env: {
        ...process.env,
        LODY_HUB_URL: 'https://example.invalid',
        LODY_HUB_TOKEN: 'private-fixture-value',
      },
      stdio: ['ignore', 'pipe', 'pipe'],
    },
  );
  let output = '';
  for (const stream of [child.stdout, child.stderr])
    stream.on('data', (bytes) => {
      output += bytes;
    });
  const exit = await new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      child.kill();
      reject(new Error('guard did not exit'));
    }, 5000);
    child.on('error', (error) => {
      clearTimeout(timer);
      reject(error);
    });
    child.on('exit', (code) => {
      clearTimeout(timer);
      resolve(code);
    });
  });
  assert.equal(exit, 1);
  assert.match(output, /LODY_HUB_TOKEN/);
  assert.ok(!output.includes('private-fixture-value'));
});

test('fault injection consumes one lost ACK and reset/abort release every hanging fetch', async () => {
  let delivered = 0;
  const network = faultFetch(async () => {
    ++delivered;
    return new Response('delivered');
  });
  network.setRules([{ method: 'POST', mode: 'lose', remaining: 1 }]);
  await assert.rejects(
    network.fetch('http://127.0.0.1/ds/lody/test', { method: 'POST' }),
    /acknowledgement lost/,
  );
  await network.fetch('http://127.0.0.1/ds/lody/test', { method: 'POST' });
  assert.equal(delivered, 2);
  network.setRules([{ mode: 'hang' }]);
  const abort = new AbortController();
  const first = network.fetch('http://127.0.0.1/ds/lody/test', {
    signal: abort.signal,
  });
  const second = network.fetch('http://127.0.0.1/ds/lody/test');
  const results = Promise.allSettled([first, second]);
  assert.equal(network.pending, 2);
  abort.abort(new Error('fixture cancellation'));
  network.reset();
  assert.ok((await results).every((item) => item.status === 'rejected'));
  network.close();
  assert.equal(network.pending, 0);
  const already = new AbortController();
  already.abort();
  network.setRules([{ mode: 'hang' }]);
  await assert.rejects(
    network.fetch('http://127.0.0.1/ds/lody/test', { signal: already.signal }),
  );
  assert.equal(network.pending, 0);
});

test('production bundle speaks typed hello and worker teardown leaves no owned fetch or timer', async () => {
  const original = globalThis.fetch;
  // No start call means no streams/presence are opened; this test has no hub.
  const runtime = await openRuntime({
    base: 'http://127.0.0.1:18799',
    bundle: await runtimeBundle(),
  });
  try {
    const hello = await runtime.call('hello', { protocol: 1, gen: 1 });
    assert.ok(hello.methods.includes('confirmSessionTurn'));
    assert.ok(hello.methods.includes('confirmSessionCreation'));
    assert.deepEqual(
      await runtime.call('confirmSessionTurn', {
        sessionId: 'fixture',
        id: 'fixture',
      }),
      { state: 'not_ready' },
    );
    assert.equal(runtime.requests.length, 0);
    assert.throws(() => runtime.call('sendTurn', {}));
    const cleanup = await runtime.close();
    assert.deepEqual(cleanup, {
      timeouts: 0,
      intervals: 0,
      hanging: 0,
      fetchRestored: true,
    });
    assert.equal(globalThis.fetch, original);
    await assert.rejects(runtime.call('ping'), /runtime closed/);
  } finally {
    await runtime.close();
  }
});

test('worker close clears runtime-owned intervals and pending typed calls', async () => {
  const fixture = `
    setInterval(() => {}, 60000);
    globalThis.dataRuntime = { receive(raw) {
      const request = JSON.parse(raw);
      if (request.method === 'hello') globalThis.webkit.messageHandlers.dataRuntime.postMessage({ type: 'envelope', envelope: JSON.stringify({ ...request, kind: 'result', payload: { protocol: 1, methods: ['hello', 'ping'] } }) });
    } };
    globalThis.webkit.messageHandlers.dataRuntime.postMessage({ type: 'ready' });
  `;
  const runtime = await openRuntime({
    base: 'http://localhost:18799',
    bundle: fixture,
  });
  const pending = assert.rejects(runtime.call('ping'), /runtime closed/);
  const [cleanup, again] = await Promise.all([
    runtime.close(),
    runtime.close(),
  ]);
  assert.deepEqual(cleanup, again);
  await pending;
  assert.deepEqual(cleanup, {
    timeouts: 0,
    intervals: 0,
    hanging: 0,
    fetchRestored: true,
  });
});

test(
  'a failing bundle still terminates its worker and clears its installed interval',
  { timeout: 5000 },
  async () => {
    await assert.rejects(
      openRuntime({
        base: 'http://127.0.0.1:18799',
        bundle:
          'setInterval(() => {}, 60000); throw new Error("synthetic startup failure");',
      }),
      /synthetic startup failure/,
    );
  },
);

test('every transport scenario can seed a handled MCP-disabled map without a pending turn or receipt', () => {
  const fixture = reconnectHistory('session', 'local:verify');
  const raw = fixture.toJSON();
  assert.equal(raw.history.length, 1);
  assert.deepEqual(raw.history[0].inputConfig.mcpServerIds, []);
  assert.equal(raw.history[0].status, 'handled');
  assert.equal(raw.history[0].finished, true);
  assert.equal(
    typeof fixture.getList('history').get(0).get,
    'function',
    'markSeen must be able to inspect the setup row',
  );
  assert.equal(raw.humanInputReceipts, undefined);
  assert.deepEqual(
    reconnectHistory('mcp', 'local:verify', ['verify-mcp']).toJSON().history[0]
      .inputConfig.mcpServerIds,
    ['verify-mcp'],
  );
});
