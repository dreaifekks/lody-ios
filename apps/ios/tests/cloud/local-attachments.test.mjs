import test from 'node:test';
import assert from 'node:assert/strict';
import {
  editAttachments,
  isAttachmentBlock,
  replacementInput,
  validAttachmentBlocks,
} from '../../../../packages/cloud-runtime/src/runtime/edit-session.ts';
import {
  migrateLegacyAntigravityModeId,
  migrateLegacyAntigravityModeOption,
  permissionModeFor,
  permissionTierOf,
} from '../../../../packages/cloud-runtime/src/protocol/capability.ts';
import {
  roleRunConfig,
  roleRunConfigApplied,
} from '../../../../packages/cloud-runtime/src/protocol/agent-roles.ts';

test('edit-session preserves local_attachment and transport:local localImageId blocks', () => {
  const localAttachment = {
    type: 'local_attachment',
    machineId: 'mac-mini',
    path: '/Users/dev/report.md',
    kind: 'file',
    fileName: 'report.md',
    mimeType: 'text/markdown',
    sizeBytes: 256,
  };
  const localImage = {
    type: 'image',
    imageId: '11111111-2222-4333-8444-555555555555',
    transport: 'local',
    machineId: 'mac-mini',
    localImageId: '11111111-2222-4333-8444-555555555555',
    mimeType: 'image/png',
    fileName: 'shot.png',
    sizeBytes: 1024,
  };
  assert.equal(isAttachmentBlock(localAttachment), true);
  assert.equal(isAttachmentBlock(localImage), true);
  assert.equal(validAttachmentBlocks([localAttachment, localImage]), true);
  assert.equal(
    validAttachmentBlocks(Array.from({ length: 9 }, () => localAttachment)),
    false,
  );

  const turn = {
    items: [localAttachment, localImage, { type: 'text', text: 'Old text' }],
    inputConfig: { cliType: 'builtin', agentType: 'codex' },
  };
  const originals = editAttachments(turn);
  assert.equal(originals.length, 2);
  assert.equal(originals[0].type, 'local_attachment');
  assert.equal(originals[0].path, '/Users/dev/report.md');
  assert.equal(originals[1].transport, 'local');
  assert.equal(originals[1].localImageId, localImage.localImageId);

  const replacement = replacementInput(
    turn,
    'Updated prompt',
    ['original:0', 'original:1'],
    [],
  );
  assert.deepEqual(replacement.inputBlocks[1], localAttachment);
  assert.deepEqual(replacement.inputBlocks[2], localImage);

  // Turns whose attachments live only in inputConfig.inputBlocks (either with
  // items absent or with text-only items) retain them across edit and resend.
  for (const inputBlocksOnlyTurn of [
    {
      inputConfig: {
        cliType: 'builtin',
        agentType: 'codex',
        inputBlocks: [
          { type: 'text', text: 'From inputBlocks only' },
          localAttachment,
          localImage,
        ],
      },
    },
    {
      items: [{ type: 'text', text: 'Text-only items' }],
      inputConfig: {
        cliType: 'builtin',
        agentType: 'codex',
        inputBlocks: [
          { type: 'text', text: 'Text-only items' },
          localAttachment,
          localImage,
        ],
      },
    },
  ]) {
    const extracted = editAttachments(inputBlocksOnlyTurn);
    assert.equal(extracted.length, 2);
    assert.equal(extracted[0].type, 'local_attachment');
    assert.equal(extracted[1].localImageId, localImage.localImageId);
    const rebuilt = replacementInput(
      inputBlocksOnlyTurn,
      'Edited text',
      ['original:0', 'original:1'],
      [],
    );
    assert.deepEqual(rebuilt.inputBlocks, [
      { type: 'text', text: 'Edited text' },
      localAttachment,
      localImage,
    ]);
  }

  // Mixed records: `items` has an image while `inputConfig.inputBlocks` has a
  // `local_attachment` (plus a duplicate of that image). Both are preserved
  // without duplication and `inputBlocks` wins for overlapping identities.
  const cloudImageInItems = {
    type: 'image',
    imageId: 'cloud-img-1',
    mimeType: 'image/png',
    fileName: 'diagram.png',
    sizeBytes: 512,
  };
  const mixedTurn = {
    items: [
      { type: 'text', text: 'Mixed attachments' },
      cloudImageInItems,
      {
        type: 'image',
        imageId: localImage.localImageId,
        mimeType: 'image/png',
        sizeBytes: 1024,
      },
    ],
    inputConfig: {
      cliType: 'builtin',
      agentType: 'codex',
      inputBlocks: [
        { type: 'text', text: 'Mixed attachments' },
        localAttachment,
        localImage,
      ],
    },
  };
  const mixedOriginals = editAttachments(mixedTurn);
  assert.equal(mixedOriginals.length, 3);
  assert.deepEqual(
    mixedOriginals.map((item) => [
      item.editId,
      item.type,
      item.path ?? item.localImageId ?? item.imageId,
    ]),
    [
      ['original:0', 'local_attachment', '/Users/dev/report.md'],
      ['original:1', 'image', localImage.localImageId],
      ['original:2', 'image', 'cloud-img-1'],
    ],
  );
  // Overlapping local image keeps rich `inputBlocks` transport/machine metadata.
  assert.equal(mixedOriginals[1].transport, 'local');
  assert.equal(mixedOriginals[1].machineId, 'mac-mini');
  const mixedRebuilt = replacementInput(
    mixedTurn,
    'Edited mixed',
    ['original:0', 'original:1', 'original:2'],
    [],
  );
  assert.deepEqual(mixedRebuilt.inputBlocks, [
    { type: 'text', text: 'Edited mixed' },
    localAttachment,
    localImage,
    cloudImageInItems,
  ]);
});

test('Antigravity mode migration and agy permission tiers', () => {
  assert.equal(migrateLegacyAntigravityModeId('auto_review'), 'auto');
  assert.equal(migrateLegacyAntigravityModeId('accept-edits'), 'accept-edits');
  assert.deepEqual(
    migrateLegacyAntigravityModeOption({ mode: 'auto_review', fast: true }),
    { mode: 'auto', fast: true },
  );

  assert.equal(permissionTierOf('accept-edits'), 'edit');
  assert.equal(permissionTierOf('acceptEdits'), 'edit');
  assert.equal(permissionTierOf('agent'), 'edit');
  assert.equal(permissionTierOf('dontAsk'), 'ask');
  assert.equal(permissionTierOf('yolo'), 'full');
  assert.equal(permissionTierOf('auto'), 'auto');
  assert.equal(permissionTierOf('auto_review'), 'auto');
  assert.equal(permissionTierOf('default'), 'ask');
  assert.equal(permissionTierOf('plan'), 'ask');

  const agyCapability = {
    machineId: 'm1',
    cliType: 'registry',
    agentType: 'antigravity-acp',
    models: [],
    modes: [
      { id: 'default', name: 'Default' },
      { id: 'accept-edits', name: 'Accept Edits' },
      { id: 'auto', name: 'Auto' },
      { id: 'yolo', name: 'YOLO' },
    ],
    reasoningEfforts: {},
    configOptions: [
      {
        id: 'mode',
        name: 'Mode',
        category: 'mode',
        type: 'select',
        currentValue: 'default',
        options: [
          { id: 'default', name: 'Default' },
          { id: 'accept-edits', name: 'Accept Edits' },
          { id: 'auto', name: 'Auto' },
          { id: 'yolo', name: 'YOLO' },
        ],
      },
    ],
  };
  assert.equal(
    permissionModeFor(agyCapability, {
      modeId: 'auto_review',
    })?.value,
    'auto',
  );
  assert.equal(
    permissionModeFor(
      { ...agyCapability, modes: [] },
      { configOptionValues: { mode: 'auto_review' } },
    )?.value,
    'auto',
  );

  const pinned = roleRunConfig({
    modeId: 'auto_review',
    configOptionValues: { mode: 'auto_review' },
  });
  assert.deepEqual(pinned, {
    modeId: 'auto',
    configOptionValues: { mode: 'auto' },
  });
  assert.equal(
    roleRunConfigApplied(pinned, {
      modeId: 'auto',
      configOptionValues: { mode: 'auto' },
    }),
    true,
  );
  assert.equal(
    roleRunConfigApplied(pinned, {
      modeId: 'auto_review',
      configOptionValues: { mode: 'auto_review' },
    }),
    true,
  );
});
