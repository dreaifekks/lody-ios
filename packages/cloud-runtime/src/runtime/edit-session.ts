import {
  appendMessageQuotes,
  type MessageQuote,
} from '../protocol/message-quotes.ts';

type RecordValue = Record<string, any>;

function inputBlock(item: RecordValue): RecordValue {
  const fields: Record<string, string[]> = {
    image: [
      'imageId',
      'transport',
      'machineId',
      'localImageId',
      'mimeType',
      'fileName',
      'sizeBytes',
      'width',
      'height',
      'storageSessionId',
    ],
    file: [
      'fileId',
      'fileName',
      'mimeType',
      'sizeBytes',
      'sha256',
      'textPreview',
      'sourcePath',
      'transport',
      'machineId',
      'uploadedAt',
      'storageSessionId',
    ],
    local_attachment: [
      'machineId',
      'path',
      'kind',
      'fileName',
      'mimeType',
      'sizeBytes',
    ],
    comment_reference: [
      'source',
      'path',
      'lineNumber',
      'side',
      'commentBody',
      'authorName',
      'authorImage',
      'replies',
      'turnId',
      'mode',
      'threadId',
      'githubThreadId',
    ],
    visual_annotation_reference: [
      'source',
      'commentId',
      'turnId',
      'body',
      'authorName',
      'status',
      'anchor',
    ],
  };
  return Object.fromEntries(
    ['type', ...fields[item.type]]
      .filter((key) => item[key] != null)
      .map((key) => [key, item[key]]),
  );
}

/**
 * An attachment block native code produced. Cloud files live in R2; on a LAN
 * the machine that runs the session keeps them (`transport: 'local'`).
 */
export function isAttachmentBlock(block: RecordValue): boolean {
  if (!block || !['image', 'file', 'local_attachment'].includes(block.type))
    return false;
  if (block.type === 'local_attachment') {
    return (
      typeof block.machineId === 'string' &&
      block.machineId.length > 0 &&
      typeof block.path === 'string' &&
      block.path.trim().length > 0 &&
      (block.kind === 'file' || block.kind === 'image') &&
      typeof block.fileName === 'string' &&
      block.fileName.trim().length > 0 &&
      typeof block.mimeType === 'string' &&
      block.mimeType.trim().length > 0 &&
      Number.isInteger(block.sizeBytes) &&
      block.sizeBytes >= 0
    );
  }
  const id =
    block.type === 'image'
      ? (block.imageId ?? block.localImageId)
      : block.fileId;
  if (
    typeof id !== 'string' ||
    !id ||
    typeof block.mimeType !== 'string' ||
    !Number.isInteger(block.sizeBytes) ||
    block.sizeBytes <= 0
  )
    return false;
  if (block.type === 'image') return true;
  const stored =
    block.transport === 'r2' ||
    (block.transport === 'local' &&
      typeof block.machineId === 'string' &&
      block.machineId.length > 0);
  return (
    stored &&
    typeof block.sha256 === 'string' &&
    typeof block.fileName === 'string' &&
    typeof block.textPreview === 'boolean' &&
    typeof block.uploadedAt === 'number'
  );
}

/** LAN images are local file blocks; enforce one combined budget, including edits. */
export function validAttachmentBlocks(
  blocks: unknown,
): blocks is RecordValue[] {
  if (
    !Array.isArray(blocks) ||
    blocks.some((block) => !isAttachmentBlock(block))
  )
    return false;
  const isLocal = blocks.some(
    (block) => block.transport === 'local' || block.type === 'local_attachment',
  );
  const limit = isLocal ? 8 : 16;
  const imageCount = blocks.filter(
    (block) =>
      block.type === 'image' ||
      (block.type === 'local_attachment' && block.kind === 'image'),
  ).length;
  const fileCount = blocks.filter(
    (block) =>
      block.type === 'file' ||
      (block.type === 'local_attachment' && block.kind === 'file'),
  ).length;
  return blocks.length <= limit && imageCount <= 8 && fileCount <= 8;
}

export function editableUserTurn(
  history: RecordValue[],
  meta: RecordValue,
  capability?: RecordValue,
) {
  if (
    meta.isArchived ||
    meta.cliType !== 'builtin' ||
    !['codex', 'claude'].includes(meta.agentType)
  )
    return;
  const goal =
    history
      .flatMap((entry) => entry.items ?? [])
      .findLast((item) => item?.type === 'goal') ?? meta.latestGoal;
  if (goal?.status === 'active') return;
  const index = history.findLastIndex((entry) => entry.role === 'user');
  const turn = history[index];
  if (
    !turn ||
    ['pending_apply', 'delivery_unknown'].includes(turn.status) ||
    turn.inputConfig?._lodyDeliveryKind === 'steer'
  )
    return;
  for (let previous = index - 1; previous >= 0; previous--) {
    const entry = history[previous];
    if (entry.role === 'user') return;
    if (entry.role !== 'assistant') continue;
    if (
      entry.finished !== true ||
      typeof entry.acpTurnId !== 'string' ||
      !entry.acpTurnId ||
      capability?.provenance !== 'runtime' ||
      capability.sessionFork !== true
    )
      return;
    break;
  }
  return turn;
}

export type EditableAttachmentBlock =
  | (RecordValue & { type: 'image'; editId: string })
  | (RecordValue & { type: 'file'; editId: string })
  | (RecordValue & { type: 'local_attachment'; editId: string });

function rawAttachmentItems(list: unknown): RecordValue[] {
  if (!Array.isArray(list)) return [];
  return list.flatMap((item: RecordValue) => {
    if (!item || typeof item !== 'object') return [];
    if (item.type === 'image_group')
      return Array.isArray(item.images) ? item.images : [];
    if (
      item.type === 'image' ||
      item.type === 'file' ||
      item.type === 'local_attachment'
    )
      return [item];
    return [];
  });
}

function rawReferenceItems(list: unknown): RecordValue[] {
  if (!Array.isArray(list)) return [];
  return list.filter(
    (item: RecordValue) =>
      item &&
      typeof item === 'object' &&
      ['comment_reference', 'visual_annotation_reference'].includes(item.type),
  );
}

/**
 * Shared user-turn block view for transcript display, edit drafts and resends:
 * falls back to `inputConfig.inputBlocks` when `items` is absent/empty or
 * carries no attachments while `inputConfig.inputBlocks` does.
 */
export function userTurnItems(turn: RecordValue): RecordValue[] {
  const items = Array.isArray(turn?.items) ? turn.items : [];
  const blocks = Array.isArray(turn?.inputConfig?.inputBlocks)
    ? turn.inputConfig.inputBlocks
    : [];
  if (items.length === 0) return blocks;
  if (rawAttachmentItems(items).length > 0) return items;
  const fallbackAttachments = rawAttachmentItems(blocks);
  if (fallbackAttachments.length === 0) return items;
  return [...items, ...fallbackAttachments];
}

export function turnAttachmentItems(turn: RecordValue): RecordValue[] {
  const fromItems = rawAttachmentItems(turn?.items);
  if (fromItems.length > 0) return fromItems;
  return rawAttachmentItems(turn?.inputConfig?.inputBlocks);
}

export function editAttachments(turn: RecordValue): EditableAttachmentBlock[] {
  return turnAttachmentItems(turn).map((item: RecordValue, index: number) => ({
    ...inputBlock({ ...item, type: item.type ?? 'image' }),
    editId: `original:${index}`,
  })) as EditableAttachmentBlock[];
}

export function replacementInput(
  turn: RecordValue,
  text: string,
  retainedIds: string[],
  added: RecordValue[],
  quotes: readonly MessageQuote[] = [],
) {
  if (
    typeof text !== 'string' ||
    text.length > 32000 ||
    !Array.isArray(retainedIds) ||
    !Array.isArray(added)
  )
    throw new Error('invalid_message');
  const original = editAttachments(turn);
  if (added.some((item) => !isAttachmentBlock(item)))
    throw new Error('invalid_attachment');
  if (
    new Set(retainedIds).size !== retainedIds.length ||
    retainedIds.some((id) => !original.some((item) => item.editId === id))
  )
    throw new Error('invalid_attachment');
  const attachments = [
    ...original
      .filter((item) => retainedIds.includes(item.editId))
      .map(({ editId, ...item }) => item),
    ...added,
  ];
  if (!validAttachmentBlocks(attachments)) throw new Error('attachment_limit');
  // Restored quote cards follow the main text, as on a fresh send.
  const composed = appendMessageQuotes(text.trim(), [], quotes);
  if (!composed.text && !attachments.length) throw new Error('empty_message');
  const itemReferences = rawReferenceItems(turn.items);
  const references =
    itemReferences.length > 0
      ? itemReferences
      : rawReferenceItems(turn.inputConfig?.inputBlocks);
  return {
    ...turn.inputConfig,
    prompt: composed.text,
    inputBlocks: [
      ...(composed.text
        ? [
            {
              type: 'text',
              text: composed.text,
              ...(composed.spans.length ? { spans: composed.spans } : {}),
            },
          ]
        : []),
      ...attachments,
      ...references.map(inputBlock),
    ],
  };
}
