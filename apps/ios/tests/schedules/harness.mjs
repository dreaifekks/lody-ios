import { build } from 'esbuild';
import { createRequire } from 'node:module';
import { pathToFileURL } from 'node:url';

/**
 * Bundles the runtime's schedule repository and command mapping against an
 * in-memory Streams gateway (`globalThis.__scheduleStreams`, stream id →
 * appended parts). Loro is shared with the caller so documents can be read
 * back without crossing WASM instances.
 */
export async function loadSchedules({ proposals = false } = {}) {
  const require = createRequire(import.meta.url);
  const bundle = await build({
    stdin: {
      contents: `
        export * from './src/runtime/schedules.ts';
        export { draftInput, registerSchedules, ruleOf, scheduleMachine, triggerOf } from './src/runtime/handlers/schedules.ts';
        export { activeSessionStatuses } from './src/runtime/machine-presence.ts';
        export * from './src/runtime/session-live-status.ts';
        export * from './src/protocol/schedules.ts';
        export * from './src/protocol/proposals.ts';
        ${proposals ? "export { registerProposals, scheduleEditProposalActivityId } from './src/runtime/handlers/proposals.ts';" : ''}
      `,
      resolveDir: new URL(
        '../../../../packages/cloud-runtime/',
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
          // The open conversation's notices, from `globalThis.__notices` (key `entry/item`).
          b.onResolve({ filter: /^\.\.\/session$/ }, (args) =>
            args.importer.endsWith('handlers/proposals.ts')
              ? { path: 'session', namespace: 'test' }
              : undefined,
          );
          b.onResolve({ filter: /^\.\.\/machine-rpc$/ }, (args) =>
            args.importer.endsWith('handlers/schedules.ts')
              ? { path: 'machine-rpc', namespace: 'test' }
              : undefined,
          );
          b.onResolve({ filter: /^loro-crdt(\/base64)?$/ }, () => ({
            path: pathToFileURL(require.resolve('loro-crdt/base64')).href,
            external: true,
          }));
          b.onResolve({ filter: /^@loro-dev\/streams-crdt\/loro$/ }, () => ({
            path: 'streams-crdt-mock',
            namespace: 'test',
          }));
          b.onResolve({ filter: /^@loro-dev\/streams-client$/ }, () => ({
            path: 'mock',
            namespace: 'test',
          }));
          b.onLoad(
            { filter: /^streams-crdt-mock$/, namespace: 'test' },
            () => ({
              contents: `
              export const EphemeralStoreAdaptor = () => ({});
              export class EphemeralStreamCrdt {}
            `,
            }),
          );
          b.onLoad({ filter: /^machine-rpc$/, namespace: 'test' }, () => ({
            contents: `
              export async function machineRpc(...args) {
                if (!globalThis.__machineRpc) throw new Error('unexpected_machine_rpc');
                return globalThis.__machineRpc(...args);
              }
            `,
          }));
          b.onLoad({ filter: /^session$/, namespace: 'test' }, () => ({
            contents: `
              const key = (args) => args.entryId + '/' + args.itemId;
              export async function noticeAt(args) {
                return globalThis.__notices.get(key(args));
              }
              export async function writeNoticeMeta(args) {
                const notice = globalThis.__notices.get(key(args));
                if (!notice || notice.name !== args.name) throw new Error('proposal_unavailable');
                if (globalThis.__failNoticeWrite) {
                  globalThis.__failNoticeWrite = false;
                  throw new Error('upload_failed');
                }
                notice.meta = { ...notice.meta, ...args.patch };
              }
              export async function readyHistory() { return []; }
            `,
          }));
          b.onLoad({ filter: /^mock$/, namespace: 'test' }, () => ({
            contents: `export class StreamsClient {
              constructor({ url }) {
                this.id = decodeURIComponent(url.split('/ds/lody/')[1]);
              }
              get store() { return globalThis.__scheduleStreams; }
              async create() {
                if (!this.store.has(this.id)) this.store.set(this.id, []);
                return { ok: true, result: {} };
              }
              async bootstrap() {
                const parts = this.store.get(this.id);
                if (!parts) return { ok: false, result: { code: 'not_found' } };
                return { ok: true, result: {
                  snapshotOffset: '-1', snapshot: null,
                  updates: parts.map((body) => ({ body })),
                  nextOffset: String(parts.length), cursor: '', upToDate: true,
                } };
              }
              async readOnce() { throw new Error('unexpected read'); }
              async append({ part }) {
                const parts = this.store.get(this.id);
                if (!parts) return { ok: false, result: { code: 'not_found' } };
                parts.push(part.body);
                return { ok: true, result: {} };
              }
            }`,
          }));
        },
      },
    ],
  });
  return import(
    `data:text/javascript;base64,${Buffer.from(bundle.outputFiles[0].text).toString('base64')}`
  );
}

export const grant = async () => ({
  token: 't',
  gatewayBaseUrl: 'https://gateway.test',
});
