import assert from 'node:assert/strict';
import { readFile, mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { buildDataRuntime } from '../../../../packages/cloud-runtime/scripts/build.mjs';
import test from 'node:test';
import { build } from 'esbuild';
import { Flock } from '@loro-dev/flock-wasm/base64';
import { runtimeCalls } from '../../../../packages/cloud-runtime/src/contract/methods.ts';
import v8 from 'node:v8';
import vm from 'node:vm';

v8.setFlagsFromString('--expose-gc');

test('persistent runtime applies live increments to the existing replica and advances the cursor', async () => {
  const previousBroadcastChannel = globalThis.BroadcastChannel;
  globalThis.BroadcastChannel = undefined;
  const previousFetch = globalThis.fetch;
  // The runtime calibrates its server clock on start; no test reaches the network.
  globalThis.fetch = async () => {
    throw new Error('network_disabled');
  };
  const flock = new Flock('synthetic');
  flock.set(['e', 'session-s1'], true, 1);
  flock.set(['e', 'machine-m1'], true, 1);
  flock.set(
    ['m', 'machine-m1'],
    {
      name: 'Synthetic Mac',
      localProjects: { p1: { name: 'app', rootPath: '/a' } },
      protocolCapabilities: { sessionDirectoryListing: 1 },
    },
    1,
  );
  flock.set(['m', 'session-s1'], { title: 'Before', machineId: 'm1' }, 2);
  const snapshot = flock.exportFile(),
    version = flock.version();
  const machineFlock = new Flock('machine');
  machineFlock.importFile(snapshot);
  machineFlock.set(
    ['localProject', 'p2'],
    { name: 'Machine only', rootPath: '/b' },
    3,
  );
  const machineSnapshot = machineFlock.exportFile();
  flock.set(['m', 'session-s1', 'title'], 'After', 3);
  flock.set(['m', 'session-s1', 'parentSessionId'], 'parent', 4);
  const update = new TextEncoder().encode(
    JSON.stringify(flock.exportJson(version)),
  );
  let nextEvent;
  const catalogEvent = () =>
    new Promise((resolve) => {
      nextEvent = resolve;
    });
  const requests = [];
  const envelopes = [];
  const replies = new Map();
  let respond;
  const machineBootstrap = Promise.withResolvers();
  const pickerReady = Promise.withResolvers();
  globalThis.__runtimeTestClient = class {
    constructor({ url }) {
      this.isMeta = decodeURIComponent(url).endsWith(':meta');
    }
    async bootstrap() {
      if (!this.isMeta) await machineBootstrap.promise;
      return {
        ok: true,
        result: {
          snapshotOffset: '1',
          nextOffset: '1',
          upToDate: true,
          snapshot: { body: this.isMeta ? snapshot : machineSnapshot },
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
          if (event.type !== 'envelope') return;
          const message = JSON.parse(event.envelope);
          envelopes.push(message);
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
          if (
            message.kind === 'event' &&
            message.method === 'creationOptionsChanged'
          )
            pickerReady.resolve();
          if (message.kind === 'event' && message.method === 'catalog')
            nextEvent?.(message.payload);
        },
      },
    },
  };
  const bundle = await build({
    absWorkingDir: new URL('../../../../', import.meta.url).pathname,
    entryPoints: ['packages/cloud-runtime/src/runtime/index.ts'],
    bundle: true,
    format: 'esm',
    platform: 'browser',
    write: false,
    plugins: [
      {
        name: 'synthetic-stream',
        setup(build) {
          // Match the production runtime's inline-WASM resolution for loro-mirror.
          build.onResolve({ filter: /^loro-crdt$/ }, () =>
            build.resolve('loro-crdt/base64', {
              resolveDir: new URL('../../../../', import.meta.url).pathname,
              kind: 'import-statement',
            }),
          );
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
          build.onResolve({ filter: /^\.\.?\/files$/ }, () => ({
            path: 'files',
            namespace: 'file-test',
          }));
          build.onLoad({ filter: /.*/, namespace: 'file-test' }, () => ({
            contents: `
              export const readFile = (ctx, args) => ({
                status: 'error', path: args.path,
                code: ctx.ownerSessionId, message: args.sessionId,
              });
              export const fileDiff = (ctx, args) => ({
                status: 'unavailable', base: 'current', path: args.path,
                reason: ctx.ownerSessionId, message: args.sessionId,
              });
              export const turnDiff = fileDiff;
              export const workspaceChanges = (ctx, args) => ({
                status: 'unavailable',
                reason: ctx.ownerSessionId, message: args.sessionId,
              });
              export const listDir = () => ({ entries: [], truncated: false });
              export const listSessionDir = (ctx, args) => ({
                entries: [{ name: ctx.ownerSessionId + ':' + args.sessionId, type: 'file' }],
                truncated: false,
              });
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
  let nextCall = 0;
  const call = (method, payload = {}) => {
    const id = `call-${++nextCall}`;
    const reply = new Promise((resolve) => replies.set(id, resolve));
    globalThis.dataRuntime.receive(
      JSON.stringify({ v: 1, gen: 1, kind: 'request', id, method, payload }),
    );
    return reply;
  };
  await import(
    `data:text/javascript;base64,${Buffer.from(bundle.outputFiles[0].text).toString('base64')}`
  );
  const hello = await call('hello', { protocol: 1, gen: 1 });
  assert.deepEqual(envelopes.shift(), hello);
  assert.deepEqual(
    {
      ...hello,
      payload: { ...hello.payload, methods: [...hello.payload.methods].sort() },
    },
    {
      v: 1,
      gen: 1,
      kind: 'result',
      id: 'call-1',
      method: 'hello',
      payload: { protocol: 1, methods: Object.keys(runtimeCalls).sort() },
    },
  );
  const turn = {
    sessionId: 's1',
    machineId: 'm1',
    userId: 'u1',
    text: 'hello',
    billingEntitlement: null,
  };
  assert.deepEqual((await call('sendTurn', turn)).payload, {
    state: 'not_sent',
    reason: 'metadata_not_ready',
  });
  assert.deepEqual(
    (
      await call('editSession', {
        action: 'read',
        sessionId: 's1',
        expectedUserTurnId: 't1',
        userId: 'u1',
        billingEntitlement: null,
      })
    ).payload,
    { state: 'not_sent', reason: 'metadata_not_ready' },
  );
  const first = catalogEvent();
  const started = await call('start', {
    workspaceId: 'synthetic-workspace',
    userId: '',
    active: true,
    knownRepos: { 'm1:local:p1': 'Afilmory/afilmory' },
  });
  assert.equal(started.kind, 'result');
  await pickerReady.promise;
  const metaOnly = JSON.parse((await first).catalog);
  assert.equal(metaOnly.sessions[0].title, 'Before');
  assert.equal(
    metaOnly.projects.length,
    1,
    'metadata projects remain available while machine sync is pending',
  );
  const machineReady = catalogEvent();
  machineBootstrap.resolve();
  const initial = JSON.parse((await machineReady).catalog);
  assert.equal(
    envelopes.some((e) => e.method === 'syncError'),
    false,
  );
  assert.equal(initial.sessions[0].title, 'Before');
  assert.ok(initial.projects.some((p) => p.id === 'm1:local:p2'));
  assert.equal(
    initial.projects.find((p) => p.id === 'm1:local:p1').repoFullName,
    'Afilmory/afilmory',
  );
  const runtimeEvents = envelopes.filter((m) => m.kind === 'event');
  assert.deepEqual(
    runtimeEvents
      .filter((m) => m.method === 'catalog' || m.method === 'synced')
      .map((m) => m.method),
    ['catalog', 'synced', 'catalog', 'synced'],
  );
  assert.deepEqual(
    runtimeEvents.find(
      (m) => m.method === 'diagnostic' && m.payload.stage === 'bootstrap_ok',
    ).payload,
    { stage: 'bootstrap_ok', stream: 'meta' },
  );
  assert.equal(requests[0].live, 'long-poll');
  const fileCalls = {
    readFile: { sessionId: 's1', path: 'README.md' },
    fileDiff: { sessionId: 's1', path: 'README.md' },
    turnDiff: { sessionId: 's1', path: 'README.md', entryId: 'turn' },
    workspaceChanges: { sessionId: 's1' },
  };
  const owners = async () => {
    const found = {};
    for (const [method, payload] of Object.entries(fileCalls)) {
      const reply = await call(method, payload);
      assert.equal(reply.kind, 'result', method);
      assert.equal(reply.payload.message, 's1');
      found[method] = reply.payload.reason ?? reply.payload.code;
    }
    return found;
  };
  const ownedBy = (owner) =>
    Object.fromEntries(Object.keys(fileCalls).map((method) => [method, owner]));
  assert.deepEqual(await owners(), ownedBy('s1'));
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
  assert.equal(
    JSON.parse(changed.catalog).projects.find((p) => p.id === 'm1:local:p1')
      .repoFullName,
    'Afilmory/afilmory',
  );
  assert.equal(changed.revision, 3);
  assert.equal(
    JSON.parse(changed.catalog).sessions[0].parentSessionId,
    'parent',
  );
  // No session document was opened: ownership must come from live Meta Flock.
  assert.deepEqual(await owners(), ownedBy('parent'));
  const listing = await call('listDir', {
    workspaceId: 'synthetic-workspace',
    sessionId: 's1',
    relativePath: '',
    userId: '',
  });
  // The machine lists session folders, so even a non-local-project session lists its own
  // workspace, under the parent's owner key (as readFile reads it).
  assert.deepEqual(listing.payload, {
    entries: [{ name: 'parent:s1', type: 'file' }],
    truncated: false,
  });
  const detail = await call('itemDetail', {
    sessionId: 's1',
    entryId: 'e1',
    itemId: 'i1',
  });
  assert.deepEqual(detail.error, {
    code: 'session_not_ready',
    retryable: false,
  });
  assert.equal(requests[1].offset, '2');
  assert.equal(
    envelopes.filter((m) => m.kind === 'request' && m.method === 'grant')
      .length,
    1,
  );
  assert.ok(envelopes.every((m) => m.gen === 1));
  assert.deepEqual((await call('ping')).payload, {});
  const probe = await call('probeSchema', {
    workspaceId: 'synthetic-workspace',
  });
  assert.deepEqual(probe.payload, {
    creationOptionsTrial: {
      'm1:local:p1': 'ok agents=0 capabilities=0',
      'm1:local:p2': 'ok agents=0 capabilities=0',
    },
    machines: {
      m1: { otherKeys: ['e', 'localProject', 'm'], capabilities: [] },
    },
  });
  const writes = {
    createSession: {
      workspaceId: 'other-workspace',
      sessionId: 's2',
      machineId: 'm1',
      agentConfigId: 'a1',
      userId: 'u1',
      title: 'New',
      billingEntitlement: null,
    },
    deleteSession: {
      workspaceId: 'other-workspace',
      sessionId: 's1',
      sessionIds: ['s1'],
    },
    pinSession: {
      workspaceId: 'other-workspace',
      sessionId: 's1',
      pinned: true,
    },
    checkTurnQuota: { sessionId: 's1', billingEntitlement: null },
    sendTurn: { ...turn, modelId: { value: null } },
    controlTurn: {
      action: 'stop',
      sessionId: 's1',
      machineId: 'm1',
      turnId: 't1',
    },
    respondPermission: {
      sessionId: 's1',
      entryId: 'e1',
      itemId: 'i1',
      requestId: 'r1',
      optionId: 'o1',
    },
  };
  const outcomes = {};
  for (const [method, payload] of Object.entries(writes)) {
    const reply = await call(method, payload);
    outcomes[method] = reply.payload ?? reply.error;
  }
  assert.deepEqual(outcomes, {
    createSession: { state: 'rejected' },
    deleteSession: { code: 'metadata_not_ready', retryable: false },
    pinSession: { code: 'metadata_not_ready', retryable: false },
    checkTurnQuota: { state: 'allowed' },
    sendTurn: { state: 'not_sent', reason: 'session_not_ready' },
    controlTurn: { code: 'session_not_ready', retryable: false },
    respondPermission: { code: 'session_not_ready', retryable: false },
  });
  const mentions = await call('mentionCatalog', {
    workspaceId: 'synthetic-workspace',
    userId: '',
    category: 'session',
  });
  assert.equal(mentions.kind, 'result');
  assert.ok(
    mentions.payload.items.some(
      (item) =>
        item.kind === 'session' &&
        item.name === 'After' &&
        item.insertText === `@session:${item.path}`,
    ),
  );
  const moved = await call('promptShortcuts', {
    workspaceId: 'other-workspace',
    userId: '',
    action: 'list',
  });
  assert.deepEqual(moved.error, {
    code: 'workspace_changed',
    retryable: false,
  });
  globalThis.__runtimePresence.store.set('machine:m1', {
    kind: 'machine',
    machineId: 'm1',
    instanceId: 'test',
    updatedAt: Date.now(),
  });
  await new Promise((resolve) => setTimeout(resolve, 0));
  const presence = () =>
    envelopes
      .filter((m) => m.kind === 'event' && m.method === 'machinePresence')
      .at(-1).payload;
  assert.deepEqual(presence(), { state: 'live', onlineMachineIds: ['m1'] });
  assert.equal((await call('setActive', { active: false })).kind, 'result');
  assert.equal(globalThis.__runtimePresence.closed, true);
  assert.equal(presence().state, 'unknown');
  assert.deepEqual(
    envelopes.filter(
      (m) =>
        m.method === 'diagnostic' &&
        m.payload.stage.startsWith('contract_dropped'),
    ),
    [],
  );
  delete globalThis.__runtimePresence;
  delete globalThis.webkit;
  delete globalThis.__runtimeTestClient;
  delete globalThis.dataRuntime;
  globalThis.BroadcastChannel = previousBroadcastChannel;
  globalThis.fetch = previousFetch;
});

// Exercise the production contract channel and handlers. Only remote provider
// work is replaced: explicit promises model a daemon cancellation still pending.
async function providerHandlerFixture(t) {
  const bundle = await build({
    stdin: {
      contents: `
        export {createChannel} from './packages/cloud-runtime/src/runtime/channel.ts';
        export {registerSettings} from './packages/cloud-runtime/src/runtime/handlers/settings.ts';
        export {registerLifecycle} from './packages/cloud-runtime/src/runtime/handlers/lifecycle.ts';
        export {stopAcceptedInputs, stopSessions} from './packages/cloud-runtime/src/runtime/session.ts';
      `,
      resolveDir: new URL('../../../../', import.meta.url).pathname,
      loader: 'ts',
    },
    bundle: true,
    format: 'esm',
    platform: 'browser',
    write: false,
    plugins: [
      {
        name: 'provider-boundary',
        setup(build) {
          build.onResolve({ filter: /^loro-crdt$/ }, () =>
            build.resolve('loro-crdt/base64', {
              resolveDir: new URL('../../../../', import.meta.url).pathname,
              kind: 'import-statement',
            }),
          );
          build.onResolve({ filter: /\/provider-rpc$/ }, () => ({
            path: 'provider-rpc',
            namespace: 'provider-boundary',
          }));
          build.onLoad(
            { filter: /.*/, namespace: 'provider-boundary' },
            () => ({
              contents:
                'export const createProviderRpc = options => globalThis.__providerBoundaryFactory(options);',
            }),
          );
        },
      },
    ],
  });
  const {
    createChannel,
    registerSettings,
    registerLifecycle,
    stopAcceptedInputs,
    stopSessions,
  } = await import(
    `data:text/javascript;base64,${Buffer.from(bundle.outputFiles[0].text).toString('base64')}`
  );
  const state = {
    workspace: 'workspace-a',
    userId: 'user-a',
    metaReplica: { flock: new Flock('synthetic-old') },
    presence: { state: 'live', onlineMachineIds: ['machine'] },
    knownProjects: [],
    machineReplicas: new Map(),
    catalogs: new Map(),
    unhealthy: new Set(),
  };
  const events = [],
    replies = new Map(),
    services = [],
    transitions = [],
    workspaceRefreshes = [];
  let sequence = 0,
    cleanup;
  const channel = createChannel((text) => {
    const message = JSON.parse(text);
    if (message.kind === 'event') events.push(message);
    else {
      replies.get(message.id)?.(message);
      replies.delete(message.id);
    }
  });
  const ctx = {
    channel,
    state,
    getGrant: async () => ({
      token: 'synthetic',
      gatewayBaseUrl: 'https://example.invalid',
      expiresIn: 3600,
    }),
    watch: () => {
      transitions.push([state.workspace, state.userId]);
      state.metaReplica = { flock: new Flock('synthetic-new') };
    },
    refreshWorkspace() {
      workspaceRefreshes.push([state.workspace, state.userId]);
    },
    startPresence() {},
    stopPresence() {},
    publish() {},
    publishSubscriptions() {},
    emitSession() {},
    markDispatch: async () => {},
    broker: async () => {
      throw new Error('unexpected_broker');
    },
  };
  globalThis.__providerBoundaryFactory = (options) => {
    let disposed = false;
    const flows = new Set();
    const usable = () => {
      options.check();
      if (disposed) throw new Error('provider_disposed');
    };
    const service = {
      check: options.check,
      operation: async (args) => {
        usable();
        return {
          action: args.action,
          success: true,
          status: 'installed',
          version: `${state.workspace}/${state.userId}`,
        };
      },
      auth: async (args) => {
        usable();
        if (args.action === 'start') flows.add(args.flowId);
        if (!flows.has(args.flowId))
          throw new Error('provider_auth_flow_unknown');
        return {
          flowId: args.flowId,
          status: 'verifying',
          methods: [],
          fields: [],
          acceptsAuthorizationCode: false,
          requiresAuthorizationConsent: false,
        };
      },
      dispose: async () => {
        disposed = true;
        if (!cleanup) return { unconfirmedFlowIds: [] };
        const pending = cleanup;
        cleanup = undefined;
        pending.entered.resolve([state.workspace, state.userId]);
        return pending.result.promise;
      },
    };
    services.push(service);
    return service;
  };
  t.after(async () => {
    stopSessions();
    await stopAcceptedInputs();
    delete globalThis.__providerBoundaryFactory;
  });
  registerSettings(ctx);
  registerLifecycle(ctx);
  const call = (method, payload) => {
    const id = `provider-boundary-${++sequence}`;
    const result = new Promise((resolve) => replies.set(id, resolve));
    channel.receive(
      JSON.stringify({ v: 1, gen: 0, kind: 'request', id, method, payload }),
    );
    return result;
  };
  const blockCleanup = () => {
    cleanup = {
      entered: Promise.withResolvers(),
      result: Promise.withResolvers(),
    };
    return cleanup;
  };
  return {
    state,
    call,
    events,
    services,
    transitions,
    workspaceRefreshes,
    blockCleanup,
  };
}

const providerScope = {
  workspaceId: 'workspace-a',
  userId: 'user-a',
  machineId: 'machine',
  id: 'codex',
};

test('provider handler recovers after same-scope Meta Flock replacement and fences the old flow', async (t) => {
  const f = await providerHandlerFixture(t),
    flowId = crypto.randomUUID();
  const auth = { ...providerScope, flowId, action: 'start' };
  assert.equal(
    (await f.call('agentProviderAuth', auth)).payload.status,
    'verifying',
  );
  const old = f.services[0];
  // Replacing only the replica wrapper must not invalidate its Flock identity.
  f.state.metaReplica = { ...f.state.metaReplica };
  assert.equal(
    (await f.call('agentProviderAuth', { ...auth, action: 'status' })).payload
      .status,
    'verifying',
  );
  f.state.metaReplica = { flock: new Flock('synthetic-recovered') };
  assert.throws(old.check, /workspace_changed/);
  const pending = f.blockCleanup();
  const operation = f.call('agentProviderOperation', {
    ...providerScope,
    action: 'binary-status',
  });
  assert.deepEqual(await pending.entered.promise, ['workspace-a', 'user-a']);
  pending.result.resolve({ unconfirmedFlowIds: [flowId] });
  assert.deepEqual((await operation).payload, {
    action: 'binary-status',
    success: true,
    status: 'installed',
    version: 'workspace-a/user-a',
  });
  assert.equal(
    (await f.call('agentProviderAuth', { ...auth, action: 'status' })).error
      .code,
    'provider_auth_flow_unknown',
  );
  const errors = f.events
    .filter((e) => e.method === 'agentProviderAuthChanged')
    .map((e) => e.payload);
  assert.deepEqual(errors, [
    {
      flowId,
      status: 'error',
      errorCode: 'provider_auth_cancel_unknown',
      methods: [],
      fields: [],
      acceptsAuthorizationCode: false,
      requiresAuthorizationConsent: false,
    },
  ]);
  assert.equal(
    (
      await f.call('agentProviderAuth', {
        ...auth,
        flowId: crypto.randomUUID(),
      })
    ).payload.status,
    'verifying',
  );
});

test('overlapping starts preserve the old scope until provider cleanup completes and only latest scope becomes usable', async (t) => {
  const f = await providerHandlerFixture(t);
  assert.equal(
    (
      await f.call('agentProviderOperation', {
        ...providerScope,
        action: 'binary-status',
      })
    ).payload.success,
    true,
  );
  const pending = f.blockCleanup();
  const first = f.call('start', {
    workspaceId: 'workspace-b',
    userId: 'user-b',
    active: false,
  });
  assert.deepEqual(await pending.entered.promise, ['workspace-a', 'user-a']);
  assert.deepEqual(
    [f.state.workspace, f.state.userId],
    ['workspace-a', 'user-a'],
  );
  assert.equal(
    (
      await f.call('agentProviderOperation', {
        ...providerScope,
        workspaceId: 'workspace-b',
        userId: 'user-b',
        action: 'binary-status',
      })
    ).error.code,
    'workspace_changed',
  );
  const latest = f.call('start', {
    workspaceId: 'workspace-c',
    userId: 'user-c',
    active: false,
  });
  // receive invokes each handler synchronously up to its first await, so both
  // starts are now waiting on the same explicitly controlled cleanup promise.
  assert.deepEqual(
    [f.state.workspace, f.state.userId],
    ['workspace-a', 'user-a'],
  );
  pending.result.resolve({ unconfirmedFlowIds: [] });
  assert.equal((await first).kind, 'result');
  assert.equal((await latest).kind, 'result');
  assert.deepEqual(f.transitions, [['workspace-c', 'user-c']]);
  assert.deepEqual(f.workspaceRefreshes, [['workspace-c', 'user-c']]);
  assert.deepEqual(
    (
      await f.call('agentProviderOperation', {
        ...providerScope,
        workspaceId: 'workspace-c',
        userId: 'user-c',
        action: 'binary-status',
      })
    ).payload,
    {
      action: 'binary-status',
      success: true,
      status: 'installed',
      version: 'workspace-c/user-c',
    },
  );
  assert.equal(
    (
      await f.call('agentProviderOperation', {
        ...providerScope,
        action: 'binary-status',
      })
    ).error.code,
    'workspace_changed',
  );
});

test('catalog frame import serves heartbeat macrotasks between slices and preserves real Flock updates', async (t) => {
  const { catalogImportCheckpoint, importCatalogUpdates } =
    await import('../../../../packages/cloud-runtime/src/runtime/catalog-sync.ts');
  const { encodeFrame } =
    await import('../../../../packages/cloud-runtime/src/frames.ts');
  t.mock.timers.enable({ apis: ['setTimeout'] });
  let now = 0,
    imported = 0,
    heartbeatAt;
  t.mock.method(performance, 'now', () => now);
  const server = new Flock('catalog-frames');
  const target = new Flock('catalog-reader');
  const frames = [];
  for (let i = 0; i < 10; i++) {
    const version = server.version();
    server.set(['m', `session-${i}`], { title: `Session ${i}` }, i + 1);
    frames.push(
      encodeFrame(
        new TextEncoder().encode(JSON.stringify(server.exportJson(version))),
      ),
    );
  }
  const bytes = new Uint8Array(
    frames.reduce((sum, frame) => sum + frame.length, 0),
  );
  let offset = 0;
  for (const frame of frames) {
    bytes.set(frame, offset);
    offset += frame.length;
  }
  const original = target.importJson.bind(target);
  t.mock.method(target, 'importJson', (json) => {
    original(json);
    imported++;
    now += 4;
  });
  setTimeout(() => {
    heartbeatAt = imported;
  }, 0);
  const result = importCatalogUpdates(
    target,
    bytes,
    catalogImportCheckpoint(new AbortController().signal),
  );
  const turn = () => new Promise((resolve) => setImmediate(resolve));
  await turn();
  assert.equal(imported, 3, 'one slice imports only its 12 ms allowance');
  t.mock.timers.tick(0);
  await turn();
  assert.equal(
    heartbeatAt,
    3,
    'native ping can run before all catalog frames finish',
  );
  for (let i = 0; i < 3; i++) {
    t.mock.timers.tick(0);
    await turn();
  }
  await result;
  for (let i = 0; i < 10; i++)
    assert.equal(target.get(['m', `session-${i}`]).title, `Session ${i}`);
});

test('scope cancellation at a catalog import yield stops before the next frame', async (t) => {
  const { catalogImportCheckpoint, importCatalogUpdates } =
    await import('../../../../packages/cloud-runtime/src/runtime/catalog-sync.ts');
  const { encodeFrame } =
    await import('../../../../packages/cloud-runtime/src/frames.ts');
  t.mock.timers.enable({ apis: ['setTimeout'] });
  let now = 0;
  t.mock.method(performance, 'now', () => now);
  const server = new Flock('cancel-server'),
    target = new Flock('cancel-reader');
  server.set(['m', 'session-one'], { title: 'One' }, 1);
  const first = encodeFrame(
    new TextEncoder().encode(JSON.stringify(server.exportJson())),
  );
  const version = server.version();
  server.set(['m', 'session-two'], { title: 'Two' }, 2);
  const second = encodeFrame(
    new TextEncoder().encode(JSON.stringify(server.exportJson(version))),
  );
  const bytes = new Uint8Array(first.length + second.length);
  bytes.set(first);
  bytes.set(second, first.length);
  const controller = new AbortController();
  const original = target.importJson.bind(target);
  t.mock.method(target, 'importJson', (json) => {
    original(json);
    now += 12;
  });
  setTimeout(() => controller.abort(new Error('workspace_changed')), 0);
  const result = importCatalogUpdates(
    target,
    bytes,
    catalogImportCheckpoint(controller.signal),
  );
  const rejected = assert.rejects(result, /workspace_changed/);
  await new Promise((resolve) => setImmediate(resolve));
  t.mock.timers.tick(0);
  await rejected;
  assert.equal(target.get(['m', 'session-one']).title, 'One');
  assert.equal(target.get(['m', 'session-two']), undefined);
});

test('bundled DataRuntime permits secure WS and retains the script and default CSP boundaries', async () => {
  const directory = await mkdtemp(
    path.join(tmpdir(), 'lody-data-runtime-csp-'),
  );
  try {
    await buildDataRuntime(directory);
    const html = await readFile(
      path.join(directory, 'DataRuntime.html'),
      'utf8',
    );
    const policy = html.match(
      /http-equiv="Content-Security-Policy" content="([^"]+)"/,
    )[1];
    assert.deepEqual(
      policy.split(';').map((part) => part.trim()),
      [
        "default-src 'none'",
        'connect-src https: wss:',
        "script-src 'unsafe-inline' 'wasm-unsafe-eval'",
      ],
    );
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});

// iOS 16.4–17.3 WebKit has no AbortSignal.any; the runtime entry installs a
// fallback before any module runs. Drive catalog sync's combined HEAD signal.
test('catalog sync combines and cancels signals on a WebKit without AbortSignal.any or URL.canParse', async (t) => {
  const nativeAny = Object.getOwnPropertyDescriptor(AbortSignal, 'any');
  const nativeCanParse = Object.getOwnPropertyDescriptor(URL, 'canParse');
  const previousFetch = globalThis.fetch;
  const previousBroadcastChannel = globalThis.BroadcastChannel;
  t.after(() => {
    Object.defineProperty(AbortSignal, 'any', nativeAny);
    Object.defineProperty(URL, 'canParse', nativeCanParse);
    globalThis.fetch = previousFetch;
    globalThis.BroadcastChannel = previousBroadcastChannel;
    delete globalThis.webkit;
    delete globalThis.__anyClient;
    delete globalThis.dataRuntime;
  });
  delete AbortSignal.any;
  delete URL.canParse;
  assert.equal(URL.canParse, undefined);
  assert.equal(AbortSignal.any, undefined);
  globalThis.BroadcastChannel = undefined;
  globalThis.fetch = async () => {
    throw new Error('network_disabled');
  };

  const meta = new Flock('meta');
  meta.set(['e', 'machine-m1'], true);
  meta.set(['m', 'machine-m1'], { name: 'Mac', ownerUserId: 'u1' });
  const metaVersion = meta.version();
  const metaSnapshot = meta.exportFile();
  const machine = new Flock('machine');
  machine.set(['localProject', 'p1'], { name: 'app', rootPath: '/a' });
  const machineSnapshot = machine.exportFile();
  const head = Promise.withResolvers();
  const metaRead = Promise.withResolvers();
  let machineReads = 0;
  let metaReads = 0;
  globalThis.__anyClient = class {
    constructor({ url }) {
      this.stream = decodeURIComponent(url.split('/ds/lody/')[1]);
    }
    async bootstrap() {
      const body = {
        'w1:meta': metaSnapshot,
        'w1:mf:m1': machineSnapshot,
        'w1:wf:workspace': new Flock('workspace').exportFile(),
      }[this.stream];
      if (!body) return { ok: false, result: { code: 'not_found' } };
      return {
        ok: true,
        result: {
          snapshotOffset: '1',
          nextOffset: '1',
          upToDate: true,
          snapshot: { body },
          updates: [],
        },
      };
    }
    readOnce() {
      if (this.stream === 'w1:meta')
        return metaReads++ === 0 ? metaRead.promise : new Promise(() => {});
      // A caught-up machine reports a backlog: the runtime asks HEAD whether a
      // fresh snapshot is cheaper, with its watcher signal plus a timeout.
      if (this.stream === 'w1:mf:m1' && machineReads++ === 0)
        return Promise.resolve({
          ok: true,
          result: { nextOffset: '2', upToDate: false },
        });
      return new Promise(() => {});
    }
    head({ signal }) {
      head.resolve(signal);
      return new Promise((_, reject) =>
        signal.addEventListener('abort', () => reject(signal.reason)),
      );
    }
  };
  const replies = new Map();
  globalThis.webkit = {
    messageHandlers: {
      dataRuntime: {
        postMessage(event) {
          if (event.type !== 'envelope') return;
          const message = JSON.parse(event.envelope);
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
        name: 'abort-any-streams',
        setup(build) {
          build.onResolve({ filter: /^loro-crdt$/ }, () =>
            build.resolve('loro-crdt/base64', {
              resolveDir: root,
              kind: 'import-statement',
            }),
          );
          build.onResolve({ filter: /^@loro-dev\/streams-client$/ }, () => ({
            path: 'client',
            namespace: 'abort-any',
          }));
          build.onResolve(
            { filter: /^@loro-dev\/streams-crdt\/loro$/ },
            () => ({ path: 'presence', namespace: 'abort-any' }),
          );
          build.onLoad({ filter: /.*/, namespace: 'abort-any' }, (args) => ({
            contents:
              args.path === 'client'
                ? 'export const StreamsClient = globalThis.__anyClient;'
                : 'export const EphemeralStoreAdaptor = s => s; export class EphemeralStreamCrdt { async join() { return { ok: true, value: { unsubscribe() {} } }; } async close() {} }',
          }));
        },
      },
    ],
  });
  // A distinct module URL: never reuse another test's initialized runtime.
  await import(
    `data:text/javascript;base64,${Buffer.from(`${bundle.outputFiles[0].text}\n// abort-signal-any`).toString('base64')}`
  );
  assert.equal(typeof AbortSignal.any, 'function', 'the entry installs it');
  assert.equal(typeof URL.canParse, 'function', 'the entry installs it');
  assert.equal(URL.canParse('https://example.invalid/a'), true);
  assert.equal(URL.canParse('not a url'), false);
  assert.equal(URL.canParse('/a', 'https://example.invalid'), true);
  let next = 0;
  const call = (method, payload = {}) => {
    const id = `call-${++next}`;
    const reply = new Promise((resolve) => replies.set(id, resolve));
    globalThis.dataRuntime.receive(
      JSON.stringify({ v: 1, gen: 1, kind: 'request', id, method, payload }),
    );
    return reply;
  };
  await call('hello', { protocol: 1, gen: 1 });
  await call('start', { workspaceId: 'w1', userId: 'u1', active: false });

  const signal = await head.promise;
  assert.equal(signal.aborted, false);
  // The machine leaves the workspace: its watcher stops, and the combined
  // signal handed to HEAD must abort with the watcher's reason.
  meta.set(['e', 'machine-m1'], false);
  const update = new TextEncoder().encode(
    JSON.stringify(meta.exportJson(metaVersion)),
  );
  const body = new Uint8Array(update.length + 4);
  new DataView(body.buffer).setUint32(0, update.length, false);
  body.set(update, 4);
  const aborted = new Promise((resolve) =>
    signal.addEventListener('abort', resolve, { once: true }),
  );
  metaRead.resolve({
    ok: true,
    result: {
      nextOffset: '2',
      upToDate: true,
      payload: { body },
    },
  });
  await aborted;
  assert.equal(signal.aborted, true);
  assert.equal(signal.reason?.name, 'AbortError');
});

test('the AbortSignal.any fallback follows the standard', async () => {
  const { abortSignalAny, installAbortSignalAny } =
    await import('../../../../packages/cloud-runtime/src/runtime/abort-signal-any.ts');
  // An already-aborted input yields an aborted signal with its reason.
  const done = new AbortController();
  done.abort('first');
  const early = abortSignalAny([new AbortController().signal, done.signal]);
  assert.equal(early.aborted, true);
  assert.equal(early.reason, 'first');

  // The first input to abort decides the reason; listeners leave every input.
  const inputs = [new AbortController(), new AbortController()];
  const attached = new Set();
  for (const { signal } of inputs) {
    const add = signal.addEventListener.bind(signal);
    const remove = signal.removeEventListener.bind(signal);
    signal.addEventListener = (type, listener, options) => {
      attached.add(listener);
      add(type, listener, options);
    };
    signal.removeEventListener = (type, listener, options) => {
      attached.delete(listener);
      remove(type, listener, options);
    };
  }
  const combined = abortSignalAny(inputs.map((c) => c.signal));
  assert.equal(combined.aborted, false);
  assert.equal(attached.size, 2);
  const reason = new Error('scope_changed');
  inputs[1].abort(reason);
  assert.equal(combined.aborted, true);
  assert.equal(combined.reason, reason);
  assert.equal(attached.size, 0);
  inputs[0].abort('late');
  assert.equal(combined.reason, reason);
  assert.equal(abortSignalAny([]).aborted, false);

  // As the standard's dependent signals: a long-lived input (a session or
  // watcher signal) holds a combined signal weakly, so request signals combined
  // with it do not accumulate.
  const gc = vm.runInNewContext('gc');
  const longLived = new AbortController();
  const weak = (() => new WeakRef(abortSignalAny([longLived.signal])))();
  await new Promise((resolve) => setImmediate(resolve));
  gc();
  assert.equal(weak.deref(), undefined);
  const held = abortSignalAny([longLived.signal]);
  await new Promise((resolve) => setImmediate(resolve));
  gc();
  longLived.abort('stop');
  assert.equal(held.reason, 'stop', 'a held combined signal still aborts');

  // A platform that has it keeps its own.
  const native = function any() {};
  const target = { any: native };
  assert.equal(installAbortSignalAny(target), false);
  assert.equal(target.any, native);
  const bare = {};
  assert.equal(installAbortSignalAny(bare), true);
  assert.equal(bare.any, abortSignalAny);
});

test('the URL.canParse fallback follows the standard and serves Effect URL schemas', async (t) => {
  const { urlCanParse, installUrlCanParse } =
    await import('../../../../packages/cloud-runtime/src/runtime/url-can-parse.ts');
  assert.equal(urlCanParse('https://example.invalid/a?b#c'), true);
  assert.equal(urlCanParse('https://exa mple.invalid'), false);
  assert.equal(urlCanParse(''), false);
  // A relative URL parses only against a base; an undefined base is no base.
  assert.equal(urlCanParse('/path'), false);
  assert.equal(urlCanParse('/path', 'https://example.invalid'), true);
  assert.equal(urlCanParse('/path', undefined), false);
  assert.equal(urlCanParse('/path', 'not a base'), false);
  assert.equal(urlCanParse(new URL('https://example.invalid')), true);
  // Same answers as the platform's own, where it exists.
  for (const [url, base] of [
    ['https://a.invalid'],
    ['/x', 'https://a.invalid'],
    ['/x'],
    ['http://[::1'],
  ])
    assert.equal(urlCanParse(url, base), URL.canParse(url, base), url);

  // A platform that has it keeps its own.
  const native = function canParse() {};
  const target = { canParse: native };
  assert.equal(installUrlCanParse(target), false);
  assert.equal(target.canParse, native);

  // Effect's URLFromString calls URL.canParse while decoding.
  const nativeCanParse = Object.getOwnPropertyDescriptor(URL, 'canParse');
  t.after(() => Object.defineProperty(URL, 'canParse', nativeCanParse));
  delete URL.canParse;
  assert.equal(installUrlCanParse(), true);
  assert.equal(URL.canParse, urlCanParse);
  const { Schema } = await import('effect');
  const decode = Schema.decodeUnknownSync(Schema.URLFromString);
  assert.equal(
    decode('https://example.invalid/a').href,
    'https://example.invalid/a',
  );
  assert.throws(() => decode('not a url'));
});

test('share uploads release their hold on the caller signal once every task settles', async (t) => {
  const { abortSignalAny } =
    await import('../../../../packages/cloud-runtime/src/runtime/abort-signal-any.ts');
  const { mapShareConcurrent } =
    await import('../../../../packages/cloud-runtime/src/runtime/sharing/session-share-concurrency.ts');
  // The WebKit 16.4 path: the fallback, whose listeners are observable.
  const nativeAny = Object.getOwnPropertyDescriptor(AbortSignal, 'any');
  t.after(() => Object.defineProperty(AbortSignal, 'any', nativeAny));
  Object.defineProperty(AbortSignal, 'any', {
    value: abortSignalAny,
    configurable: true,
    writable: true,
  });
  const editor = new AbortController();
  const attached = new Set();
  const add = editor.signal.addEventListener.bind(editor.signal);
  const remove = editor.signal.removeEventListener.bind(editor.signal);
  editor.signal.addEventListener = (type, listener, options) => {
    attached.add(listener);
    add(type, listener, options);
  };
  editor.signal.removeEventListener = (type, listener, options) => {
    attached.delete(listener);
    remove(type, listener, options);
  };
  const seen = [];
  const results = await mapShareConcurrent(
    [1, 2, 3],
    async (item, _index, signal) => {
      seen.push(signal.aborted);
      return item * 2;
    },
    editor.signal,
  );
  assert.deepEqual(results, [2, 4, 6]);
  assert.deepEqual(seen, [false, false, false]);
  assert.equal(attached.size, 0);
  await assert.rejects(
    mapShareConcurrent(
      [1],
      async () => {
        throw new Error('upload_failed');
      },
      editor.signal,
    ),
    /upload_failed/,
  );
  assert.equal(attached.size, 0);
  assert.equal(editor.signal.aborted, false);
});
