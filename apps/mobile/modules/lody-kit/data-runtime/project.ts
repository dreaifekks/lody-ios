import {
  readTurnMetadata,
  type TurnMetadata,
} from '../../../src/cloud/turnMetadata.ts';
import { executionProjection, type SteerReceipt } from './execution';
import {
  isContainer,
  type ContainerID,
  type LoroDoc,
  type LoroList,
  type LoroMap,
  type LoroMovableList,
} from 'loro-crdt/base64';
import {
  parseQuestionMeta,
  samePermissionOutcome,
} from '../../../src/cloud/permissionQuestions.ts';
import type { QuestionMeta, TurnAuthor } from '../../../src/models/session.ts';
import { billableTurnCount } from './billing';
import { previewSummary } from './preview';

export type SystemNoticeMeta = {
  reason?: string;
  code?: string;
  message?: string;
};

export type ItemSummary =
  | {
      itemId: string;
      rev: number;
      type: 'system_notice';
      name: string;
      meta?: SystemNoticeMeta;
    }
  | { itemId: string; rev: number; type: 'text'; text: string }
  | { itemId: string; rev: number; type: 'thought'; text: string }
  | {
      itemId: string;
      rev: number;
      type: 'tool_call';
      kind: string;
      title: string;
      status: string;
      path?: string;
      added?: number;
      removed?: number;
      hasDetail: boolean;
      permission?: {
        requestId: string;
        pending: boolean;
        options?: { optionId: string; name: string; kind?: string }[];
        kind?: 'permission' | 'ask_user_question';
        questionMeta?: QuestionMeta;
      };
    }
  | {
      itemId: string;
      rev: number;
      type: 'plan';
      entries: { content: string; status: string; priority?: string }[];
    }
  | {
      itemId: string;
      rev: number;
      type: 'subagent_task';
      taskId: string;
      status: string;
      actor?: string;
      description?: string;
      lastToolName?: string;
      summary?: string;
      error?: string;
      isBackgrounded?: boolean;
      skipTranscript?: boolean;
      run?: SubagentRunSummary;
    }
  | { itemId: string; rev: number; type: string };

export type SubagentRunSummary = {
  state: string;
  modelId?: string;
  outputIncomplete?: boolean;
  cancel?: boolean;
  totalTokens?: number;
  toolCallCount?: number;
  contextUsagePercent?: number;
  /**
   * The session envelope carries only the latest step, with `itemCount` set to
   * the run's length; `subagentRun` reads every step when a sheet asks for it.
   */
  items: ItemSummary[];
  itemCount?: number;
};

export type EntrySummary = TurnMetadata & {
  id: string;
  rev: number;
  role: string;
  status: string;
  finished: boolean;
  author?: TurnAuthor;
  userTurnId?: string;
  executionId?: string;
  executionFinished?: boolean;
  steerCount?: number;
  delivery?: string;
  holdOpen?: boolean;
  timestamp?: string;
  startedAt?: number;
  endedAt?: number;
  permissionWaitMs?: number;
  modelInfo?: { modelId?: string; name?: string; thoughtLevel?: string };
  items: ItemSummary[];
};

export type Envelope = {
  v: 1;
  status: string;
  reason?: string;
  revision: number;
  billableTurnCount: number;
  awaitingUserSince?: number;
  preview?: { label: string; active: boolean };
  composer?: {
    modelId?: string;
    modeId?: string;
    effort?: string;
    configOptionValues?: Record<string, string | boolean>;
  };
  entries: EntrySummary[];
};

let revision = 0;
type CachedEntry = {
  /** The entry as `lightEntry` reads it, before steer links are applied. */
  base: any;
  value?: EntrySummary & { userTurnId?: string };
  /** What `value` was summarized with besides the entry itself. */
  index: number;
  link: string;
  pending: string;
};
type Projection = {
  revs: Map<string, { rev: number; fingerprint: string }>;
  /** History entries by container: a moved or re-inserted entry is a new one. */
  entries: Map<ContainerID, CachedEntry>;
  /** Entries a change reached since the last projection. */
  dirty: Set<ContainerID>;
  /** Every cached entry must be read again. */
  stale: boolean;
  unsubscribe: () => void;
};
const HISTORY = 'history';
const projections = new WeakMap<LoroDoc, Projection>();
function projectionFor(doc: LoroDoc) {
  const existing = projections.get(doc);
  if (existing) return existing;
  const history = doc.getList(HISTORY);
  const projection: Projection = {
    revs: new Map(),
    entries: new Map(),
    dirty: new Set(),
    stale: true,
    unsubscribe: () => {},
  };
  // Loro delivers a batch synchronously at the end of its commit or import, so
  // the paths index the history as it is now. Anything unexpected re-reads all.
  projection.unsubscribe = doc.subscribe((batch) => {
    if (batch.by === 'checkout') {
      projection.stale = true;
      return;
    }
    for (const event of batch.events) {
      const [root, index] = event.path;
      // Inserting or deleting entries changes only which containers are read.
      if (root !== HISTORY || event.path.length < 2) continue;
      const entry = typeof index === 'number' ? history.get(index) : undefined;
      if (isContainer(entry)) projection.dirty.add(entry.id);
      else projection.stale = true;
    }
  });
  projections.set(doc, projection);
  return projection;
}
/** Stops following a replica that is being discarded. */
export function releaseProjection(doc: LoroDoc) {
  projections.get(doc)?.unsubscribe();
  projections.delete(doc);
}

const plain = (value: unknown): any =>
  isContainer(value) ? (value as { toJSON(): unknown }).toJSON() : value;
// By kind rather than `instanceof`: a test may hold another Loro instance.
const kindOf = (value: unknown) =>
  isContainer(value) ? value.kind() : undefined;
const isMap = (value: unknown): value is LoroMap => kindOf(value) === 'Map';
const isList = (value: unknown): value is LoroList | LoroMovableList =>
  kindOf(value) === 'List' || kindOf(value) === 'MovableList';
// Provider payloads can hold whole files and images, and no summary reads them.
const PAYLOAD_KEYS = new Set(['_meta', 'rawInput', 'rawOutput']);
/** A content block keeps only what summaries read: diffs whole, others by type. */
function lightBlock(block: unknown) {
  if (isMap(block)) {
    const type = plain(block.get('type'));
    return type === 'diff' ? block.toJSON() : { type };
  }
  const value = block as any;
  return value?.type === 'diff' ? value : { type: value?.type };
}
function lightContent(value: unknown) {
  if (isList(value)) {
    const blocks = [];
    for (let i = 0; i < value.length; i++)
      blocks.push(lightBlock(value.get(i)));
    return blocks;
  }
  return Array.isArray(value) ? value.map(lightBlock) : plain(value);
}
function lightItems(value: unknown) {
  if (isList(value)) {
    const items = [];
    for (let i = 0; i < value.length; i++) items.push(lightItem(value.get(i)));
    return items;
  }
  return Array.isArray(value) ? value.map(lightItem) : plain(value);
}
function lightRun(run: unknown) {
  if (isMap(run)) {
    const value: Record<string, unknown> = {};
    for (const key of run.keys())
      value[key] =
        key === 'items' ? lightItems(run.get(key)) : plain(run.get(key));
    return value;
  }
  const value = run as any;
  return value && typeof value === 'object' && 'items' in value
    ? { ...value, items: lightItems(value.items) }
    : value;
}
/** An item without provider payloads or the bodies of its content blocks. */
function lightItem(item: unknown): any {
  if (isMap(item)) {
    const value: Record<string, unknown> = {};
    for (const key of item.keys()) {
      if (PAYLOAD_KEYS.has(key)) continue;
      const field = item.get(key);
      if (key === 'content') value.content = lightContent(field);
      else if (key === 'run') value.run = lightRun(field);
      else value[key] = plain(field);
    }
    return value;
  }
  if (!item || typeof item !== 'object' || Array.isArray(item)) return item;
  const value: Record<string, unknown> = {};
  for (const [key, field] of Object.entries(item)) {
    if (PAYLOAD_KEYS.has(key)) continue;
    if (key === 'content') value.content = lightContent(field);
    else if (key === 'run') value.run = lightRun(field);
    else value[key] = field;
  }
  return value;
}
/** One history entry as every projection reads it, at a fraction of `toJSON`. */
function lightEntry(entry: unknown): any {
  if (isMap(entry)) {
    const value: Record<string, unknown> = {};
    for (const key of entry.keys())
      value[key] =
        key === 'items' ? lightItems(entry.get(key)) : plain(entry.get(key));
    return value;
  }
  const value = entry as any;
  return value && typeof value === 'object' && 'items' in value
    ? { ...value, items: lightItems(value.items) }
    : value;
}
/**
 * Lody's `readMessageAuthor`, kept to what a bubble shows: a record of another
 * version or shape is no author at all, never a guessed one.
 */
function readAuthor(value: any): TurnAuthor | undefined {
  // Lody's labels: trimmed, 1 to 256 characters.
  const label = (text: unknown) => {
    const trimmed = typeof text === 'string' ? text.trim() : '';
    return trimmed && trimmed.length <= 256 ? trimmed : undefined;
  };
  if (value?.v !== 1) return undefined;
  if (value.kind === 'system') return { kind: 'system' };
  if (value.kind === 'human')
    return label(value.userId) ? { kind: 'human' } : undefined;
  const name = label(value.name);
  if (value.kind !== 'agent' || !name) return undefined;
  const author: TurnAuthor = { kind: 'agent', name };
  if (value.role !== undefined) {
    const roleName = label(value.role?.name);
    const instanceLabel = label(value.role?.instanceLabel);
    if (
      !roleName ||
      typeof value.role?.emoji !== 'string' ||
      (value.role?.instanceLabel !== undefined && !instanceLabel)
    )
      return undefined;
    author.role = {
      name: roleName,
      emoji: value.role.emoji,
      ...(instanceLabel ? { instanceLabel } : {}),
    };
  }
  if (value.model !== undefined) {
    const id = label(value.model?.id);
    const modelName = label(value.model?.name);
    if (!id || (value.model?.name !== undefined && !modelName))
      return undefined;
    author.model = modelName ?? id;
  }
  return author;
}
function bump(projection: Projection, key: string, fingerprint: string) {
  const previous = projection.revs.get(key);
  if (previous && previous.fingerprint === fingerprint) return previous.rev;
  const rev = (previous?.rev ?? 0) + 1;
  projection.revs.set(key, { rev, fingerprint });
  return rev;
}

export function itemRev(doc: LoroDoc, entryId: string, itemId: string) {
  return projectionFor(doc).revs.get(`${entryId}/${itemId}`)?.rev ?? 0;
}

export function identityAt(list: LoroList, index: number) {
  const id = list.getIdAt(index);
  return id ? `${id.peer}:${id.counter}` : `idx:${index}`;
}

function countDiff(content: unknown) {
  if (!Array.isArray(content)) return undefined;
  let added = 0,
    removed = 0,
    path: string | undefined;
  for (const block of content) {
    if (!block || block.type !== 'diff') continue;
    path ??= typeof block.path === 'string' ? block.path : undefined;
    const before = String(block.oldText ?? '').split('\n');
    const after = String(block.newText ?? '').split('\n');
    const shared = new Set(before);
    for (const line of after) if (!shared.has(line)) added += 1;
    const target = new Set(after);
    for (const line of before) if (!target.has(line)) removed += 1;
  }
  return path === undefined && added === 0 && removed === 0
    ? undefined
    : { path, added, removed };
}

function summarizeItem(
  projection: Projection,
  raw: any,
  entryId: string,
  identity: string,
) {
  const type = String(raw?.type ?? 'unknown');
  const itemId =
    type === 'tool_call' && typeof raw.toolCallId === 'string'
      ? raw.toolCallId
      : identity;
  const key = `${entryId}/${itemId}`;

  if (type === 'system_notice') {
    const name = typeof raw.name === 'string' ? raw.name : '';
    const meta = {
      reason:
        typeof raw.meta?.reason === 'string' ? raw.meta.reason : undefined,
      code: typeof raw.meta?.code === 'string' ? raw.meta.code : undefined,
      message:
        typeof raw.meta?.message === 'string' ? raw.meta.message : undefined,
    };
    return {
      itemId,
      rev: bump(projection, key, JSON.stringify({ name, meta })),
      type,
      name,
      meta,
    };
  }

  if (type === 'text' || type === 'thought') {
    const text = typeof raw.text === 'string' ? raw.text : '';
    return {
      itemId,
      rev: bump(projection, key, text),
      type,
      text,
    } as ItemSummary;
  }

  if (type === 'image' || type === 'image_group') {
    const sources = type === 'image' ? [raw] : raw.images;
    const images = (Array.isArray(sources) ? sources : [])
      .filter(
        (image: any) =>
          typeof image?.imageId === 'string' && image.imageId.length > 0,
      )
      .map((raw: any) => ({
        id: String(raw.imageId ?? ''),
        fileName: String(raw.fileName ?? '图片'),
        storageSessionId:
          typeof raw.storageSessionId === 'string'
            ? raw.storageSessionId
            : undefined,
        width:
          typeof raw.width === 'number' && raw.width > 0
            ? raw.width
            : undefined,
        height:
          typeof raw.height === 'number' && raw.height > 0
            ? raw.height
            : undefined,
      }));
    const media = type === 'image' ? { image: images[0] } : { images };
    return {
      itemId,
      rev: bump(projection, key, JSON.stringify(media)),
      type,
      ...media,
    } as ItemSummary;
  }
  if (type === 'file') {
    const file = {
      id: String(raw.fileId ?? ''),
      fileName: String(raw.fileName ?? '附件'),
      transport: typeof raw.transport === 'string' ? raw.transport : undefined,
      sizeBytes: Number.isSafeInteger(raw.sizeBytes)
        ? raw.sizeBytes
        : undefined,
      storageSessionId:
        typeof raw.storageSessionId === 'string'
          ? raw.storageSessionId
          : undefined,
      // A LAN machine gives a kept file back by id, checked against these.
      ...(raw.transport === 'local' &&
      typeof raw.machineId === 'string' &&
      typeof raw.sha256 === 'string'
        ? {
            machineId: raw.machineId,
            sha256: raw.sha256,
            mimeType: typeof raw.mimeType === 'string' ? raw.mimeType : '',
          }
        : {}),
    };
    return {
      itemId,
      rev: bump(projection, key, JSON.stringify(file)),
      type,
      file,
    } as ItemSummary;
  }

  if (type === 'tool_call') {
    const diff = countDiff(raw.content);
    const questionMeta = parseQuestionMeta(raw.permissionRequest?._meta);
    const isQuestion =
      !!questionMeta ||
      raw.permissionRequest?.kind === 'ask_user_question' ||
      raw.kind === 'ask_user_question';
    const permission = raw.permissionRequest
      ? {
          requestId: String(raw.permissionRequest.requestId ?? ''),
          pending: raw.permissionRequest.outcome == null,
          options: raw.permissionRequest.options,
          kind: isQuestion
            ? ('ask_user_question' as const)
            : ('permission' as const),
          questionMeta,
        }
      : undefined;
    const summary = {
      itemId,
      rev: 0,
      type,
      kind: String(raw.kind ?? 'other'),
      title: String(raw.title ?? raw.toolName ?? ''),
      status: String(raw.status ?? 'pending'),
      path: diff?.path,
      added: diff?.added,
      removed: diff?.removed,
      hasDetail: Array.isArray(raw.content) ? raw.content.length > 0 : false,
      permission,
    };
    summary.rev = bump(projection, key, JSON.stringify(summary));
    return summary as ItemSummary;
  }

  if (type === 'plan') {
    const entries = (Array.isArray(raw.entries) ? raw.entries : []).map(
      (e: any) => ({
        content: String(e?.content ?? ''),
        status: String(e?.status ?? 'pending'),
        priority: e?.priority == null ? undefined : String(e.priority),
      }),
    );
    return {
      itemId,
      rev: bump(projection, key, JSON.stringify(entries)),
      type,
      entries,
    } as ItemSummary;
  }

  if (type === 'subagent_task') {
    const summary = {
      itemId,
      rev: 0,
      type,
      taskId: String(raw.taskId ?? itemId),
      status: String(raw.status ?? 'pending'),
      actor: raw.actor == null ? undefined : String(raw.actor),
      description:
        raw.description == null ? undefined : String(raw.description),
      lastToolName:
        raw.lastToolName == null ? undefined : String(raw.lastToolName),
      summary: raw.summary == null ? undefined : String(raw.summary),
      error: raw.error == null ? undefined : String(raw.error),
      isBackgrounded:
        raw.isBackgrounded == null ? undefined : Boolean(raw.isBackgrounded),
      skipTranscript:
        raw.skipTranscript == null ? undefined : Boolean(raw.skipTranscript),
      run: summarizeRun(projection, raw.run, key),
    };
    // Every step counts toward the rev, so an open run sheet reads it again.
    summary.rev = bump(projection, key, JSON.stringify(summary));
    const run = summary.run;
    if (!run) return summary as ItemSummary;
    return {
      ...summary,
      run: { ...run, items: run.items.slice(-1), itemCount: run.items.length },
    } as ItemSummary;
  }

  return { itemId, rev: bump(projection, key, type), type } as ItemSummary;
}

const finite = (value: unknown) =>
  typeof value === 'number' && Number.isFinite(value) ? value : undefined;

function summarizeRun(
  projection: Projection,
  run: any,
  key: string,
): SubagentRunSummary | undefined {
  if (!run || typeof run !== 'object' || !run.snapshot) return;
  const snapshot = run.snapshot;
  const progress = run.progress ?? {};
  const items: unknown[] = Array.isArray(run.items) ? run.items : [];
  return {
    state: String(snapshot.state ?? 'unknown'),
    modelId:
      typeof snapshot.modelId === 'string' ? snapshot.modelId : undefined,
    outputIncomplete: snapshot.outputIncomplete === true || undefined,
    cancel: snapshot.support?.cancel === true || undefined,
    totalTokens: finite(progress.totalTokens),
    toolCallCount: finite(progress.toolCallCount),
    contextUsagePercent: finite(progress.contextUsagePercent),
    items: items.map((item, index) =>
      summarizeItem(projection, item, `${key}/run`, `run-${index}`),
    ) as ItemSummary[],
  };
}

/**
 * Every step of the run a `subagent_task` item holds, for the sheet that shows
 * it. The session envelope carries only the latest step.
 */
export function subagentRun(
  doc: LoroDoc,
  entryId: string,
  itemId: string,
  item: LoroMap,
): SubagentRunSummary | undefined {
  return summarizeRun(
    projectionFor(doc),
    lightRun(item.get('run')),
    `${entryId}/${itemId}`,
  );
}

function summarizeEntry(
  projection: Projection,
  history: LoroList,
  entry: any,
  index: number,
  pendingOutcomes?: ReadonlyMap<string, unknown>,
) {
  const id = String(entry?.id ?? identityAt(history, index));
  if (pendingOutcomes?.size && Array.isArray(entry?.items)) {
    const container = history.get(index) as LoroMap | undefined;
    const items =
      container && typeof container.get === 'function'
        ? (container.get('items') as LoroList)
        : undefined;
    entry = {
      ...entry,
      items: entry.items.map((item: any, i: number) => {
        const request = item?.permissionRequest;
        let itemId = `idx:${index}:${i}`;
        if (items && typeof items.getIdAt === 'function')
          itemId = identityAt(items, i);
        if (item?.type === 'tool_call' && typeof item.toolCallId === 'string')
          itemId = item.toolCallId;
        const key = `${id}/${itemId}/${request?.requestId}`;
        if (
          !pendingOutcomes.has(key) ||
          !samePermissionOutcome(request?.outcome, pendingOutcomes.get(key))
        )
          return item;
        return { ...item, permissionRequest: { ...request, outcome: null } };
      }),
    };
  }
  const container = history.get(index) as LoroMap | undefined;
  const items =
    container && typeof (container as any).get === 'function'
      ? ((container as any).get('items') as LoroList | undefined)
      : undefined;
  const list = Array.isArray(entry?.items) ? entry.items : [];
  const summarizedItems: ItemSummary[] = list.map((item: any, i: number) =>
    summarizeItem(
      projection,
      item,
      id,
      items && typeof items.getIdAt === 'function'
        ? identityAt(items, i)
        : `idx:${index}:${i}`,
    ),
  );
  const fileDiffs = (Array.isArray(entry?.fileDiff) ? entry.fileDiff : [])
    .filter((diff: any) => diff && typeof diff.filePath === 'string')
    .map((diff: any) => ({
      path: String(diff.filePath),
      add: Number(diff.add) || 0,
      del: Number(diff.del) || 0,
    }));
  const model = entry?.modelInfo;
  const modelInfo = {
    modelId:
      typeof model?.modelId === 'string' ? model.modelId.trim() : undefined,
    name: typeof model?.name === 'string' ? model.name.trim() : undefined,
    thoughtLevel:
      typeof model?._meta?.lodyThoughtLevel === 'string'
        ? model._meta.lodyThoughtLevel.trim()
        : undefined,
  };
  const metadata = readTurnMetadata(entry);
  const author = readAuthor(entry?.author);
  const value = {
    ...metadata,
    id,
    rev: bump(
      projection,
      `entry/${id}`,
      summarizedItems.map((i) => `${i.itemId}:${i.rev}`).join(',') +
        `|${entry?.status}|${entry?.finished}|${entry?.inputConfig?._lodyDeliveryKind === 'continue'}|${JSON.stringify(fileDiffs)}|${JSON.stringify(modelInfo)}|${JSON.stringify(metadata)}|${JSON.stringify(author)}`,
    ),
    role: String(entry?.role ?? 'assistant'),
    status: entry?.status ?? (entry?.read ? 'seen' : 'pending'),
    finished: entry?.finished === true,
    ...(author ? { author } : {}),
    timestamp: entry?.timestamp,
    startedAt: entry?.startedAt,
    endedAt: entry?.endedAt,
    permissionWaitMs: entry?.permissionWaitMs,
    modelInfo: modelInfo.name || modelInfo.modelId ? modelInfo : undefined,
    userTurnId: entry?.userTurnId,
    deliveryKind:
      entry?.inputConfig?._lodyDeliveryKind === 'continue'
        ? ('continue' as const)
        : undefined,
    items: summarizedItems,
    ...(fileDiffs.length ? { fileDiffs } : {}),
  };
  return value;
}

/**
 * The session's turn configurations, newest first, in the order of Lody's
 * `collectSessionConversationSources`: what is queued runs after everything in
 * history, so the next turn and the composer follow the queue's tail.
 */
export function conversationConfigs(history: any[], queue: any[]): any[] {
  return [
    ...queue.map((item) => item?.acpSessionConfig).reverse(),
    ...history
      .filter((entry) => entry?.role === 'user')
      .map((entry) => entry.inputConfig)
      .reverse(),
  ];
}

function pendingFingerprint(
  pendingOutcomes: ReadonlyMap<string, unknown> | undefined,
  entryId: string,
) {
  if (!pendingOutcomes?.size) return '';
  let fingerprint = '';
  for (const [key, outcome] of pendingOutcomes)
    if (key.startsWith(`${entryId}/`))
      fingerprint += `${key}=${JSON.stringify(outcome)};`;
  return fingerprint;
}

/**
 * Projects the replica for the chat. Only entries a change reached since the
 * previous call are read again, and without provider payloads.
 */
export function projectSession(
  doc: LoroDoc,
  status: string,
  reason?: string,
  pendingOutcomes?: ReadonlyMap<string, unknown>,
  steerReceipts?: ReadonlyMap<string, SteerReceipt>,
): Envelope {
  return project(doc, false, status, reason, pendingOutcomes, steerReceipts);
}

/**
 * Projects every entry again from its complete JSON: the reference that the
 * incremental `projectSession` must equal.
 */
export function projectSessionFull(
  doc: LoroDoc,
  status: string,
  reason?: string,
  pendingOutcomes?: ReadonlyMap<string, unknown>,
  steerReceipts?: ReadonlyMap<string, SteerReceipt>,
): Envelope {
  return project(doc, true, status, reason, pendingOutcomes, steerReceipts);
}

function project(
  doc: LoroDoc,
  full: boolean,
  status: string,
  reason?: string,
  pendingOutcomes?: ReadonlyMap<string, unknown>,
  steerReceipts?: ReadonlyMap<string, SteerReceipt>,
): Envelope {
  const projection = projectionFor(doc);
  const history = doc.getList(HISTORY) as LoroList;
  const links = doc.getMap('lodySteerLinks').toJSON() as Record<string, any>;
  const configFor = (id: string, input: any) => {
    const link = links[id];
    if (
      !link ||
      typeof link.targetId !== 'string' ||
      !['interrupt', 'native'].includes(link.mode)
    )
      return input;
    return {
      ...input,
      _lodyDeliveryKind: 'steer',
      _lodySteerTarget: link.targetId,
      _lodySteerMode: link.mode,
    };
  };
  const reuse = !full && !projection.stale;
  const present = new Set<ContainerID>();
  const raw: any[] = [];
  const summarized: (EntrySummary & { userTurnId?: string })[] = [];
  for (let index = 0; index < history.length; index++) {
    const container = history.get(index);
    const key = isContainer(container) ? container.id : undefined;
    let cached =
      key && reuse && !projection.dirty.has(key)
        ? projection.entries.get(key)
        : undefined;
    if (!cached) {
      cached = {
        base: full ? plain(container) : lightEntry(container),
        index: -1,
        link: '',
        pending: '',
      };
      if (key) projection.entries.set(key, cached);
    }
    if (key) present.add(key);
    const base = cached.base;
    const entry = {
      ...base,
      inputConfig: configFor(base?.id, base?.inputConfig),
    };
    raw.push(entry);
    // A summary also depends on the entry's place, steer link and unsent answers.
    const link = JSON.stringify(links[base?.id]) ?? '';
    const pending = pendingFingerprint(
      pendingOutcomes,
      String(base?.id ?? identityAt(history, index)),
    );
    if (
      !cached.value ||
      cached.index !== index ||
      cached.link !== link ||
      cached.pending !== pending
    ) {
      cached.value = summarizeEntry(
        projection,
        history,
        entry,
        index,
        pendingOutcomes,
      );
      cached.index = index;
      cached.link = link;
      cached.pending = pending;
    }
    summarized.push(cached.value);
  }
  for (const key of projection.entries.keys())
    if (!present.has(key)) projection.entries.delete(key);
  projection.dirty.clear();
  projection.stale = false;
  const queued = (doc.getMovableList('mq').toJSON() as any[]).map((item) => ({
    ...item,
    acpSessionConfig: configFor(item.userTurnId, item.acpSessionConfig),
  }));
  const input = conversationConfigs(raw, queued)[0];
  const options =
    input?.configOptionValues && typeof input.configOptionValues === 'object'
      ? input.configOptionValues
      : {};
  const fastValues = Object.fromEntries(
    ['fast', 'fast-mode'].flatMap((id) =>
      typeof options[id] === 'boolean' ? [[id, options[id]]] : [],
    ),
  );
  const effort = [options.reasoning_effort, options.effort].find(
    (value) => typeof value === 'string',
  );

  // A daemon history-sync timeout can place a concurrent reply before its input.
  // Use its explicit causal link; never sort streamed turns by arrival time.
  const userIds = new Set(
    summarized.filter((e) => e.role === 'user').map((e) => e.id),
  );
  const replies = new Map<string, typeof summarized>();
  for (const entry of summarized)
    if (entry.role === 'assistant' && userIds.has(entry.userTurnId!)) {
      const group = replies.get(entry.userTurnId!) ?? [];
      group.push(entry);
      replies.set(entry.userTurnId!, group);
    }
  const ordered = summarized.flatMap((entry) =>
    entry.role === 'assistant' && userIds.has(entry.userTurnId!)
      ? []
      : [
          entry,
          ...(entry.role === 'user' ? (replies.get(entry.id) ?? []) : []),
        ],
  );

  const execution = executionProjection(
    [
      ...raw,
      ...queued
        .filter((item) => !userIds.has(item.userTurnId))
        .map((item) => ({
          id: item.userTurnId,
          role: 'user',
          status:
            item.acpSessionConfig?._lodySteerMode === 'interrupt'
              ? 'pending_apply'
              : 'queued',
          inputConfig: item.acpSessionConfig,
        })),
    ],
    status === 'live',
    steerReceipts,
  );
  revision += 1;
  const session = doc.getMap('session').toJSON();
  return {
    v: 1,
    status,
    reason,
    revision,
    billableTurnCount: billableTurnCount({ history: raw, mq: queued }),
    awaitingUserSince:
      typeof session?.awaitingUserSince === 'number'
        ? session.awaitingUserSince
        : undefined,
    preview: previewSummary(doc),
    ...(input
      ? {
          composer: {
            ...(typeof input.modelId === 'string'
              ? { modelId: input.modelId }
              : {}),
            ...(typeof input.modeId === 'string'
              ? { modeId: input.modeId }
              : {}),
            ...(typeof effort === 'string' ? { effort } : {}),
            ...(Object.keys(fastValues).length
              ? { configOptionValues: fastValues }
              : {}),
          },
        }
      : {}),
    entries: [
      ...ordered.map((entry) => ({ ...entry, ...execution.get(entry.id) })),
      ...queued
        .filter(
          (item) =>
            typeof item.userTurnId === 'string' &&
            !userIds.has(item.userTurnId),
        )
        .map((item) => ({
          id: item.userTurnId,
          role: 'user',
          status:
            item.acpSessionConfig?._lodySteerMode === 'interrupt'
              ? 'pending_apply'
              : 'queued',
          ...execution.get(item.userTurnId),
          finished: false,
          rev: 0,
          timestamp: item.timestamp,
          items: (
            item.acpSessionConfig?.inputBlocks ?? [
              { type: 'text', text: item.task },
            ]
          ).map((block: any, index: number) =>
            summarizeItem(projection, block, item.userTurnId, `queue:${index}`),
          ),
        })),
    ],
  };
}
