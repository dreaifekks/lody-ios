// Offline integration driver for an explicitly started loopback Streams hub.
// Never start a hub here and never use a real account/token/machine.
//
// LODY_HUB_URL=http://127.0.0.1:18799 node --experimental-strip-types verification/lan-hub/reconnect.mjs
// The caller prepares the loopback lody bucket (PUT /ds/lody) beforehand.
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import {
  Worker,
  isMainThread,
  parentPort,
  workerData,
} from 'node:worker_threads';
import { build } from 'esbuild';
import { Flock } from '@loro-dev/flock-wasm/base64';
import { LoroDoc, LoroMap } from 'loro-crdt/base64';
import { StreamsClient } from '@loro-dev/streams-client';
import { decompress } from 'fzstd';
import {
  runtimeCalls,
  hostCalls,
  runtimeEvents,
} from '../../packages/cloud-runtime/src/contract/methods.ts';
import { Envelope } from '../../packages/cloud-runtime/src/contract/envelope.ts';
import {
  decodeFrames,
  encodeFrame,
} from '../../packages/cloud-runtime/src/frames.ts';

const token = 'loopback';
const workerKind = 'lody-loopback-runtime';

/** Run before bundling, opening a socket, or writing any seed streams. */
export function loopbackHub(raw, suppliedToken) {
  if (suppliedToken !== undefined && suppliedToken !== token)
    throw new Error(
      'LODY_HUB_TOKEN must be absent or the synthetic value loopback',
    );
  if (
    typeof raw !== 'string' ||
    !/^https?:\/\/(?:127\.0\.0\.1|localhost|\[::1\])(?::[0-9]+)?\/?$/i.test(raw)
  )
    throw new Error(
      'LODY_HUB_URL must name only 127.0.0.1, localhost, or [::1], without credentials/path/query',
    );
  const url = new URL(raw);
  return url.origin;
}

export function checkedFetch(base, fetcher, shutdown) {
  const origin = loopbackHub(base);
  return (input, init = {}) => {
    const url = new URL(
      typeof input === 'string' || input instanceof URL ? input : input.url,
    );
    if (
      url.origin !== origin ||
      !(url.pathname === '/ds/lody' || url.pathname.startsWith('/ds/lody/'))
    )
      throw new Error('verification fetch escaped the loopback hub');
    if (url.username || url.password)
      throw new Error('verification fetch included credentials');
    const signals = [shutdown];
    if (input instanceof Request && input.signal) signals.push(input.signal);
    if (init.signal) signals.push(init.signal);
    const signal = AbortSignal.any(signals);
    signal.throwIfAborted();
    // A loopback server may not redirect this driver to a real hub.
    return fetcher(input, { ...init, signal, redirect: 'error' });
  };
}

const sleep = (ms, signal) =>
  new Promise((resolve, reject) => {
    if (signal?.aborted) {
      reject(signal.reason);
      return;
    }
    const done = () => {
      signal?.removeEventListener('abort', abort);
      resolve();
    };
    const timer = setTimeout(done, ms);
    const abort = () => {
      clearTimeout(timer);
      reject(signal.reason);
    };
    signal?.addEventListener('abort', abort, { once: true });
  });
async function until(read, ms, what, signal) {
  const deadline = Date.now() + ms;
  for (;;) {
    signal?.throwIfAborted();
    const result = await read();
    if (result) return result;
    if (Date.now() >= deadline)
      throw new Error(`timed out waiting for ${what}`);
    await sleep(50, signal);
  }
}
const must = (result) => {
  assert.ok(result.ok, JSON.stringify(result.result));
  return result.result;
};

/** Worker-owned instrumentation; close removes every installed listener. */
export function faultFetch(fetcher, report = () => {}) {
  let rules = [];
  const hanging = new Set();
  const reset = () => {
    for (const fail of [...hanging])
      fail(new TypeError('verification connection reset'));
  };
  return {
    setRules(next) {
      rules = next.map((rule) => ({ ...rule }));
    },
    reset,
    close() {
      rules = [];
      reset();
    },
    get pending() {
      return hanging.size;
    },
    async fetch(input, init = {}) {
      const url = new URL(
        typeof input === 'string' || input instanceof URL ? input : input.url,
      );
      const path = decodeURIComponent(url.pathname.split('/ds/lody/')[1] ?? '');
      const request = {
        method:
          init.method ?? (input instanceof Request ? input.method : 'GET'),
        stream: path.replace(/\/bootstrap$/, ''),
        bootstrap: path.endsWith('/bootstrap'),
        offset: url.searchParams.get('offset'),
        cursor: url.searchParams.get('cursor'),
      };
      const rule = rules.find(
        (item) =>
          (item.remaining === undefined || item.remaining > 0) &&
          (!item.method || item.method === request.method) &&
          (!item.stream || item.stream === request.stream),
      );
      if (rule?.remaining !== undefined) --rule.remaining;
      request.mode = rule?.mode;
      report(request);
      if (request.mode === 'drop')
        throw new TypeError('verification socket dropped');
      if (request.mode === 'hang') {
        return new Promise((_, reject) => {
          const signal = init.signal;
          const fail = (reason) => {
            hanging.delete(fail);
            signal?.removeEventListener('abort', abort);
            reject(reason);
          };
          const abort = () => fail(signal.reason);
          if (signal?.aborted) {
            fail(signal.reason);
            return;
          }
          hanging.add(fail);
          signal?.addEventListener('abort', abort, { once: true });
        });
      }
      const response = await fetcher(input, init);
      if (request.mode === 'lose') {
        await response.arrayBuffer();
        throw new TypeError('verification acknowledgement lost');
      }
      return response;
    },
  };
}

export async function runtimeBundle() {
  const result = await build({
    absWorkingDir: fileURLToPath(new URL('../../', import.meta.url)),
    entryPoints: ['packages/cloud-runtime/src/runtime/index.ts'],
    bundle: true,
    format: 'esm',
    platform: 'browser',
    target: 'safari17',
    write: false,
    logLevel: 'silent',
    // Match the production HTML bundle: streams-crdt's root Loro import must
    // share the embedded base64 WASM rather than fetch a relative .wasm file.
    plugins: [
      {
        name: 'bundled-loro-wasm',
        setup(b) {
          b.onResolve({ filter: /^loro-crdt$/ }, () =>
            b.resolve('loro-crdt/base64', {
              resolveDir: fileURLToPath(new URL('../../', import.meta.url)),
              kind: 'import-statement',
            }),
          );
        },
      },
    ],
  });
  return result.outputFiles[0].text;
}

async function runWorker({ base, bundle }) {
  loopbackHub(base);
  const shutdown = new AbortController();
  const originalFetch = globalThis.fetch;
  const originalTimeout = globalThis.setTimeout;
  const originalInterval = globalThis.setInterval;
  const originalClearTimeout = globalThis.clearTimeout;
  const originalClearInterval = globalThis.clearInterval;
  const timeouts = new Set(),
    intervals = new Set();
  let closed = false;
  const network = faultFetch(
    checkedFetch(base, originalFetch, shutdown.signal),
    (request) => parentPort.postMessage({ type: 'request', request }),
  );
  globalThis.fetch = network.fetch;
  globalThis.setTimeout = (callback, ms, ...args) => {
    if (closed) return undefined;
    const timer = originalTimeout(() => {
      timeouts.delete(timer);
      callback(...args);
    }, ms);
    timeouts.add(timer);
    return timer;
  };
  globalThis.setInterval = (callback, ms, ...args) => {
    if (closed) return undefined;
    const timer = originalInterval(callback, ms, ...args);
    intervals.add(timer);
    return timer;
  };
  globalThis.clearTimeout = (timer) => {
    timeouts.delete(timer);
    originalClearTimeout(timer);
  };
  globalThis.clearInterval = (timer) => {
    intervals.delete(timer);
    originalClearInterval(timer);
  };
  const clean = () => {
    if (closed) return;
    closed = true;
    shutdown.abort(new Error('verification shutdown'));
    network.close();
    for (const timer of timeouts) originalClearTimeout(timer);
    for (const timer of intervals) originalClearInterval(timer);
    timeouts.clear();
    intervals.clear();
    globalThis.fetch = originalFetch;
    globalThis.setTimeout = originalTimeout;
    globalThis.setInterval = originalInterval;
    globalThis.clearTimeout = originalClearTimeout;
    globalThis.clearInterval = originalClearInterval;
  };
  const receive = (envelope) =>
    globalThis.dataRuntime.receive(JSON.stringify(envelope));
  globalThis.location = { origin: base, protocol: new URL(base).protocol };
  globalThis.webkit = {
    messageHandlers: {
      dataRuntime: {
        postMessage(event) {
          if (closed) return;
          if (event.type === 'ready') {
            parentPort.postMessage({ type: 'ready' });
            return;
          }
          assert.equal(event.type, 'envelope');
          const message = Envelope.parse(JSON.parse(event.envelope));
          if (message.kind === 'request') {
            if (message.method === 'grant') {
              hostCalls.grant.params.parse(message.payload);
              queueMicrotask(() => {
                if (!closed)
                  receive({
                    ...message,
                    kind: 'result',
                    payload: { token, gatewayBaseUrl: base, expiresIn: 3600 },
                  });
              });
            } else
              receive({
                v: 1,
                gen: message.gen,
                kind: 'error',
                id: message.id,
                method: message.method,
                error: { code: 'unsupported_host_call', retryable: false },
              });
          } else parentPort.postMessage({ type: 'envelope', message });
        },
      },
    },
  };
  const onMessage = (message) => {
    try {
      if (message.type === 'call') receive(message.envelope);
      else if (message.type === 'fault') network.setRules(message.rules);
      else if (message.type === 'reset') network.reset();
      else if (message.type === 'shutdown') {
        clean();
        parentPort.postMessage({
          type: 'control',
          id: message.id,
          result: {
            timeouts: timeouts.size,
            intervals: intervals.size,
            hanging: network.pending,
            fetchRestored: globalThis.fetch === originalFetch,
          },
        });
        parentPort.off('message', onMessage);
        parentPort.close();
        return;
      } else throw new Error('unknown worker control');
      if (message.type !== 'call')
        parentPort.postMessage({ type: 'control', id: message.id });
    } catch (error) {
      parentPort.postMessage({ type: 'fatal', message: error.message });
    }
  };
  parentPort.on('message', onMessage);
  try {
    await import(
      `data:text/javascript;base64,${Buffer.from(bundle).toString('base64')}`
    );
  } catch (error) {
    clean();
    parentPort.off('message', onMessage);
    parentPort.close();
    throw new Error(
      `runtime bundle failed: ${String(error.stack ?? error.message)
        .replace(
          /data:text\/javascript;base64,[A-Za-z0-9+/=]+/g,
          'runtime-bundle',
        )
        .slice(0, 1200)}`,
    );
  }
}

/** Every runtime invocation crosses the versioned, schema-checked channel. */
export async function openRuntime({ base, bundle = undefined }) {
  loopbackHub(base);
  const worker = new Worker(new URL(import.meta.url), {
    workerData: {
      kind: workerKind,
      base,
      bundle: bundle ?? (await runtimeBundle()),
    },
  });
  const events = [],
    requests = [],
    pending = new Map();
  let next = 0,
    disposed = false,
    closing;
  const ready = Promise.withResolvers();
  const settle = (id, error, value) => {
    const call = pending.get(id);
    if (!call) return;
    pending.delete(id);
    clearTimeout(call.timer);
    if (error) call.reject(error);
    else call.resolve(value);
  };
  const fail = (error) => {
    ready.reject(error);
    for (const id of [...pending.keys()]) settle(id, error);
  };
  worker.on('error', fail);
  worker.on('exit', (code) => {
    if (!disposed) fail(new Error(`runtime worker exited (${code})`));
  });
  worker.on('message', (item) => {
    try {
      if (item.type === 'ready') ready.resolve();
      else if (item.type === 'fatal') fail(new Error(item.message));
      else if (item.type === 'request') requests.push(item.request);
      else if (item.type === 'control') settle(item.id, undefined, item.result);
      else if (item.type === 'envelope') {
        const message = Envelope.parse(item.message);
        assert.equal(message.gen, 1);
        if (message.kind !== 'event' && pending.has(message.id))
          assert.equal(message.method, pending.get(message.id).method);
        if (message.kind === 'event') {
          const schema = runtimeEvents[message.method];
          assert.ok(schema, `unknown runtime event ${message.method}`);
          schema.parse(message.payload);
          events.push(message);
        } else if (message.kind === 'error')
          settle(message.id, new Error(message.error.code));
        else {
          const spec = runtimeCalls[message.method];
          assert.ok(spec, `unknown runtime result ${message.method}`);
          settle(message.id, undefined, spec.result.parse(message.payload));
        }
      }
    } catch (error) {
      fail(error);
    }
  });
  const request = (message, timeout = 10000) => {
    if (disposed) return Promise.reject(new Error('runtime closed'));
    const id = `verify-${++next}`;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(
        () => settle(id, new Error(`runtime ${message.type} timed out`)),
        timeout,
      );
      pending.set(id, { resolve, reject, timer });
      if (message.type === 'call') {
        message.envelope.id = id;
        pending.get(id).method = message.envelope.method;
      }
      worker.postMessage({ ...message, id });
    });
  };
  const call = (method, payload = {}) => {
    const spec = runtimeCalls[method];
    assert.ok(spec, `unknown runtime method ${method}`);
    const params = spec.params.parse(payload);
    return request(
      {
        type: 'call',
        envelope: { v: 1, gen: 1, kind: 'request', method, payload: params },
      },
      spec.timeoutMs + 10000,
    );
  };
  const close = () => {
    closing ??= dispose();
    return closing;
  };
  const dispose = async () => {
    if (disposed) return;
    let cleanup;
    try {
      cleanup = await request({ type: 'shutdown' }, 3000);
    } finally {
      disposed = true;
      fail(new Error('runtime closed'));
      await worker.terminate();
    }
    return cleanup;
  };
  try {
    let timer;
    try {
      await Promise.race([
        ready.promise,
        new Promise((_, reject) => {
          timer = setTimeout(
            () => reject(new Error('runtime startup timed out')),
            10000,
          );
        }),
      ]);
    } finally {
      clearTimeout(timer);
    }
    await call('hello', { protocol: 1, gen: 1 });
  } catch (error) {
    await close().catch(() => {});
    throw error;
  }
  return {
    call,
    events,
    requests,
    fault: (rules) => request({ type: 'fault', rules }),
    reset: () => request({ type: 'reset' }),
    close,
  };
}

/** A handled setup turn binds MCP selection without creating a pending send. */
export function reconnectHistory(sessionId, userId, mcpServerIds = []) {
  const doc = new LoroDoc();
  const setup = doc.getList('history').pushContainer(new LoroMap());
  const fields = {
    id: `verify-setup-${sessionId}`,
    role: 'user',
    userId,
    status: 'handled',
    finished: true,
    items: [],
    inputConfig: { cliType: 'builtin', agentType: 'claude', mcpServerIds },
  };
  for (const [key, value] of Object.entries(fields)) setup.set(key, value);
  doc.commit();
  return doc;
}

export async function main(env = process.env) {
  // This guard must precede seed creation or any network activity.
  const base = loopbackHub(env.LODY_HUB_URL, env.LODY_HUB_TOKEN);
  const shutdown = new AbortController();
  const fetcher = checkedFetch(base, globalThis.fetch, shutdown.signal);
  const workspace = `lw_verify_${randomUUID().replaceAll('-', '')}`;
  const machine = 'verify-machine',
    quiet = 'verify-quiet',
    user = 'local:verify';
  const direct = (stream) =>
    new StreamsClient({
      url: `${base}/ds/lody/${encodeURIComponent(stream)}`,
      auth: async () => token,
      fetch: fetcher,
      retry: { maxAttempts: 1 },
      timeout: { connectTimeoutMs: 5000, pollTimeoutMs: 10000 },
    });
  const sessions = Object.fromEntries(
    [
      'plain',
      'lost',
      'dropped',
      'dead',
      'mcp-network',
      'stalled',
      'pointer',
      'pointer-ack',
    ].map((name) => [name, randomUUID()]),
  );
  let runtime, responder, responderError;
  const stopRuntime = () => {
    void runtime?.close().catch(() => {});
  };
  shutdown.signal.addEventListener('abort', stopRuntime, { once: true });
  const dispatched = [];
  // Bound an unattended run; finally still owns all cancellation and teardown.
  const deadline = setTimeout(
    () => shutdown.abort(new Error('verification exceeded 5 minutes')),
    300000,
  );
  try {
    const bundle = await runtimeBundle();
    const seed = new Flock('verify-seed');
    for (const id of [machine, quiet]) {
      seed.set(['e', `machine-${id}`], true);
      seed.set(['m', `machine-${id}`], {
        name: id === machine ? 'Verify' : 'Quiet',
        os: 'linux',
      });
    }
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
          contentType: octets.contentType,
          body: encodeFrame(
            new TextEncoder().encode(JSON.stringify(seed.exportJson())),
          ),
        },
      }),
    );
    for (const id of [machine, quiet])
      must(
        await direct(`${workspace}:rpc:req:${id}`).create({
          contentType: 'application/json',
          ttlSeconds: 900,
        }),
      );
    for (const [name, id] of Object.entries(sessions)) {
      const client = direct(`${workspace}:s:${id}`);
      must(await client.create(octets));
      // All transport scenarios explicitly disable MCP. A separate case keeps
      // a configured selection to exercise pre-write directory failures.
      const selection = name === 'mcp-network' ? ['verify-mcp'] : [];
      const doc = reconnectHistory(id, user, selection);
      must(
        await client.append({
          part: {
            contentType: octets.contentType,
            body: encodeFrame(doc.export({ mode: 'update' })),
          },
        }),
      );
    }
    const mcp = new Flock('verify-mcp-catalog');
    mcp.set(['mcpServer', 'verify-mcp'], {
      id: 'verify-mcp',
      name: 'Synthetic MCP',
      transport: 'http',
      enabledByDefault: false,
      connection: { transport: 'http', url: `${base}/unused-synthetic-mcp` },
    });
    mcp.commit();
    const workspaceSettings = `${workspace}:wf:workspace`;
    must(await direct(workspaceSettings).create(octets));
    must(
      await direct(workspaceSettings).append({
        part: {
          contentType: octets.contentType,
          body: encodeFrame(
            new TextEncoder().encode(JSON.stringify(mcp.exportJson())),
          ),
        },
      }),
    );

    responder = (async () => {
      const inbox = direct(`${workspace}:rpc:req:${machine}`);
      let offset = '-1';
      while (!shutdown.signal.aborted) {
        const read = await inbox.readOnce({
          offset,
          live: 'long-poll',
          signal: shutdown.signal,
        });
        if (!read.ok) {
          await sleep(200, shutdown.signal);
          continue;
        }
        offset = read.result.nextOffset;
        if (!read.result.payload) continue;
        const parsed = JSON.parse(
          new TextDecoder().decode(read.result.payload.body),
        );
        for (const request of Array.isArray(parsed) ? parsed : [parsed]) {
          assert.equal(request.workspaceId, workspace);
          assert.equal(request.machineId, machine);
          assert.ok(
            request.replyTo.startsWith(`${workspace}:rpc:res:${machine}:`),
          );
          assert.ok(
            ['machine/ping', 'session/dispatch-turn'].includes(request.method),
          );
          const ping = request.method === 'machine/ping';
          if (!ping) dispatched.push(request.params.userTurnId);
          must(
            await direct(request.replyTo).append({
              part: {
                contentType: 'application/json',
                body: JSON.stringify({
                  jsonrpc: '2.0',
                  id: request.id,
                  result: ping
                    ? { type: 'machine/ping_response', success: true }
                    : { accepted: true },
                }),
              },
            }),
          );
        }
      }
    })();
    // Observe a responder failure immediately, even before final teardown awaits it.
    void responder.catch((error) => {
      if (!shutdown.signal.aborted) {
        responderError = error;
        shutdown.abort(error);
      }
    });

    async function replica(stream, make, snapshot, update) {
      const client = direct(stream),
        doc = make();
      const data = must(await client.bootstrap({ signal: shutdown.signal }));
      if (data.snapshotOffset !== '-1' && data.snapshot) {
        let bytes = data.snapshot.body;
        if (
          bytes[0] === 0x28 &&
          bytes[1] === 0xb5 &&
          bytes[2] === 0x2f &&
          bytes[3] === 0xfd
        )
          bytes = decompress(bytes);
        snapshot(doc, bytes);
      }
      let appended = 0;
      const consume = (body) => {
        for (const bytes of decodeFrames(body)) {
          update(doc, bytes);
          ++appended;
        }
      };
      for (const part of data.updates) consume(part.body);
      let tail = data;
      while (!tail.upToDate) {
        tail = must(
          await client.readOnce({
            offset: tail.nextOffset,
            cursor: tail.cursor,
            signal: shutdown.signal,
          }),
        );
        if (tail.payload) consume(tail.payload.body);
      }
      return { doc, appended };
    }
    const history = (id) =>
      replica(
        `${workspace}:s:${id}`,
        () => new LoroDoc(),
        (doc, bytes) => doc.import(bytes),
        (doc, bytes) => doc.import(bytes),
      );
    const catalog = () =>
      replica(
        `${workspace}:meta`,
        () => new Flock(`reader-${randomUUID()}`),
        (doc, bytes) => doc.importFile(bytes),
        (doc, bytes) =>
          doc.importJson(JSON.parse(new TextDecoder().decode(bytes))),
      );
    const hubHistory = async (id) => {
      const { doc, appended } = await history(id);
      const rows = doc.toJSON().history ?? [];
      const setup = rows.filter((entry) => entry.id === `verify-setup-${id}`);
      assert.equal(
        setup.length,
        1,
        'the explicit MCP setup turn remains intact',
      );
      assert.deepEqual(
        setup[0].inputConfig.mcpServerIds,
        id === sessions['mcp-network'] ? ['verify-mcp'] : [],
      );
      return {
        // One framed update was intentionally seeded before the runtime opened.
        appended: appended - 1,
        turns: rows
          .filter((entry) => entry.id !== `verify-setup-${id}`)
          .map((entry) => entry.id),
      };
    };
    const pointer = async (id) =>
      (await catalog()).doc.get(['m', `session-${id}`, 'latestUserMsgId']);
    const markSeen = async (id, turnId) => {
      const { doc } = await history(id),
        before = doc.version(),
        rows = doc.getList('history');
      for (let i = 0; i < rows.length; ++i) {
        const entry = rows.get(i);
        if (entry.get('id') === turnId) {
          entry.set('status', 'seen');
          entry.set('read', true);
        }
      }
      doc.commit();
      must(
        await direct(`${workspace}:s:${id}`).append({
          part: {
            contentType: octets.contentType,
            body: encodeFrame(doc.export({ mode: 'update', from: before })),
          },
        }),
      );
    };
    runtime = await openRuntime({ base, bundle });
    shutdown.signal.throwIfAborted();
    await runtime.call('start', {
      workspaceId: workspace,
      userId: user,
      active: false,
    });
    await until(
      () => runtime.events.some((event) => event.method === 'synced'),
      20000,
      'catalog',
      shutdown.signal,
    );
    const turn = (id, text, extra = {}) =>
      runtime.call('sendTurn', {
        sessionId: id,
        machineId: machine,
        userId: user,
        text,
        cliType: 'builtin',
        agentType: 'claude',
        billingEntitlement: null,
        ...extra,
      });
    const confirm = (id, turnId) =>
      runtime.call('confirmSessionTurn', { sessionId: id, id: turnId });
    const settled = (id, turnId) =>
      until(
        async () => {
          const value = await confirm(id, turnId);
          return ['pending', 'not_ready'].includes(value.state)
            ? undefined
            : value;
        },
        30000,
        'turn confirmation',
        shutdown.signal,
      );
    const posts = (stream) =>
      runtime.requests.filter(
        (request) => request.method === 'POST' && request.stream === stream,
      ).length;
    const check = async (name, run) => {
      const started = Date.now(),
        id = sessions[name];
      await runtime.fault([]);
      try {
        await run(id, `${workspace}:s:${id}`);
      } finally {
        await runtime.fault([]);
        await runtime.reset();
      }
      console.log(
        `ok  ${name} (${((Date.now() - started) / 1000).toFixed(1)}s)`,
      );
    };
    await check('plain', async (id) => {
      await runtime.call('ensureSession', { sessionId: id });
      const sent = await turn(id, 'plain');
      assert.equal(sent.state, 'accepted');
      assert.deepEqual(await hubHistory(id), { appended: 1, turns: [sent.id] });
      assert.equal(await pointer(id), sent.id);
      assert.ok(dispatched.includes(sent.id));
    });
    for (const [name, mode] of [
      ['lost', 'lose'],
      ['dropped', 'drop'],
    ])
      await check(name, async (id, stream) => {
        await runtime.call('ensureSession', { sessionId: id });
        await runtime.fault([{ method: 'POST', stream, mode, remaining: 1 }]);
        const sent = await turn(id, name);
        assert.equal(sent.state, 'accepted');
        assert.deepEqual(await hubHistory(id), {
          appended: 1,
          turns: [sent.id],
        });
        assert.equal(await pointer(id), sent.id);
        if (mode === 'lose')
          assert.equal(
            posts(stream),
            2,
            'producer tuple deduplicates the repeated append',
          );
      });
    await check('dead', async (id, stream) => {
      await runtime.call('ensureSession', { sessionId: id });
      const start = runtime.requests.length;
      await runtime.fault([{ stream, mode: 'hang' }]);
      // Wait for an owned long-poll to enter the dead route. A previous healthy
      // poll may still finish after fault installation; it must not freshen the
      // replica just before send and accidentally turn this into a write test.
      await until(
        () =>
          runtime.requests
            .slice(start)
            .some(
              (request) =>
                request.stream === stream &&
                request.method === 'GET' &&
                !request.bootstrap &&
                request.mode === 'hang',
            ),
        40000,
        'dead session poll',
        shutdown.signal,
      );
      await sleep(3500, shutdown.signal);
      const started = Date.now(),
        refused = await turn(id, 'route is dead');
      assert.deepEqual(
        { state: refused.state, reason: refused.reason },
        { state: 'not_sent', reason: 'session_not_ready' },
      );
      assert.ok(Date.now() - started < 8000);
      const attempts = runtime.requests.slice(start);
      assert.ok(
        attempts.some(
          (request) =>
            request.stream === stream &&
            request.method === 'HEAD' &&
            request.mode === 'hang',
        ),
        'freshness must actually probe HEAD',
      );
      assert.ok(
        !attempts.some((request) => request.stream === workspaceSettings),
        'explicit [] must bypass the MCP catalog',
      );
      assert.ok(
        !attempts.some((request) => request.method === 'POST'),
        'the dead-route refusal happens before any write',
      );
      assert.deepEqual(await hubHistory(id), { appended: 0, turns: [] });
      await runtime.fault([]);
      await runtime.reset();
      await runtime.call('ensureSession', { sessionId: id });
      const sent = await turn(id, 'route is back', { id: refused.id });
      assert.equal(sent.state, 'accepted');
      assert.deepEqual(await hubHistory(id), {
        appended: 1,
        turns: [refused.id],
      });
    });
    await check('mcp-network', async (id, stream) => {
      await runtime.call('ensureSession', { sessionId: id });
      const start = runtime.requests.length;
      await runtime.fault([
        { method: 'GET', stream: workspaceSettings, mode: 'drop' },
      ]);
      const refused = await turn(id, 'MCP directory route is down');
      assert.equal(refused.state, 'not_sent');
      assert.equal(refused.reason, 'mcp_catalog_unavailable');
      assert.equal(refused.retryable, true);
      assert.ok(
        runtime.requests
          .slice(start)
          .some(
            (request) =>
              request.stream === workspaceSettings && request.mode === 'drop',
          ),
      );
      assert.ok(
        !runtime.requests
          .slice(start)
          .some((request) => request.method === 'POST'),
        'MCP preparation failure writes no receipt, turn, pointer or RPC',
      );
      assert.deepEqual(await hubHistory(id), { appended: 0, turns: [] });
      await runtime.fault([]);
      assert.equal(
        (await turn(id, 'MCP directory recovered', { id: refused.id })).state,
        'accepted',
        'a provably pre-write failure may reuse its ID',
      );
      assert.deepEqual(await hubHistory(id), {
        appended: 1,
        turns: [refused.id],
      });
      assert.equal(posts(stream), 1);
    });
    await check('stalled', async (id, stream) => {
      await runtime.call('ensureSession', { sessionId: id });
      await runtime.fault([{ method: 'POST', stream, mode: 'hang' }]);
      const sending = turn(id, 'write stalls');
      // Foreground connection reset interrupts the stalled write; keep its route dead
      // until the send attempt has ended, so the verifier never replays the old ID.
      await until(
        () =>
          runtime.requests.some(
            (request) => request.stream === stream && request.mode === 'hang',
          ),
        5000,
        'stalled append',
        shutdown.signal,
      );
      await runtime.fault([{ method: 'POST', stream, mode: 'drop' }]);
      await runtime.reset();
      const lost = await sending;
      assert.equal(lost.state, 'unknown');
      await runtime.fault([]);
      await runtime.reset();
      const verdict = await settled(id, lost.id);
      assert.equal(verdict.state, 'absent');
      assert.ok(verdict.retryId && verdict.retryId !== lost.id);
      assert.deepEqual(await hubHistory(id), { appended: 0, turns: [] });
      assert.equal(
        (await turn(id, 'write stalls', { id: lost.id })).reason,
        'turn_already_exists',
      );
      assert.equal(
        (await turn(id, 'retry with a fresh id', { id: verdict.retryId }))
          .state,
        'accepted',
      );
      assert.deepEqual(await hubHistory(id), {
        appended: 1,
        turns: [verdict.retryId],
      });
    });
    await check('pointer', async (id) => {
      await runtime.call('ensureSession', { sessionId: id });
      await runtime.fault([
        { method: 'POST', stream: `${workspace}:meta`, mode: 'drop' },
      ]);
      const sent = await turn(id, 'pointer never reached the hub');
      assert.equal(sent.state, 'uploaded');
      assert.equal(await pointer(id), undefined);
      assert.ok(!dispatched.includes(sent.id));
      await markSeen(id, sent.id);
      await until(
        () =>
          runtime.events.some(
            (event) =>
              ['session', 'sessionCache'].includes(event.method) &&
              event.payload.sessionId === id &&
              event.payload.session &&
              JSON.parse(event.payload.session).entries.some(
                (entry) => entry.id === sent.id && entry.status === 'seen',
              ),
          ),
        10000,
        'seen turn',
        shutdown.signal,
      );
      await runtime.fault([]);
      assert.deepEqual(await confirm(id, sent.id), {
        state: 'seen',
        delivery: 'uploaded',
      });
      assert.equal(await pointer(id), sent.id);
      assert.ok(
        !dispatched.includes(sent.id),
        'confirmation repairs the pointer without replaying a dispatch RPC',
      );
    });
    await check('pointer-ack', async (id) => {
      await runtime.call('ensureSession', { sessionId: id });
      await runtime.fault([
        { method: 'POST', stream: `${workspace}:meta`, mode: 'lose' },
      ]);
      const sent = await turn(id, 'pointer committed but all ACKs lost');
      assert.equal(sent.state, 'uploaded');
      assert.equal(await pointer(id), sent.id);
      assert.ok(!dispatched.includes(sent.id));
      await runtime.fault([]);
      await runtime.reset();
      assert.deepEqual(await settled(id, sent.id), {
        state: 'seen',
        delivery: 'uploaded',
      });
      assert.equal(await pointer(id), sent.id);
    });
    {
      const stream = `${workspace}:meta`;
      const count = () =>
        runtime.requests.filter(
          (request) => request.stream === stream && request.bootstrap,
        ).length;
      const before = count(),
        errors = runtime.events.filter(
          (event) => event.method === 'syncError',
        ).length;
      const start = runtime.requests.length;
      await runtime.fault([
        { method: 'GET', stream, mode: 'drop', remaining: 1 },
      ]);
      await runtime.reset();
      await until(
        () =>
          runtime.requests
            .slice(start)
            .some(
              (request) => request.stream === stream && request.mode === 'drop',
            ),
        40000,
        'catalog dropped poll',
        shutdown.signal,
      );
      await runtime.fault([]);
      const resumed = runtime.events.length;
      // Wake the retry's long poll with a harmless marker in this synthetic workspace.
      const marker = (await catalog()).doc,
        version = marker.version();
      marker.set(['verification', 'reconnect'], Date.now());
      marker.commit();
      must(
        await direct(stream).append({
          part: {
            contentType: octets.contentType,
            body: encodeFrame(
              new TextEncoder().encode(
                JSON.stringify(marker.exportJson(version)),
              ),
            ),
          },
        }),
      );
      await until(
        () =>
          runtime.events
            .slice(resumed)
            .some((event) => event.method === 'synced'),
        10000,
        'catalog recovery',
        shutdown.signal,
      );
      assert.equal(count(), before, 'the catalog keeps its replica/cursor');
      assert.equal(
        runtime.events.filter((event) => event.method === 'syncError').length,
        errors,
        'one dropped read stays inside STALL_GRACE',
      );
      console.log('ok  catalog cursor and grace');
    }
    {
      const status = (args) =>
        runtime.call('machineStatus', { workspaceId: workspace, ...args });
      const { machines } = await status({ action: 'list' });
      assert.deepEqual(
        machines.map((item) => item.id).sort(),
        [machine, quiet].sort(),
      );
      assert.ok(
        machines.every((item) => item.online === undefined),
        'no heartbeat/presence is fabricated by this harness',
      );
      const { ms } = await status({ action: 'ping', machineId: machine });
      assert.ok(ms >= 0 && ms < 5000);
      const started = Date.now();
      await assert.rejects(status({ action: 'ping', machineId: quiet }));
      assert.ok(Date.now() - started < 9000);
      await assert.rejects(
        status({ action: 'ping', machineId: 'missing' }),
        /machine_unavailable/,
      );
      console.log('ok  machine status and ping');
    }
    shutdown.signal.throwIfAborted();
  } finally {
    clearTimeout(deadline);
    shutdown.abort(new Error('verification complete'));
    try {
      if (runtime) {
        const cleanup = await runtime.close();
        assert.deepEqual(cleanup, {
          timeouts: 0,
          intervals: 0,
          hanging: 0,
          fetchRestored: true,
        });
      }
    } finally {
      await responder?.catch(() => {});
      shutdown.signal.removeEventListener('abort', stopRuntime);
    }
  }
  if (responderError) throw responderError;
  console.log(
    'LAN reconnect: all loopback checks passed; owned resources released',
  );
}

if (!isMainThread && workerData?.kind === workerKind)
  await runWorker(workerData);
else if (
  isMainThread &&
  process.argv[1] &&
  import.meta.url === pathToFileURL(resolve(process.argv[1])).href
) {
  try {
    await main();
  } catch (error) {
    console.error(
      `LAN reconnect failed: ${String(error.message).slice(0, 500)}`,
    );
    process.exitCode = 1;
  }
}
