import test from 'node:test';
import assert from 'node:assert/strict';
import vm from 'node:vm';
import { build } from 'esbuild';

const bundle = await build({
  entryPoints: [
    new URL(
      '../../../../packages/cloud-runtime/src/runtime/machine-rpc.ts',
      import.meta.url,
    ).pathname,
  ],
  bundle: true,
  write: false,
  format: 'iife',
  globalName: 'rpc',
  plugins: [
    {
      name: 'machine-rpc-client',
      setup(builder) {
        builder.onResolve({ filter: /^\.\/session$/ }, () => ({
          path: 'session',
          namespace: 'fixture',
        }));
        builder.onLoad({ filter: /.*/, namespace: 'fixture' }, () => ({
          contents:
            'export const clientFor = (...args) => globalThis.clientFor(...args);',
        }));
      },
    },
  ],
});
const load = (context) =>
  vm.runInNewContext(bundle.outputFiles[0].text + ';rpc.machineRpc;', context);

test('capability RPC waits past progress frames for the final result', async () => {
  let id,
    envelope,
    reads = 0;
  const progress = [];
  const context = {
    crypto,
    Date,
    TextDecoder,
    clientFor: async (stream) =>
      stream.includes(':rpc:req:')
        ? {
            append: async (value) => {
              envelope = JSON.parse(value.part.body);
              id = envelope.id;
              return { ok: true };
            },
          }
        : {
            create: async () => ({ ok: true }),
            readOnce: async () => {
              reads++;
              const result =
                reads === 1
                  ? { type: 'machine/acp-binary-progress' }
                  : {
                      type: 'machine/acp-capabilities-refresh_response',
                      success: true,
                    };
              return {
                ok: true,
                result: {
                  nextOffset: String(reads),
                  payload: {
                    body: new TextEncoder().encode(
                      JSON.stringify({ id, result }),
                    ),
                  },
                },
              };
            },
          },
  };
  const call = load(context);
  const reply = await call(
    'w',
    'm',
    'machine/acp-capabilities-refresh',
    { configId: 'g' },
    () => {},
    new AbortController().signal,
    (value) => progress.push(value),
    120000,
  );
  assert.equal(reads, 2);
  assert.equal(reply.result.success, true);
  assert.equal(envelope.expiresAt - envelope.sentAt, 120000);
  assert.equal(progress[0].type, 'machine/acp-binary-progress');
});

test('a cancelled provider request cannot append after late authorization/client construction', async () => {
  let releaseClient, clientRequested;
  const ready = new Promise((resolve) => {
    clientRequested = resolve;
  });
  const delayed = new Promise((resolve) => {
    releaseClient = resolve;
  });
  const outbound = [];
  const context = {
    crypto,
    Date,
    TextDecoder,
    clientFor: async (stream) => {
      if (stream.includes(':rpc:req:')) {
        clientRequested();
        return delayed;
      }
      return { create: async () => ({ ok: true }) };
    },
  };
  const call = load(context);
  const controller = new AbortController();
  const result = call(
    'w',
    'm',
    'machine/acp-authenticate',
    { action: 'cancel' },
    () => {},
    controller.signal,
  );
  await ready;
  controller.abort();
  releaseClient({
    append: async (value) => {
      outbound.push(value);
      return { ok: true };
    },
  });
  await assert.rejects(result, { name: 'AbortError' });
  assert.deepEqual(outbound, []);
});
