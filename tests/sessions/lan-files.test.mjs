import test from 'node:test';
import assert from 'node:assert/strict';
import {
  editAttachments,
  replacementInput,
  validAttachmentBlocks,
} from '../../packages/cloud-runtime/src/runtime/edit-session.ts';

const local = (id, mimeType = 'text/plain') => ({
  type: 'file',
  fileId: id,
  fileName: id + (mimeType === 'image/jpeg' ? '.jpg' : '.txt'),
  mimeType,
  sizeBytes: 32,
  transport: 'local',
  machineId: 'desk',
  sha256: 'a'.repeat(64),
  textPreview: mimeType === 'text/plain',
  uploadedAt: 1,
  storageSessionId: 'kept-session',
});
const cloudImage = (id) => ({
  type: 'image',
  imageId: id,
  mimeType: 'image/png',
  sizeBytes: 32,
});

test('LAN has one eight-attachment budget including pictures and mixed retained images; Cloud keeps its existing budget', () => {
  const eight = Array.from({ length: 8 }, (_, i) =>
    local('file-' + i, i % 2 ? 'image/jpeg' : 'text/plain'),
  );
  assert.equal(validAttachmentBlocks(eight), true);
  assert.equal(validAttachmentBlocks([...eight, local('ninth')]), false);
  assert.equal(
    validAttachmentBlocks([...eight, cloudImage('legacy-image')]),
    false,
  );
  assert.equal(
    validAttachmentBlocks([
      ...eight.map((block) => ({ ...block, transport: 'r2' })),
      ...Array.from({ length: 8 }, (_, i) => cloudImage('cloud-' + i)),
    ]),
    true,
  );
  for (const bad of [
    null,
    {},
    [null],
    [{ ...local('foreign'), machineId: '' }],
  ])
    assert.equal(validAttachmentBlocks(bad), false);
});

test('editing retained LAN files and images preserves the member, storage session and digest; a failed ninth attachment leaves the original intact', () => {
  const files = Array.from({ length: 8 }, (_, i) =>
    local('file-' + i, 'image/jpeg'),
  );
  const turn = {
    id: 'turn',
    items: [{ type: 'text', text: 'original' }, ...files],
    inputConfig: { modelId: 'model' },
  };
  const before = structuredClone(turn);
  const editable = editAttachments(turn);
  assert.equal(editable.length, 8);
  assert.deepEqual(editable[0], { ...files[0], editId: 'original:0' });
  const retained = editable.map((block) => block.editId);
  const replacement = replacementInput(turn, 'edited', retained.slice(1), [
    local('replacement'),
  ]);
  assert.equal(replacement.inputBlocks.length, 9);
  assert.equal(replacement.inputBlocks[1].machineId, 'desk');
  assert.equal(replacement.inputBlocks[1].storageSessionId, 'kept-session');
  assert.equal(replacement.inputBlocks[1].sha256, 'a'.repeat(64));
  assert.throws(
    () => replacementInput(turn, 'edited', retained, [cloudImage('ninth')]),
    /attachment_limit/,
  );
  assert.deepEqual(turn, before);
});
