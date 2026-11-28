import { migrateLegacyAntigravityModeId } from '../protocol/capability.ts';
import {
  proposalOf,
  type ProposalPresentation,
} from '../protocol/proposals.ts';
import {
  operationPresentation,
  type OperationPresentation,
} from './operation-presentation.ts';
import {
  type SessionUsage,
  projectSessionUsage,
} from '../protocol/session-usage.ts';
import { presentMessageText } from '../protocol/message-references.ts';
import {
  readTurnMetadata,
  type TurnMetadata,
} from '../protocol/turnMetadata.ts';
import { executionProjection, type SteerReceipt } from './execution';
import { userTurnItems } from './edit-session.ts';
import type {
  ContainerID,
  LoroDoc,
  LoroList,
  LoroMap,
  LoroMovableList,
} from 'loro-crdt/base64';

const LORO_CONTAINERS = new Set([
  'Text',
  'Map',
  'List',
  'Tree',
  'MovableList',
  'Counter',
]);
function isContainer(
  value: unknown,
): value is { id: ContainerID; kind(): string; toJSON(): unknown } {
  if (typeof value !== 'object' || value === null) return false;
  const proto = Object.getPrototypeOf(value);
  if (
    proto === null ||
    typeof proto !== 'object' ||
    typeof (proto as { kind?: unknown }).kind !== 'function'
  )
    return false;
  return LORO_CONTAINERS.has((value as { kind(): string }).kind());
}
import {
  parseQuestionMeta,
  samePermissionOutcome,
} from '../protocol/permissionQuestions.ts';
import type { QuestionMeta, TurnAuthor } from '../models/session.ts';
import { billableTurnCount } from './billing';
import type { RoostHistorySyncState } from './upstream-roost.js';
import { previewSummary } from './preview';

export type SystemNoticeMeta = {
  reason?: string;
  code?: string;
  message?: string;
  trigger?: string;
  status?: string;
  kind?: string;
  generation?: number;
  nodeId?: string;
  usedBefore?: number;
  usedAfter?: number;
  foldedCount?: number;
  foldId?: string;
  command?: {
    action: string;
    name?: string;
    description?: string;
    promptPrefix?: string;
    patch?: RoleProposalFields;
  };
  before?: RoleProposalFields;
  outcome?: string;
  /** `agent_warning`: which Lody path raised it (web `AgentWarningNoticeBody`). */
  source?: string;
  /** `session_fork_origin`: the conversation this one was forked from. */
  sourceSessionId?: string;
  sourceTitle?: string;
  /** `resume_from_external_chat_history`: the imported history was cut to fit. */
  truncated?: boolean;
};

const SESSION_ROLLOVER_TURN_PREFIX = 'session-rollover:';
const BOARD_MAINTENANCE_TURN_PREFIX = 'board-maintenance:';

/**
 * Internal maintenance/rollover assistant replies (`:seal`, `:renew`, `:fold`,
 * `:memory`, `:compact`, `:handoff`) stay out of the visible chat transcript
 * and execution/unread state; their paired system divider represents the run.
 */
export function isHiddenInternalAssistantEntry(entry: any): boolean {
  return (
    entry?.role === 'assistant' &&
    typeof entry.userTurnId === 'string' &&
    (entry.userTurnId.startsWith(SESSION_ROLLOVER_TURN_PREFIX) ||
      entry.userTurnId.startsWith(BOARD_MAINTENANCE_TURN_PREFIX))
  );
}
type RoleProposalFields = {
  name?: string;
  description?: string;
  promptPrefix?: string;
};
export type OperationMemberSummary = {
  title: string;
  status: string;
};

/** Web `WorktreeScriptNoticeView` reads at most this much of a step's output. */
const WORKTREE_OUTPUT_TAIL = 8000;

export type ItemSummary =
  | {
      itemId: string;
      rev: number;
      type:
        | 'operation_progress'
        | 'operation_completion'
        | 'operation_completion_batch';
      operation: OperationPresentation;
      memberCount?: number;
      deliveryStatus?: string;
      members?: OperationMemberSummary[];
    }
  | {
      itemId: string;
      rev: number;
      type: 'system_notice';
      name: string;
      meta?: SystemNoticeMeta;
      /** `agent_role_proposal` / `schedule_proposal` / `schedule_edit_proposal`, when well-formed. */
      proposal?: ProposalPresentation;
    }
  | {
      itemId: string;
      rev: number;
      type: 'worktree_script';
      phase: 'setup' | 'cleanup';
      status: 'in_progress' | 'completed' | 'failed';
      /** Each command with the tail of its output. */
      steps: {
        command: string;
        status: 'in_progress' | 'completed' | 'failed';
        output: string;
      }[];
    }
  | { itemId: string; rev: number; type: 'text'; text: string }
  | { itemId: string; rev: number; type: 'thought'; text: string }
  | {
      itemId: string;
      rev: number;
      type: 'proposed_plan';
      turnId: string;
      markdown: string;
      status: 'delta' | 'completed' | 'cleared';
      isLatest: boolean;
    }
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
      /** Plan text a `switch_mode` (plan-approval) card carries; see `planExitMarkdown`. */
      plan?: string;
      /** Web `isProcessStatusToolCall`: a one-line status (e.g. context compaction), not a tool card. */
      activityKind?: 'context_compaction' | 'codex_retry';
      permission?: {
        requestId: string;
        pending: boolean;
        options?: { optionId: string; name: string; kind?: string }[];
        kind?: 'permission' | 'ask_user_question';
        questionMeta?: QuestionMeta;
        /** The option a settled request was answered with (history `outcome.optionId`). */
        chosenOptionId?: string;
        /** The request was withdrawn (history outcome `cancelled`), not answered. */
        withdrawn?: boolean;
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
  sessionId?: string;
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
  userId?: string;
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
  sendReady?: boolean;
  controlReady?: boolean;
  billableTurnCount?: number;
  usage?: SessionUsage;
  historyHasMore?: boolean;
  historyLoading?: boolean;
  historySync?: RoostHistorySyncState;
  /** Locally persisted owner inputs whose delivery is still being reconciled. */
  pendingRoostInputs?: readonly Record<string, unknown>[];
  awaitingUserSince?: number;
  preview?: { label: string; active: boolean };
  composer?: {
    modelId?: string;
    modeId?: string;
    effort?: string;
    configOptionValues?: Record<string, string | boolean>;
    /** The Role the latest turn ran as; null after an explicit None (web). */
    agentRoleId?: string | null;
  };
  /** Active unfinished assistant turn ID from full history (including hidden maintenance turns). */
  activeTurnId?: string;
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
  /** Invalidate tool details from change events without reading provider payloads. */
  detailVersions: Map<string, number>;
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
    detailVersions: new Map(),
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
      projection.detailVersions.clear();
      return;
    }
    const changed = new Set<string>();
    for (const event of batch.events) {
      const [root, index] = event.path;
      // Inserting or deleting entries changes only which containers are read.
      if (root !== HISTORY || event.path.length < 2) continue;
      const entry = typeof index === 'number' ? history.get(index) : undefined;
      const detailsChanged =
        event.path.some((part) =>
          ['content', 'rawInput', 'rawOutput'].includes(String(part)),
        ) ||
        (event.diff.type === 'map' &&
          Object.keys(event.diff.updated).some((key) =>
            ['content', 'rawInput', 'rawOutput', 'run', 'items'].includes(key),
          ));
      if (detailsChanged && isMap(entry)) {
        const id = plain(entry.get('id'));
        if (typeof id === 'string') changed.add(id);
      }
      if (isContainer(entry)) projection.dirty.add(entry.id);
      else projection.stale = true;
    }
    for (const id of changed)
      projection.detailVersions.set(
        id,
        (projection.detailVersions.get(id) ?? 0) + 1,
      );
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
      if (PAYLOAD_KEYS.has(key)) {
        if (key !== '_meta' && item.get(key) != null) value[key] = true;
        continue;
      }
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
    if (PAYLOAD_KEYS.has(key)) {
      if (key !== '_meta' && field != null) value[key] = true;
      continue;
    }
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

/**
 * Plan text carried by a plan-approval (`switch_mode`) card — web
 * `resolvePlanExitMarkdown` (`packages/components/.../plan-surface.ts`).
 * Claude puts it in `rawInput.plan` (its `content` can later be replaced by a
 * status message), Kimi in the first `content` text block; Codex carries none
 * here and renders a separate `proposed_plan` item instead.
 */
function planExitMarkdown(raw: any): string | undefined {
  const rawPlan = raw.rawInput?.plan;
  if (typeof rawPlan === 'string' && rawPlan.trim()) return rawPlan.trim();
  const block = (Array.isArray(raw.content) ? raw.content : []).find(
    (block: any) =>
      block?.type === 'content' &&
      block.content?.type === 'text' &&
      typeof block.content.text === 'string' &&
      block.content.text.trim(),
  );
  return block ? String(block.content.text).trim() : undefined;
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
  parentItemId?: string,
) {
  const type = String(raw?.type ?? 'unknown');
  const localId =
    type === 'tool_call' && typeof raw.toolCallId === 'string'
      ? raw.toolCallId
      : identity;
  const itemId = parentItemId
    ? JSON.stringify([parentItemId, localId])
    : localId;
  const key = `${entryId}/${itemId}`;

  if (
    [
      'operation_progress',
      'operation_completion',
      'operation_completion_batch',
    ].includes(type)
  ) {
    const operation = operationPresentation(raw);
    if (
      type === 'operation_completion' ||
      type === 'operation_completion_batch'
    ) {
      const members = (
        type === 'operation_completion_batch'
          ? (raw.members ?? []).slice(0, 50)
          : [raw]
      )
        .flatMap((member: any): OperationMemberSummary[] => {
          const completion = member.completion;
          const result =
            completion?.type === 'result'
              ? completion.value
              : completion?.partial;
          if (completion?.type === 'error')
            return [
              {
                title: completion.error.message,
                status: 'failed',
              },
            ];
          if (
            completion?.type === 'result' &&
            (member.operationKind === 'board_report' ||
              member.source === 'board_report')
          ) {
            return (result?.boardReport?.events ?? []).map((event: any) => ({
              title: event.title ?? event.sessionId,
              status: event.kind,
            }));
          }
          return (result?.items ?? []).map((item: any) => ({
            title: item.label ?? item.target?.sessionId ?? member.operationKind,
            status: item.status,
          }));
        })
        .slice(0, 50);
      const summary = {
        itemId,
        rev: 0,
        type,
        operation,
        memberCount: raw.memberCount ?? members.length,
        deliveryStatus: raw.deliveryStatus,
        members,
      };
      summary.rev = bump(projection, key, JSON.stringify(summary));
      return summary as ItemSummary;
    }
    return {
      itemId,
      rev: bump(projection, key, JSON.stringify(operation)),
      type,
      operation,
    } as ItemSummary;
  }

  if (type === 'system_notice') {
    const name = typeof raw.name === 'string' ? raw.name : '';
    const string = (field: string) =>
      typeof raw.meta?.[field] === 'string'
        ? (raw.meta[field] as string)
        : undefined;
    const noticeMeta: SystemNoticeMeta = {
      reason: string('reason'),
      code: string('code'),
      message: string('message'),
    };
    for (const field of ['source', 'sourceSessionId', 'sourceTitle'] as const) {
      const value = string(field);
      if (value !== undefined) noticeMeta[field] = value;
    }
    if (raw.meta?.truncated === true) noticeMeta.truncated = true;
    const finiteNumber = (field: string) =>
      typeof raw.meta?.[field] === 'number' && Number.isFinite(raw.meta[field])
        ? (raw.meta[field] as number)
        : undefined;
    if (name === 'board_context_maintenance') {
      const usedBefore = finiteNumber('usedBefore');
      const usedAfter = finiteNumber('usedAfter');
      const nodeId = string('nodeId');
      const foldedCount = finiteNumber('foldedCount');
      const foldId = string('foldId');
      Object.assign(noticeMeta, {
        trigger: string('trigger'),
        status: string('status'),
        kind: string('kind'),
        ...(usedBefore !== undefined ? { usedBefore } : {}),
        ...(usedAfter !== undefined ? { usedAfter } : {}),
        ...(nodeId !== undefined ? { nodeId } : {}),
        ...(foldedCount !== undefined ? { foldedCount } : {}),
        ...(foldId !== undefined ? { foldId } : {}),
      });
    }
    if (name === 'session_context_rollover') {
      const generation = finiteNumber('generation');
      const nodeId = string('nodeId');
      const usedBefore = finiteNumber('usedBefore');
      const usedAfter = finiteNumber('usedAfter');
      Object.assign(noticeMeta, {
        kind: string('kind'),
        trigger: string('trigger'),
        status: string('status'),
        ...(generation !== undefined ? { generation } : {}),
        ...(nodeId !== undefined ? { nodeId } : {}),
        ...(usedBefore !== undefined ? { usedBefore } : {}),
        ...(usedAfter !== undefined ? { usedAfter } : {}),
      });
    }
    if (name === 'agent_role_proposal' && raw.meta?.command) {
      const fields = ({
        name,
        description,
        promptPrefix,
      }: RoleProposalFields) => ({ name, description, promptPrefix });
      const command = raw.meta.command;
      noticeMeta.command = {
        action: command.action,
        ...fields(command),
        ...(command.patch ? { patch: fields(command.patch) } : {}),
      };
      if (raw.meta.before) noticeMeta.before = fields(raw.meta.before);
      noticeMeta.outcome = raw.meta.outcome;
    }
    const proposal = proposalOf(name, raw.meta);
    return {
      itemId,
      rev: bump(
        projection,
        key,
        JSON.stringify({ name, meta: noticeMeta, proposal }),
      ),
      type,
      name,
      meta: noticeMeta,
      ...(proposal ? { proposal } : {}),
    };
  }

  if (
    type === 'worktree_script' &&
    (raw.phase === 'setup' || raw.phase === 'cleanup') &&
    ['in_progress', 'completed', 'failed'].includes(raw.status)
  ) {
    const status = (value: unknown) =>
      value === 'in_progress' || value === 'completed' || value === 'failed'
        ? value
        : undefined;
    const steps = (Array.isArray(raw.steps) ? raw.steps : []).flatMap(
      (step: any) => {
        const state = status(step?.status);
        if (typeof step?.command !== 'string' || !state) return [];
        const output = typeof step.output === 'string' ? step.output : '';
        return [
          {
            command: step.command,
            status: state,
            output: output.slice(-WORKTREE_OUTPUT_TAIL),
          },
        ];
      },
    );
    const script = {
      phase: raw.phase,
      status: raw.status,
      steps,
    };
    return {
      itemId,
      rev: bump(projection, key, JSON.stringify(script)),
      type,
      ...script,
    } as ItemSummary;
  }

  if (type === 'text' || type === 'thought') {
    const text = typeof raw.text === 'string' ? raw.text : '';
    return {
      itemId,
      rev: bump(projection, key, text),
      type,
      text,
      ...(raw.references?.length ? { references: raw.references } : {}),
    } as ItemSummary;
  }

  if (type === 'proposed_plan') {
    const plan = {
      turnId: typeof raw.turnId === 'string' ? raw.turnId : '',
      markdown: typeof raw.markdown === 'string' ? raw.markdown : '',
      status:
        raw.status === 'delta' || raw.status === 'completed'
          ? raw.status
          : 'cleared',
      isLatest: raw.isLatest === true,
    };
    return {
      itemId,
      rev: bump(projection, key, JSON.stringify(plan)),
      type,
      ...plan,
    } as ItemSummary;
  }

  if (type === 'image' || type === 'image_group') {
    const sources = type === 'image' ? [raw] : raw.images;
    const images = (Array.isArray(sources) ? sources : [])
      .filter(
        (image: any) =>
          (typeof image?.imageId === 'string' && image.imageId.length > 0) ||
          (typeof image?.localImageId === 'string' &&
            image.localImageId.length > 0),
      )
      .map((raw: any) => {
        const localImageId =
          typeof raw.localImageId === 'string' && raw.localImageId.length > 0
            ? raw.localImageId
            : undefined;
        const id =
          typeof raw.imageId === 'string' && raw.imageId.length > 0
            ? raw.imageId
            : (localImageId ?? '');
        return {
          id,
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
          ...(typeof raw.transport === 'string'
            ? { transport: raw.transport }
            : {}),
          ...(typeof raw.machineId === 'string' && raw.machineId.length > 0
            ? { machineId: raw.machineId }
            : {}),
          ...(localImageId ? { localImageId } : {}),
          ...(Number.isSafeInteger(raw.sizeBytes) && raw.sizeBytes > 0
            ? { sizeBytes: raw.sizeBytes }
            : {}),
          ...(typeof raw.mimeType === 'string' && raw.mimeType.length <= 255
            ? { mimeType: raw.mimeType }
            : {}),
        };
      });
    const media = type === 'image' ? { image: images[0] } : { images };
    return {
      itemId,
      rev: bump(projection, key, JSON.stringify(media)),
      type,
      ...media,
    } as ItemSummary;
  }
  if (type === 'local_attachment') {
    const path = typeof raw.path === 'string' ? raw.path.trim() : '';
    const machineId =
      typeof raw.machineId === 'string' ? raw.machineId.trim() : '';
    if (!path || !machineId) return { itemId, rev: 1, type };
    const fileName =
      typeof raw.fileName === 'string' && raw.fileName.trim()
        ? raw.fileName.trim()
        : '附件';
    const mimeType =
      typeof raw.mimeType === 'string' &&
      raw.mimeType.trim() &&
      raw.mimeType.length <= 255
        ? raw.mimeType.trim()
        : 'application/octet-stream';
    const kind = raw.kind === 'image' ? 'image' : 'file';
    const sizeBytes =
      Number.isSafeInteger(raw.sizeBytes) && raw.sizeBytes >= 0
        ? raw.sizeBytes
        : undefined;
    const file = {
      id: `local:${machineId}:${path}`,
      fileName,
      mimeType,
      transport: 'local_attachment',
      machineId,
      path,
      kind,
      ...(sizeBytes !== undefined ? { sizeBytes } : {}),
    };
    return {
      itemId,
      rev: bump(projection, key, JSON.stringify(file)),
      type,
      file,
    } as ItemSummary;
  }
  if (type === 'file') {
    const mimeType = typeof raw.mimeType === 'string' ? raw.mimeType : '';
    const file = {
      id: String(raw.fileId ?? ''),
      fileName: String(raw.fileName ?? '附件'),
      mimeType:
        typeof raw.mimeType === 'string' && raw.mimeType.length <= 255
          ? raw.mimeType
          : undefined,
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
            mimeType,
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
    const plan = raw.kind === 'switch_mode' ? planExitMarkdown(raw) : undefined;
    const activityKind =
      raw.activityKind === 'context_compaction' ||
      raw.activityKind === 'codex_retry'
        ? (raw.activityKind as 'context_compaction' | 'codex_retry')
        : undefined;
    const questionMeta = parseQuestionMeta(raw.permissionRequest?._meta);
    const isQuestion =
      !!questionMeta ||
      raw.permissionRequest?.kind === 'ask_user_question' ||
      raw.kind === 'ask_user_question';
    // Only the decision itself: question answers (possibly secret) stay in `itemDetail`.
    const outcome = raw.permissionRequest?.outcome;
    const permission =
      !parentItemId && raw.permissionRequest
        ? {
            requestId: String(raw.permissionRequest.requestId ?? ''),
            pending: outcome == null,
            options: raw.permissionRequest.options,
            kind: isQuestion
              ? ('ask_user_question' as const)
              : ('permission' as const),
            questionMeta,
            ...(outcome?.outcome === 'selected' &&
            typeof outcome.optionId === 'string'
              ? { chosenOptionId: outcome.optionId }
              : {}),
            ...(outcome?.outcome === 'cancelled' ? { withdrawn: true } : {}),
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
      hasDetail:
        (Array.isArray(raw.content) && raw.content.length > 0) ||
        raw.rawInput != null ||
        raw.rawOutput != null,
      ...(plan ? { plan } : {}),
      ...(activityKind ? { activityKind } : {}),
      permission,
    };
    summary.rev = bump(
      projection,
      key,
      JSON.stringify({
        ...summary,
        content: lightContent(raw.content),
        detailVersion: projection.detailVersions.get(entryId) ?? 0,
      }),
    );
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
      group: taskGroup(raw),
      run: summarizeRun(projection, raw.run, entryId, itemId),
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
  entryId: string,
  parentItemId: string,
): SubagentRunSummary | undefined {
  if (!run || typeof run !== 'object' || !Array.isArray(run.items)) return;
  const snapshot = run.snapshot ?? {};
  const progress = run.progress ?? {};
  const items: unknown[] = Array.isArray(run.items) ? run.items : [];
  return {
    sessionId: String(run.sessionId ?? parentItemId),
    state: String(snapshot.state ?? 'unknown'),
    modelId:
      typeof snapshot.modelId === 'string' ? snapshot.modelId : undefined,
    outputIncomplete: snapshot.outputIncomplete === true || undefined,
    cancel: snapshot.support?.cancel === true || undefined,
    totalTokens: finite(progress.totalTokens),
    toolCallCount: finite(progress.toolCallCount),
    contextUsagePercent: finite(progress.contextUsagePercent),
    items: items.flatMap((item: any, index) => {
      if (!['text', 'thought', 'tool_call', 'plan'].includes(item?.type))
        return [];
      return [
        summarizeItem(projection, item, entryId, `run:${index}`, parentItemId),
      ];
    }) as ItemSummary[],
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
  item: { get(key: string): unknown },
): SubagentRunSummary | undefined {
  return summarizeRun(
    projectionFor(doc),
    lightRun(item.get('run')),
    entryId,
    itemId,
  );
}

function summarizeEntry(
  projection: Projection,
  history: LoroList | undefined,
  entry: any,
  index: number,
  pendingOutcomes?: ReadonlyMap<string, unknown>,
) {
  const id = String(
    entry?.id ?? (history ? identityAt(history, index) : `idx:${index}`),
  );
  const fallbackItemId = (itemIndex: number) => {
    if (history) return `idx:${index}:${itemIndex}`;
    return `idx:${id}:${itemIndex}`;
  };
  if (pendingOutcomes?.size && Array.isArray(entry?.items)) {
    const container = history?.get(index) as LoroMap | undefined;
    const items =
      container && typeof container.get === 'function'
        ? (container.get('items') as LoroList)
        : undefined;
    entry = {
      ...entry,
      items: entry.items.map((item: any, i: number) => {
        const request = item?.permissionRequest;
        let itemId = fallbackItemId(i);
        if (items && typeof items.getIdAt === 'function')
          itemId = identityAt(items, i);
        if (item?.type === 'tool_call' && typeof item.toolCallId === 'string')
          itemId = item.toolCallId;
        // A proposal decision whose upload is unconfirmed stays undecided, so it can be retried.
        if (
          item?.type === 'system_notice' &&
          pendingOutcomes.has(`${id}/${itemId}/notice`)
        ) {
          const { outcome: _outcome, ...meta } = item.meta ?? {};
          return { ...item, meta };
        }
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
  const container = history?.get(index) as LoroMap | undefined;
  const items =
    container && typeof (container as any).get === 'function'
      ? ((container as any).get('items') as LoroList | undefined)
      : undefined;
  const rawItems = Array.isArray(entry?.items) ? entry.items : [];
  const list: any[] = entry?.role === 'user' ? userTurnItems(entry) : rawItems;
  const useLoroIdentity =
    rawItems.length > 0 && items && typeof items.getIdAt === 'function';
  const summarizedItems: ItemSummary[] = list.map((item: any, i: number) =>
    summarizeItem(
      projection,
      entry.role === 'user' && item?.type === 'text'
        ? { ...item, ...presentMessageText(item.text ?? '', item.spans) }
        : item,
      id,
      useLoroIdentity && i < rawItems.length
        ? identityAt(items, i)
        : fallbackItemId(i),
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
    // Who sent a user turn, for its avatar and name.
    userId: typeof entry?.userId === 'string' ? entry.userId : undefined,
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

/** Use the ordinary transcript projection for locally pending upstream inputs. */
export function projectPendingInputs(
  doc: LoroDoc,
  entries: readonly unknown[],
) {
  return entries.map((entry, index) =>
    summarizeEntry(projectionFor(doc), undefined, entry, index),
  );
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
  historyOverride?: readonly unknown[],
  historyMetadata?: readonly Record<string, unknown>[],
  /**
   * First history index sent to the host. Earlier entries still feed usage,
   * billing, execution and the composer; only the transcript is windowed.
   */
  historyStart = 0,
): Envelope {
  return project(
    doc,
    false,
    status,
    reason,
    pendingOutcomes,
    steerReceipts,
    historyOverride,
    historyMetadata,
    historyStart,
  );
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
  historyOverride?: readonly unknown[],
  historyMetadata?: readonly Record<string, unknown>[],
  historyStart = 0,
): Envelope {
  return project(
    doc,
    true,
    status,
    reason,
    pendingOutcomes,
    steerReceipts,
    historyOverride,
    historyMetadata,
    historyStart,
  );
}

function project(
  doc: LoroDoc,
  full: boolean,
  status: string,
  reason?: string,
  pendingOutcomes?: ReadonlyMap<string, unknown>,
  steerReceipts?: ReadonlyMap<string, SteerReceipt>,
  historyOverride?: readonly unknown[],
  historyMetadata?: readonly Record<string, unknown>[],
  historyStart = 0,
): Envelope {
  const projection = projectionFor(doc);
  const history = historyOverride
    ? undefined
    : (doc.getList(HISTORY) as LoroList);
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
  let raw: any[];
  let start = 0;
  let summarized: (EntrySummary & { userTurnId?: string })[];
  if (historyOverride) {
    raw = (historyOverride as any[]).map((entry) => ({
      ...entry,
      inputConfig: configFor(entry.id, entry.inputConfig),
    }));
    start = Math.min(Math.max(0, historyStart), raw.length);
    summarized = raw
      .slice(start)
      .map((entry, offset) =>
        summarizeEntry(
          projection,
          undefined,
          entry,
          start + offset,
          pendingOutcomes,
        ),
      );
  } else {
    const list = history!;
    const reuse = !full && !projection.stale;
    const present = new Set<ContainerID>();
    raw = [];
    const allSummarized: (EntrySummary & { userTurnId?: string })[] = [];
    for (let index = 0; index < list.length; index++) {
      const container = list.get(index);
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
        String(base?.id ?? identityAt(list, index)),
      );
      if (
        !cached.value ||
        cached.index !== index ||
        cached.link !== link ||
        cached.pending !== pending
      ) {
        cached.value = summarizeEntry(
          projection,
          list,
          entry,
          index,
          pendingOutcomes,
        );
        cached.index = index;
        cached.link = link;
        cached.pending = pending;
      }
      allSummarized.push(cached.value);
    }
    for (const key of projection.entries.keys())
      if (!present.has(key)) projection.entries.delete(key);
    projection.dirty.clear();
    projection.stale = false;
    start = Math.min(Math.max(0, historyStart), raw.length);
    summarized = allSummarized.slice(start);
  }
  const queued = (doc.getMovableList('mq').toJSON() as any[]).map((item) => ({
    ...item,
    acpSessionConfig: configFor(item.userTurnId, item.acpSessionConfig),
  }));
  const input =
    conversationConfigs(raw, queued)[0] ??
    historyMetadata?.findLast((entry) => entry.role === 'user')?.inputConfig;
  const options =
    input?.configOptionValues && typeof input.configOptionValues === 'object'
      ? input.configOptionValues
      : {};
  // Restore agent-specific permission selectors as well as Fast. Effort and
  // the standard model option have their own composer fields so changes stay atomic.
  const composerValues = Object.fromEntries(
    Object.entries(
      readTurnMetadata({ inputConfig: input }).inputConfig
        ?.configOptionValues ?? {},
    ).filter(
      ([id]) =>
        id !== 'effort' &&
        id !== 'reasoning_effort' &&
        id !== 'thought_level' &&
        id !== 'model',
    ),
  );
  const effort = [
    options.reasoning_effort,
    options.effort,
    options.thought_level,
  ].find((value) => typeof value === 'string');
  const rawModelOption =
    typeof options.model === 'string' && options.model.trim()
      ? options.model.trim()
      : undefined;
  const rawTopModel =
    typeof input?.modelId === 'string' && input.modelId.trim()
      ? input.modelId.trim()
      : undefined;
  const isConfigOptionDriven =
    input?.cliType === 'registry' || input?.cliType === 'custom';
  const composerModelId = isConfigOptionDriven
    ? (rawModelOption ?? rawTopModel)
    : (rawTopModel ?? rawModelOption);

  let activeTurnId: string | undefined;
  for (let index = raw.length - 1; index >= 0; index--) {
    const entry = raw[index];
    if (!entry || entry.role !== 'assistant') continue;
    if (
      entry.finished !== true &&
      typeof entry.endedAt !== 'number' &&
      typeof entry.id === 'string' &&
      entry.id
    ) {
      activeTurnId = entry.id;
    }
    break;
  }

  const visibleRaw = raw.filter(
    (entry) => !isHiddenInternalAssistantEntry(entry),
  );
  const visibleSummarized = summarized.filter(
    (entry) => !isHiddenInternalAssistantEntry(entry),
  );

  // A daemon history-sync timeout can place a concurrent reply before its input.
  // Use its explicit causal link; never sort streamed turns by arrival time.
  const userIds = new Set(
    visibleSummarized.filter((e) => e.role === 'user').map((e) => e.id),
  );
  // Inputs before the window are still landed: they must not reappear as queued.
  const landedUserIds = new Set(userIds);
  for (const entry of raw.slice(0, start))
    if (entry?.role === 'user' && typeof entry.id === 'string')
      landedUserIds.add(entry.id);
  const replies = new Map<string, typeof visibleSummarized>();
  for (const entry of visibleSummarized)
    if (entry.role === 'assistant' && userIds.has(entry.userTurnId!)) {
      const group = replies.get(entry.userTurnId!) ?? [];
      group.push(entry);
      replies.set(entry.userTurnId!, group);
    }
  const ordered = visibleSummarized.flatMap((entry) =>
    entry.role === 'assistant' && userIds.has(entry.userTurnId!)
      ? []
      : [
          entry,
          ...(entry.role === 'user' ? (replies.get(entry.id) ?? []) : []),
        ],
  );

  const execution = executionProjection(
    [
      ...visibleRaw,
      ...queued
        .filter((item) => !landedUserIds.has(item.userTurnId))
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
    usage: projectSessionUsage(raw),
    billableTurnCount: billableTurnCount({ history: raw, mq: queued }),
    awaitingUserSince:
      typeof session?.awaitingUserSince === 'number'
        ? session.awaitingUserSince
        : undefined,
    preview: previewSummary(doc),
    ...(activeTurnId ? { activeTurnId } : {}),
    ...(input
      ? {
          composer: {
            ...(composerModelId ? { modelId: composerModelId } : {}),
            ...(typeof input.modeId === 'string'
              ? { modeId: migrateLegacyAntigravityModeId(input.modeId) }
              : {}),
            ...(typeof effort === 'string' ? { effort } : {}),
            ...(Object.keys(composerValues).length
              ? { configOptionValues: composerValues }
              : {}),
            ...(typeof input.agentRoleId === 'string' ||
            input.agentRoleId === null
              ? { agentRoleId: input.agentRoleId }
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
            !landedUserIds.has(item.userTurnId),
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
          rev: bump(
            projection,
            `queue/${item.userTurnId}`,
            JSON.stringify(item),
          ),
          author: readAuthor(item.author),
          deliveryKind:
            item.acpSessionConfig?._lodyDeliveryKind === 'continue'
              ? ('continue' as const)
              : undefined,
          timestamp: item.timestamp,
          items: (
            item.acpSessionConfig?.inputBlocks ?? [
              { type: 'text', text: item.task },
            ]
          ).map((block: any, index: number) =>
            summarizeItem(
              projection,
              block?.type === 'text'
                ? {
                    ...block,
                    ...presentMessageText(block.text ?? '', block.spans),
                  }
                : block,
              item.userTurnId,
              `queue:${index}`,
            ),
          ),
        })),
    ],
  };
}

/**
 * Web `groupOf` (`subagent-task-state.tsx`): a scheduled wakeup is a task; anything with a
 * subagent type or a run is a subagent; else a shell command, MCP task or monitor is a task and
 * an unrecognised type stays with the subagents.
 */
const NON_AGENT_TASK_TYPES = new Set(['local_bash', 'mcp_task', 'monitor_mcp']);
function taskGroup(raw: any): 'subagents' | 'tasks' {
  if (raw?.taskKind === 'scheduled') return 'tasks';
  if (raw?.subagentType || raw?.run) return 'subagents';
  const type = raw?.taskType ?? raw?.actor;
  return typeof type === 'string' && NON_AGENT_TASK_TYPES.has(type)
    ? 'tasks'
    : 'subagents';
}
