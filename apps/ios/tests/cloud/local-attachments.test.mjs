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
