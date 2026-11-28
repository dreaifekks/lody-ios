import assert from 'node:assert/strict';
import { test } from 'node:test';
import { build } from 'esbuild';
import { Flock } from '@loro-dev/flock-wasm/base64';
import { LoroDoc } from 'loro-crdt/base64';
const bundle = await build({
  stdin: {
    contents: `export * from './packages/cloud-runtime/src/runtime/prompt-shortcuts.ts'; export * from './packages/cloud-runtime/src/protocol/prompt-shortcuts/compiler.ts'; export * from './packages/cloud-runtime/src/protocol/prompt-shortcuts/document.ts'; export * from './packages/cloud-runtime/src/protocol/prompt-shortcuts/catalog.ts'; export * from './packages/cloud-runtime/src/frames.ts'; export { forgetSettings } from './packages/cloud-runtime/src/runtime/settings.ts';`,
    resolveDir: new URL('../../../../', import.meta.url).pathname,
  },
  bundle: true,
  format: 'esm',
  platform: 'browser',
  write: false,
  plugins: [
    {
      name: 'streams',
      setup(b) {
        b.onResolve({ filter: /^@loro-dev\/streams-client$/ }, () => ({
          path: 'mock',
          namespace: 'test',
        }));
        b.onLoad({ filter: /.*/, namespace: 'test' }, () => ({
          contents:
            'export class StreamsClient {constructor(args){return new globalThis.__shortcutClient(args)}}',
        }));
      },
    },
  ],
});
const {
  forgetShortcuts,
  listedShortcuts,
  promptShortcuts,
  shortcutAccess,
  expandShortcuts,
  parsePromptShortcut,
  PromptShortcutDocument,
  PromptShortcutCatalog,
  encodeFrame,
  forgetSettings,
} = await import(
  `data:text/javascript;base64,${Buffer.from(bundle.outputFiles[0].text).toString('base64')}`
);
const value = {
  v: 1,
  id: 'review',
  workspaceId: 'w',
  ownerUserId: 'owner',
  name: 'Review',
  slug: 'review',
  prompt: 'Review $literal /review',
  scope: {},
  mentions: [],
  revision: 'r1',
  createdAt: 1,
  updatedAt: 1,
};
const entry = (() => {
  const { prompt, mentions, ...rest } = value;
  return { ...rest, bodyDocId: 'body', dependencySummary: [] };
})();
const workspaceGrant = async () => ({
  token: 'workspace-token',
  gatewayBaseUrl: 'https://example.com',
});

test('validates byte limits, UTF-16 mention ranges, legacy visibility stripping and immutable coherent revisions', () => {
  assert.deepEqual(
    parsePromptShortcut({ ...value, visibility: 'private' }),
    value,
  );
  assert.throws(() =>
    parsePromptShortcut({ ...value, prompt: '中'.repeat(90000) }),
  );
  assert.throws(
    () =>
      parsePromptShortcut({
        ...value,
        prompt: '😀',
        mentions: [
          {
            start: 1,
            end: 2,
            label: 'x',
            target: { kind: 'agent_role', agentRoleId: 'role' },
          },
        ],
      }),
    /Ranges/,
  );
  const doc = new PromptShortcutDocument(new LoroDoc());
  doc.save(value, []);
  assert.equal(doc.read().prompt, value.prompt);
  assert.throws(
    () => doc.save({ ...value, prompt: 'Changed' }, []),
    /revision id/,
  );
  doc.save({ ...value, revision: 'r2', prompt: 'Next' }, ['r1']);
  assert.throws(
    () => doc.save({ ...value, revision: 'r3' }, ['r1']),
    /changed/,
  );
  assert.equal(doc.read().prompt, 'Next');
});

test('slash expansion reads fresh bodies once and never interprets inserted text', async () => {
  const result = await expandShortcuts(
    'Before /shortcut:review after',
    async () => [entry],
    async () => value,
    async (text) => text.replace('$literal', 'BAD'),
  );
  assert.equal(result, 'Before Review $literal /review after');
  await assert.rejects(
    expandShortcuts(
      '/shortcut:review',
      async () => [entry, { ...entry, id: 'other' }],
      async () => value,
    ),
    /unavailable/,
  );
  await assert.rejects(
    expandShortcuts(
      '/shortcut:review',
      async () => [entry],
      async () => {
        throw new Error('revoked');
      },
    ),
    /shortcut_unavailable/,
  );
  await assert.rejects(
    expandShortcuts(
      '/shortcut:review',
      async () => [],
      async () => {
        throw new Error('must not read');
      },
    ),
    /unavailable/,
  );
  assert.equal(
    await expandShortcuts(
      '/help',
      async () => {
        throw new Error('unreachable');
      },
      async () => value,
    ),
    '/help',
  );
  await assert.rejects(
    expandShortcuts(
      '/shortcut:review',
      async () => [{ ...entry, scope: { machineId: 'm' } }],
      async () => value,
    ),
    /unavailable/,
  );
});

test('workspace-scoped publication, in-place body updates, owner fences and explicit index repair', async () => {
  forgetShortcuts();
  forgetSettings();
  const streams = new Map();
  let writes = 0,
    failIndex = false;
  globalThis.__shortcutClient = class {
    constructor({ url }) {
      this.id = decodeURIComponent(url.split('/').at(-1));
    }
    async create() {
      if (!streams.has(this.id)) streams.set(this.id, { updates: [] });
      return { ok: true, result: {} };
    }
    async bootstrap() {
      const data = streams.get(this.id);
      if (!data) return { ok: false, result: { code: 'not_found' } };
      return {
        ok: true,
        result: {
          snapshotOffset: '-1',
          updates: data.updates.map((body) => ({ body })),
          nextOffset: String(data.updates.length),
          upToDate: true,
        },
      };
    }
    async readOnce() {
      return { ok: true, result: { nextOffset: '1', upToDate: true } };
    }
    async append({ part }) {
      writes++;
      if (failIndex && this.id === 'w:shortcut-index') {
        failIndex = false;
        return { ok: false, result: { code: 'network' } };
      }
      streams.get(this.id).updates.push(part.body);
      return { ok: true, result: {} };
    }
  };
  const req = {
    workspaceId: 'w',
    action: 'save',
    entry: null,
    value,
    bodyDocId: 'body',
  };
  failIndex = true;
  await assert.rejects(
    promptShortcuts(req, 'owner', workspaceGrant, AbortSignal.timeout(5000)),
    /unknown/,
  );
  assert.ok(streams.has('w:shortcut:body'), 'body written to workspace stream');
  const previous = writes;
  const saved = await promptShortcuts(
    req,
    'owner',
    workspaceGrant,
    AbortSignal.timeout(5000),
  );
  assert.equal(writes, previous + 1, 'explicit retry repairs only the index');
  const access = shortcutAccess(
    'w',
    'owner',
    workspaceGrant,
    AbortSignal.timeout(5000),
  );
  assert.equal((await access.list()).length, 1);
  assert.equal((await access.read(saved)).prompt, value.prompt);
  await assert.rejects(
    promptShortcuts(
      { ...req, value: { ...value, ownerUserId: 'another' } },
      'owner',
      workspaceGrant,
      AbortSignal.timeout(5000),
    ),
    /invalid/,
  );
  // Rotating bodyDocId on edit is rejected; edits update `{workspaceId}:shortcut:{bodyDocId}` in place.
  await assert.rejects(
    promptShortcuts(
      {
        ...req,
        entry: saved,
        bodyDocId: 'body-rotated',
        value: {
          ...value,
          revision: 'r2',
          prompt: 'Updated review',
          updatedAt: 2,
        },
      },
      'owner',
      workspaceGrant,
      AbortSignal.timeout(5000),
    ),
    /invalid/,
  );
  const edited = await promptShortcuts(
    {
      ...req,
      entry: saved,
      bodyDocId: 'body',
      value: {
        ...value,
        revision: 'r2',
        prompt: 'Updated review',
        updatedAt: 2,
      },
    },
    'owner',
    workspaceGrant,
    AbortSignal.timeout(5000),
  );
  assert.equal(edited.bodyDocId, 'body');
  assert.equal((await access.read(edited)).prompt, 'Updated review');
  await assert.rejects(access.read(saved, true), /changed/);
});

test('a composer choice reads the body against the listing it showed, without re-reading the index', async () => {
  forgetShortcuts();
  forgetSettings();
  const body = new LoroDoc();
  new PromptShortcutDocument(body).save(value, []);
  const index = new Flock('fixture-ws-index');
  new PromptShortcutCatalog(index).put(entry);
  const parts = new Map([
    [
      'w:shortcut-index',
      [new TextEncoder().encode(JSON.stringify(index.exportJson()))],
    ],
    ['w:shortcut:body', [body.export({ mode: 'snapshot' })]],
  ]);
  const reads = [];
  globalThis.__shortcutClient = class {
    constructor({ url }) {
      this.id = decodeURIComponent(url.split('/').at(-1));
    }
    async bootstrap() {
      reads.push(this.id);
      const streamParts = parts.get(this.id);
      if (!streamParts) return { ok: false, result: { code: 'not_found' } };
      return {
        ok: true,
        result: {
          snapshotOffset: '-1',
          updates: streamParts.map((bytes) => ({ body: encodeFrame(bytes) })),
          nextOffset: '1',
          upToDate: true,
        },
      };
    }
    async readOnce() {
      reads.push(this.id);
      return { ok: true, result: { nextOffset: '1', upToDate: true } };
    }
  };
  const select = (id) =>
    promptShortcuts(
      { workspaceId: 'w', action: 'select', id },
      'owner',
      workspaceGrant,
      AbortSignal.timeout(5000),
    );
  const listing = await listedShortcuts('w', 'owner', workspaceGrant);
  assert.deepEqual(listing.entries, [entry]);
  assert.equal((await select('review')).prompt, value.prompt);
  const before = reads.length;
  assert.equal((await select('review')).prompt, value.prompt);
  assert.equal(
    reads.length,
    before,
    'a listed, already read body needs no stream read',
  );
  assert.ok(
    !reads.slice(1).includes('w:shortcut-index'),
    'choosing never re-reads the index the listing came from',
  );
  await assert.rejects(select('missing'), /shortcut_changed/);
});
