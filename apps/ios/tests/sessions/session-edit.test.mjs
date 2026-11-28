import test from 'node:test';
import assert from 'node:assert/strict';
import {
  editableUserTurn,
  isAttachmentBlock,
  replacementInput,
} from '../../../../packages/cloud-runtime/src/runtime/edit-session.ts';
import { openTestSession } from '../helpers.mjs';

const meta = { machineId: 'm1', cliType: 'builtin', agentType: 'codex' };
const original = {
  id: 'original',
  role: 'user',
  status: 'completed',
  finished: true,
  inputConfig: {
    modelId: 'original-model',
    configOptionValues: { fast: true },
  },
  items: [
    { type: 'text', text: 'Original prompt' },
    { type: 'image', imageId: 'image-1', mimeType: 'image/png', sizeBytes: 10 },
    {
      type: 'file',
      fileId: 'file-1',
      fileName: 'original.txt',
      mimeType: 'text/plain',
      sizeBytes: 8,
      transport: 'r2',
      sha256: 'digest',
      textPreview: true,
      uploadedAt: 1,
    },
  ],
};

test('edit eligibility fences history, automation and provider boundaries; attachment edits preserve configuration', () => {
  assert.equal(editableUserTurn([original], meta), original);
  assert.equal(
    editableUserTurn([original], { ...meta, autoReview: true }),
    original,
  );
  const preceding = {
    id: 'reply',
    role: 'assistant',
    finished: true,
    acpTurnId: 'provider-turn',
  };
  assert.equal(editableUserTurn([preceding, original], meta), undefined);
  assert.equal(
    editableUserTurn([preceding, original], meta, {
      provenance: 'runtime',
      sessionFork: true,
    }),
    original,
  );
  for (const invalid of [
    { isArchived: true },
    { agentType: 'grok' },
    { latestGoal: { status: 'active' } },
  ]) {
    assert.equal(
      editableUserTurn([original], { ...meta, ...invalid }),
      undefined,
    );
  }
  for (const status of ['pending_apply', 'delivery_unknown'])
    assert.equal(editableUserTurn([{ ...original, status }], meta), undefined);
  assert.equal(
    editableUserTurn(
      [{ ...original, inputConfig: { _lodyDeliveryKind: 'steer' } }],
      meta,
    ),
    undefined,
  );
  assert.equal(
    editableUserTurn([original, { ...original, id: 'newer' }], meta),
    undefined,
  );
  const added = {
    type: 'image',
    imageId: 'added',
    mimeType: 'image/png',
    sizeBytes: 12,
  };
  const input = replacementInput(original, 'Edited', ['original:1'], [added]);
  const historyWithMetadata = {
    ...original,
    items: original.items.map((item) => ({
      ...item,
      itemId: 'history-item',
      rev: 3,
    })),
  };
  assert.deepEqual(
    replacementInput(historyWithMetadata, 'Edited', ['original:1'], [added]),
    input,
    'history metadata must not invalidate strict input blocks and drop attachments',
  );
  assert.deepEqual(input.inputBlocks, [
    { type: 'text', text: 'Edited' },
    original.items[2],
    added,
  ]);
  assert.equal(input.modelId, 'original-model');
  assert.deepEqual(input.configOptionValues, { fast: true });
  assert.equal(
    replacementInput(original, '', ['original:0'], []).inputBlocks.length,
    1,
  );
  assert.throws(() => replacementInput(original, '', [], []));
  assert.throws(() => replacementInput(original, 'Edited', ['foreign-id'], []));
  assert.throws(() =>
    replacementInput(
      original,
      'Edited',
      [],
      [{ type: 'image', imageId: 'bad' }],
    ),
  );
  assert.equal(original.items.length, 3);
});

test('a LAN file is kept by the machine it names; R2 and LAN files carry the same digest fields', () => {
  const lanFile = {
    type: 'file',
    fileId: 'file-lan',
    fileName: 'photo.jpg',
    mimeType: 'image/jpeg',
    sizeBytes: 2048,
    sha256: 'a'.repeat(64),
    textPreview: false,
    transport: 'local',
    machineId: 'm1',
    uploadedAt: 1,
  };
  assert.equal(isAttachmentBlock(lanFile), true);
  assert.equal(isAttachmentBlock({ ...lanFile, machineId: '' }), false);
  assert.equal(isAttachmentBlock({ ...lanFile, machineId: undefined }), false);
  assert.equal(isAttachmentBlock({ ...lanFile, transport: 'blob' }), false);
  assert.equal(isAttachmentBlock({ ...lanFile, sha256: undefined }), false);
  assert.equal(
    isAttachmentBlock({ ...lanFile, transport: 'r2', machineId: undefined }),
    true,
  );

  const input = replacementInput(original, 'With a photo', [], [lanFile]);
  assert.deepEqual(
    input.inputBlocks.filter((block) => block.type === 'file'),
    [lanFile],
  );
  assert.throws(
    () =>
      replacementInput(
        original,
        'Unkept',
        [],
        [{ ...lanFile, machineId: undefined }],
      ),
    /invalid_attachment/,
  );
});

test('edit RPC leaves history server-owned, preserves failed drafts and never automatically replays uncertain writes', async () => {
  let result = {
    result: { success: false, error: { message: 'stale boundary' } },
  };
  const requests = [];
  const fixture = await openTestSession({
    onRpc: (request) => {
      requests.push(request);
      return result;
    },
  });
  try {
    fixture.server.getList('history').push(original);
    await fixture.pushUpdate();
    const base = {
      sessionId: 's1',
      userId: 'u1',
      expectedUserTurnId: 'original',
    };
    assert.equal(
      (await fixture.runtime.editSession({ ...base, action: 'read' }, meta))
        .state,
      'ready',
    );
    const args = {
      ...base,
      action: 'send',
      id: 'replacement',
      text: 'Changed',
      retainedIds: ['original:0'],
    };
    assert.equal(
      (await fixture.runtime.editSession(args, meta)).state,
      'not_sent',
    );
    assert.equal(requests[0].method, 'session/edit-and-resend');
    assert.equal(requests[0].params.expectedUserTurnId, 'original');
    assert.equal(requests[0].params.replacementUserTurnId, 'replacement');
    assert.deepEqual(requests[0].params.inputConfig.inputBlocks, [
      { type: 'text', text: 'Changed' },
      original.items[1],
    ]);
    assert.deepEqual(fixture.server.toJSON().history, [original]);
    result = { error: { message: 'lost response' } };
    assert.equal(
      (await fixture.runtime.editSession(args, meta)).state,
      'unknown',
    );
    assert.equal(requests.length, 2);
    assert.equal(
      (
        await fixture.runtime.editSession(
          { ...base, action: 'read', id: 'replacement' },
          meta,
        )
      ).state,
      'ready',
    );
    assert.equal(requests.length, 2);
    fixture.server.getList('history').delete(0, 1);
    fixture.server.getList('history').push({ ...original, id: 'replacement' });
    await fixture.pushUpdate();
    assert.equal(
      (
        await fixture.runtime.editSession(
          { ...base, action: 'read', id: 'replacement' },
          meta,
        )
      ).state,
      'accepted',
    );
    assert.equal(
      (await fixture.runtime.editSession({ ...args, id: 'another' }, meta))
        .state,
      'not_sent',
    );
    assert.equal(requests.length, 2);
  } finally {
    fixture.close();
  }
});

test('editing a Roost session uses its owner history and the edit RPC', async () => {
  const requests = [];
  const fixture = await openTestSession({
    target: {
      backend: 'roost',
      machineId: 'm1',
      acceptsInput: true,
      dispatchesInput: true,
    },
    async onRpc(request, runtime) {
      if (request.method === 'session/edit-and-resend') {
        requests.push(request);
        return { result: { success: true } };
      }
      return {
        result: await runtime.sealPayload('s1', {
          type: 'session/history-read_response',
          sessionId: 's1',
          success: true,
          historyRevision: 1,
          historyCount: 1,
          result: {
            checkpoint: 'c1',
            startPosition: 0,
            totalCount: 1,
            rows: [{ position: 0, state: 'ready', turnId: 'original' }],
            hasMoreOlder: false,
            cursor: null,
          },
          pageTurns: [{ ...original, timestamp: '2026-01-01' }],
        }),
      };
    },
  });
  try {
    const base = {
      sessionId: 's1',
      userId: 'u1',
      expectedUserTurnId: 'original',
    };
    assert.equal(
      (await fixture.runtime.editSession({ ...base, action: 'read' }, meta))
        .state,
      'ready',
    );
    assert.equal(
      (
        await fixture.runtime.editSession(
          {
            ...base,
            action: 'send',
            id: 'replacement',
            text: 'Changed',
            retainedIds: [],
          },
          meta,
        )
      ).state,
      'accepted',
    );
    assert.equal(requests[0].params.expectedUserTurnId, 'original');
    assert.deepEqual(fixture.server.toJSON().history ?? [], []);
  } finally {
    fixture.close();
  }
});

test('an accepted edit and resend counts as a send; a refused or uncertain one does not', async () => {
  let result = { result: { success: false, error: { message: 'stale' } } };
  const fixture = await openTestSession({ onRpc: () => result });
  const sends = [];
  fixture.runtime.setSessionSendObserver((id) => sends.push(id));
  try {
    fixture.server.getList('history').push(original);
    await fixture.pushUpdate();
    const args = {
      sessionId: 's1',
      userId: 'u1',
      expectedUserTurnId: 'original',
      action: 'send',
      text: 'Changed',
      retainedIds: ['original:0'],
    };
    assert.equal(
      (await fixture.runtime.editSession({ ...args, id: 'r1' }, meta)).state,
      'not_sent',
    );
    result = { error: { message: 'lost response' } };
    assert.equal(
      (await fixture.runtime.editSession({ ...args, id: 'r2' }, meta)).state,
      'unknown',
    );
    assert.deepEqual(sends, []);
    result = { result: { success: true } };
    assert.equal(
      (await fixture.runtime.editSession({ ...args, id: 'r3' }, meta)).state,
      'accepted',
    );
    assert.deepEqual(sends, ['s1']);
  } finally {
    fixture.runtime.setSessionSendObserver(() => {});
    fixture.close();
  }
});

test('editing and resending preserves local_attachment and local image stored only in inputConfig.inputBlocks', async () => {
  const requests = [];
  const fixture = await openTestSession({
    onRpc: (request) => {
      requests.push(request);
      return { result: { success: true } };
    },
  });
  const localAttachment = {
    type: 'local_attachment',
    machineId: 'm1',
    path: '/Users/dev/report.md',
    kind: 'file',
    fileName: 'report.md',
    mimeType: 'text/markdown',
    sizeBytes: 128,
  };
  const localImage = {
    type: 'image',
    imageId: '33333333-4444-4555-8666-777777777777',
    transport: 'local',
    machineId: 'm1',
    localImageId: '33333333-4444-4555-8666-777777777777',
    mimeType: 'image/png',
    fileName: 'paste.png',
    sizeBytes: 640,
  };
  const turnOnlyInInputBlocks = {
    id: 'blocks-only',
    role: 'user',
    status: 'handled',
    inputConfig: {
      cliType: 'builtin',
      agentType: 'codex',
      prompt: 'Original text',
      inputBlocks: [
        { type: 'text', text: 'Original text' },
        localAttachment,
        localImage,
      ],
    },
  };
  try {
    fixture.server.getList('history').push(turnOnlyInInputBlocks);
    await fixture.pushUpdate();
    const read = await fixture.runtime.editSession(
      {
        sessionId: 's1',
        userId: 'u1',
        expectedUserTurnId: 'blocks-only',
        action: 'read',
      },
      meta,
    );
    assert.equal(read.state, 'ready');
    assert.equal(read.text, 'Original text');
    assert.deepEqual(
      read.attachments.map((item) => [item.editId, item.type]),
      [
        ['original:0', 'local_attachment'],
        ['original:1', 'image'],
      ],
    );
    const resent = await fixture.runtime.editSession(
      {
        sessionId: 's1',
        userId: 'u1',
        expectedUserTurnId: 'blocks-only',
        action: 'send',
        id: 'blocks-only-edited',
        text: 'Updated text',
        retainedIds: ['original:0', 'original:1'],
      },
      meta,
    );
    assert.equal(resent.state, 'accepted');
    assert.deepEqual(requests[0].params.inputConfig.inputBlocks, [
      { type: 'text', text: 'Updated text' },
      localAttachment,
      localImage,
    ]);
  } finally {
    fixture.close();
  }
});

test('editing and resending merges mixed attachments across items and inputConfig.inputBlocks without duplication', async () => {
  const requests = [];
  const fixture = await openTestSession({
    onRpc: (request) => {
      requests.push(request);
      return { result: { success: true } };
    },
  });
  const imageInItems = {
    type: 'image',
    imageId: 'img-in-items',
    mimeType: 'image/png',
    fileName: 'shot.png',
    sizeBytes: 320,
  };
  const localAttachmentInBlocks = {
    type: 'local_attachment',
    machineId: 'm1',
    path: '/Users/dev/mixed.pdf',
    kind: 'file',
    fileName: 'mixed.pdf',
    mimeType: 'application/pdf',
    sizeBytes: 512,
  };
  const sharedLocalImage = {
    type: 'image',
    imageId: '44444444-5555-4666-8777-888888888888',
    transport: 'local',
    machineId: 'm1',
    localImageId: '44444444-5555-4666-8777-888888888888',
    mimeType: 'image/png',
    fileName: 'dup.png',
    sizeBytes: 400,
  };
  const mixedTurn = {
    id: 'mixed-turn',
    role: 'user',
    status: 'handled',
    items: [
      { type: 'text', text: 'Mixed original' },
      imageInItems,
      {
        type: 'image',
        imageId: sharedLocalImage.localImageId,
        mimeType: 'image/png',
        sizeBytes: 400,
      },
    ],
    inputConfig: {
      cliType: 'builtin',
      agentType: 'codex',
      prompt: 'Mixed original',
      inputBlocks: [
        { type: 'text', text: 'Mixed original' },
        localAttachmentInBlocks,
        sharedLocalImage,
      ],
    },
  };
  try {
    fixture.server.getList('history').push(mixedTurn);
    await fixture.pushUpdate();
    const read = await fixture.runtime.editSession(
      {
        sessionId: 's1',
        userId: 'u1',
        expectedUserTurnId: 'mixed-turn',
        action: 'read',
      },
      meta,
    );
    assert.equal(read.state, 'ready');
    assert.equal(read.text, 'Mixed original');
    assert.deepEqual(
      read.attachments.map((item) => [
        item.editId,
        item.type,
        item.path ?? item.localImageId ?? item.imageId,
      ]),
      [
        ['original:0', 'local_attachment', '/Users/dev/mixed.pdf'],
        ['original:1', 'image', sharedLocalImage.localImageId],
        ['original:2', 'image', 'img-in-items'],
      ],
    );
    const resent = await fixture.runtime.editSession(
      {
        sessionId: 's1',
        userId: 'u1',
        expectedUserTurnId: 'mixed-turn',
        action: 'send',
        id: 'mixed-turn-edited',
        text: 'Mixed updated',
        retainedIds: ['original:0', 'original:1', 'original:2'],
      },
      meta,
    );
    assert.equal(resent.state, 'accepted');
    assert.deepEqual(requests[0].params.inputConfig.inputBlocks, [
      { type: 'text', text: 'Mixed updated' },
      localAttachmentInBlocks,
      sharedLocalImage,
      imageInItems,
    ]);
  } finally {
    fixture.close();
  }
});
