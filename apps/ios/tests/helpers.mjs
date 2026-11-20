import { build } from 'esbuild';
import { LoroDoc } from 'loro-crdt/base64';
import { createRequire } from 'node:module';
import { pathToFileURL } from 'node:url';
import { IDBFactory, IDBKeyRange } from 'fake-indexeddb';

export async function loadRuntime(storageSuffix = '') {
  const bundle = await build({
    define: { LODY_MOBILE_STORAGE_SUFFIX: JSON.stringify(storageSuffix) },
    stdin: {
      contents:
        "export * from './session.ts'; export { createRoostHistoryTransport } from './roost-history.ts'; export { sealPayload, openPayload } from './machine-rpc.ts'; export { registerSessions } from './handlers/sessions.ts';",
      resolveDir: new URL(
        '../../../packages/cloud-runtime/src/runtime/',
        import.meta.url,
      ).pathname,
      loader: 'ts',
    },
    bundle: true,
    format: 'esm',
    platform: 'browser',
    write: false,
    plugins: [
      {
        name: 'stream',
        setup(b) {
          // Fixtures and runtime must share one WASM instance: passing a Loro
          // container between independently bundled instances corrupts pointers.
          b.onResolve({ filter: /^loro-crdt\/base64$/ }, () => ({
            path: pathToFileURL(
              createRequire(import.meta.url).resolve('loro-crdt/base64'),
            ).href,
            external: true,
          }));
          b.onResolve({ filter: /^@loro-dev\/streams-client$/ }, () => ({
            path: 'mock',
            namespace: 'test',
          }));
          b.onLoad({ filter: /.*/, namespace: 'test' }, () => ({
            contents:
              'export class StreamsClient{constructor(a){return new globalThis.__sessionClient(a)}}',
          }));
        },
      },
    ],
  });
  return import(
    `data:text/javascript;base64,${Buffer.from(bundle.outputFiles[0].text).toString('base64')}`
  );
}

export function frame(bytes) {
  const result = new Uint8Array(bytes.length + 4);
  new DataView(result.buffer).setUint32(0, bytes.length, false);
  result.set(bytes, 4);
  return result;
}

export async function* historyPublications(request, runtime, signal, next) {
  const { sessionId, readProof, subscription } = await runtime.openPayload(
    request.params,
  );
  if (readProof !== 'synthetic-read-proof' || subscription.action !== 'open')
    throw new Error('Invalid subscription intent');
  const frame = (publication) => ({
    type: 'session/history-subscription_response',
    sessionId,
    subscriptionId: subscription.id,
    event: 'publication',
    publication,
  });
  const response = next(subscription, signal);
  // A matching initial publication leaves the persisted projection unchanged.
  yield {
    result: await runtime.sealPayload(
      sessionId,
      frame({ checkpoint: subscription.checkpoint, revision: 1 }),
    ),
  };
  const delta = await response;
  yield {
    result: await runtime.sealPayload(
      sessionId,
      frame({
        checkpoint: delta.result.checkpoint,
        revision: delta.historyRevision,
        delta: {
          baseCheckpoint: subscription.checkpoint,
          includeBodiesFrom: subscription.includeBodiesFrom,
          withPatches: subscription.withPatches,
          response: delta,
        },
      }),
    ),
  };
  await new Promise((resolve) => {
    if (signal.aborted) resolve();
    else signal.addEventListener('abort', resolve, { once: true });
  });
}

export async function openTestSession({
  failAppend = () => false,
  afterAppend,
  beforeBootstrap,
  readSession,
  markDispatch = async () => {},
  onRpc,
  onSubscription,
  onEvent = () => {},
  readyWhen = (snapshot) => snapshot.status === 'live',
  target,
  resolveTarget,
  indexedDBAvailable = true,
  indexedDBFactory,
  storageSuffix,
  seedServer = () => {},
  catchupServer,
  /** Bytes of the workspace settings Flock (`w1:wf:workspace`), e.g. Agent Role rows. */
  settings,
} = {}) {
  const previousIndexedDB = globalThis.indexedDB;
  const previousIDBKeyRange = globalThis.IDBKeyRange;
  const previousNavigator = Object.getOwnPropertyDescriptor(
    globalThis,
    'navigator',
  );
  const locks = new Map();
  Object.defineProperty(globalThis, 'navigator', {
    configurable: true,
    value: {
      locks: {
        request(name, { signal }, work) {
          const previous = locks.get(name) ?? Promise.resolve();
          let granted = false;
          const current = previous
            .catch(() => {})
            .then(() => {
              signal.throwIfAborted();
              granted = true;
              return work();
            });
          locks.set(name, current);
          // As in Web Locks, aborting rejects a request that is still queued.
          return new Promise((resolve, reject) => {
            const abort = () => {
              if (!granted)
                reject(new DOMException('Lock request aborted', 'AbortError'));
            };
            signal.addEventListener('abort', abort, { once: true });
            current
              .then(resolve, reject)
              .finally(() => signal.removeEventListener('abort', abort));
          });
        },
      },
    },
  });
  globalThis.indexedDB = indexedDBAvailable
    ? (indexedDBFactory ?? new IDBFactory())
    : {
        open() {
          const error = new Error('IndexedDB unavailable');
          error.stack = undefined;
          throw error;
        },
      };
  globalThis.IDBKeyRange = IDBKeyRange;
  const server = new LoroDoc();
  seedServer(server);
  const ok = (result) => ({ ok: true, result });
  let sessionRead;
  let catchupUpdate;
  let offset = 1;
  const appends = [];
  const replies = new Map();
  globalThis.__sessionClient = class {
    constructor({ url }) {
      this.url = decodeURIComponent(url);
    }
    async bootstrap() {
      if (beforeBootstrap) await beforeBootstrap(this.url);
      if (this.url.includes(':wf:') && settings)
        return ok({
          snapshotOffset: '1',
          nextOffset: '1',
          upToDate: true,
          snapshot: { body: settings() },
          updates: [],
        });
      const snapshot = server.export({ mode: 'snapshot' });
      if (catchupServer) {
        const version = server.version();
        catchupServer(server);
        catchupUpdate = server.export({ mode: 'update', from: version });
      }
      return ok({
        snapshotOffset: '1',
        nextOffset: '1',
        upToDate: !catchupUpdate,
        snapshot: { body: snapshot },
        updates: [],
      });
    }
    async readOnce(options = {}) {
      const { signal } = options;
      if (this.url.includes(':rpc:res:') && onRpc) {
        const request = replies.get(this.url.split('/ds/lody/')[1]);
        const result = await onRpc(request, runtime, signal);
        return ok({
          nextOffset: '1',
          upToDate: true,
          closed: false,
          payload: {
            body: new TextEncoder().encode(
              JSON.stringify({ id: request.id, ...result }),
            ),
          },
        });
      }
      if (catchupUpdate) {
        const bytes = catchupUpdate;
        catchupUpdate = undefined;
        return ok({
          nextOffset: '2',
          upToDate: true,
          closed: false,
          payload: { body: frame(bytes) },
        });
      }
      if (readSession && this.url.endsWith(':s:s1'))
        return readSession(options);
      return new Promise((resolve) => {
        sessionRead = resolve;
      });
    }
    async *live({ signal, mode }) {
      const request = replies.get(this.url.split('/ds/lody/')[1]);
      if (
        mode !== 'long-poll' ||
        !onSubscription ||
        request?.method !== 'session/history-subscribe'
      )
        throw new Error('Unexpected live stream');
      for await (const result of onSubscription(request, runtime, signal)) {
        yield {
          type: 'data',
          mode,
          nextOffset: String(++offset),
          payload: {
            body: new TextEncoder().encode(
              JSON.stringify({ id: request.id, ...result }),
            ),
          },
        };
      }
    }
    async create() {
      return ok({});
    }
    async append({ part }) {
      appends.push(this.url);
      if (failAppend(this.url))
        return { ok: false, result: { code: 'timeout' } };
      if (this.url.includes(':rpc:req:')) {
        const request = JSON.parse(part.body);
        if (request.method !== 'session/history-unsubscribe')
          replies.set(request.replyTo, request);
      } else if (!this.url.includes(':rpc:'))
        server.import(part.body.subarray(4));
      if (afterAppend) await afterAppend(this.url, part);
      return ok({ nextOffset: String(++offset) });
    }
  };
  const runtime = await loadRuntime(storageSuffix);
  let resolveEmit;
  const events = [];
  const background = [];
  const nextEmit = (matches = () => true) =>
    new Promise((resolve) => {
      resolveEmit = (value) => {
        if (!matches(value)) return;
        resolveEmit = undefined;
        resolve(value);
      };
    });
  const ready = Promise.withResolvers();
  const emit = (e) => {
    onEvent(e);
    if (e.backgroundWork) background.push(e.backgroundWork);
    if (!e.session) return;
    const value = JSON.parse(e.session);
    events.push(value);
    if (readyWhen(value)) ready.resolve();
    if (value.status === 'live') resolveEmit?.(value);
  };
  const targetResolver = resolveTarget ?? (target ? () => target : undefined);
  const resolver =
    targetResolver &&
    Object.assign(() => {
      const value = targetResolver();
      if (value?.backend !== 'roost') return value;
      return {
        incremental: true,
        live: !!onSubscription,
        getHistoryProof: async (intent) =>
          intent.requestId ? 'synthetic-write-proof' : 'synthetic-read-proof',
        ...value,
      };
    }, targetResolver);
  const reopen = () =>
    runtime.openSession(
      's1',
      'w1',
      async () => ({ token: 'synthetic', gatewayBaseUrl: 'https://x.invalid' }),
      emit,
      markDispatch,
      true,
      resolver,
    );
  await reopen();
  await ready.promise;
  if (target?.backend === 'roost' || resolveTarget?.()?.backend === 'roost') {
    runtime.startAcceptedInputs({
      accountId: 'u1',
      workspaceId: 'w1',
      getGrant: async () => ({
        token: 'synthetic',
        gatewayBaseUrl: 'https://x.invalid',
      }),
      emit,
      markDispatch,
      async getDocMeta(room) {
        const current = resolver();
        if (current?.backend !== 'roost') return undefined;
        if (room === 'session-s1')
          return {
            exists: true,
            meta: {
              id: 's1',
              machineId: current.machineId,
              historyBackend: 'roost',
              latestUserMsgId: current.latestUserMsgId,
              isArchived: current.isArchived,
            },
          };
        if (room === 'machine-' + current.machineId)
          return {
            exists: true,
            meta: {
              protocolCapabilities: {
                sessionInputAcceptance: current.acceptsInput ? 1 : 0,
                sessionInputDispatch: current.dispatchesInput ? 1 : 0,
              },
            },
          };
      },
      resolveTarget: () => resolver,
    });
  }
  let version = server.version();
  const pushUpdate = async () => {
    const update = server.export({ mode: 'update', from: version });
    version = server.version();
    const emitted = nextEmit();
    sessionRead(
      ok({
        nextOffset: String(++offset),
        upToDate: true,
        closed: false,
        payload: { body: frame(update) },
      }),
    );
    return emitted;
  };
  const close = () => {
    runtime.stopSessions();
    void runtime.stopAcceptedInputs();
    if (previousNavigator)
      Object.defineProperty(globalThis, 'navigator', previousNavigator);
    else delete globalThis.navigator;
    delete globalThis.__sessionClient;
    globalThis.indexedDB = previousIndexedDB;
    globalThis.IDBKeyRange = previousIDBKeyRange;
  };
  return {
    runtime,
    server,
    pushUpdate,
    reopen,
    nextEmit,
    events,
    background,
    appends,
    close,
  };
}
