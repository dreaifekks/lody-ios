import type { SessionUsage } from '../protocol/session-usage.ts';
import type { MessageReference } from '../protocol/message-references.ts';
import {
  appendMessageQuotes,
  messageQuotes,
  splitMessageQuotes,
  type MessageQuoteSpan,
} from '../protocol/message-quotes.ts';
import { LoroDoc, LoroMap, LoroList, LoroText } from 'loro-crdt/base64';
import { StreamsClient } from '@loro-dev/streams-client';
import { decompress } from 'fzstd';
import { decodeFrames, encodeFrame } from '../frames';
import {
  conversationConfigs,
  identityAt,
  itemRev,
  projectPendingInputs,
  projectSession,
  releaseProjection,
  subagentRun,
} from './project';
import type { SteerReceipt } from './execution';
import { machineRpc, type RpcReply } from './machine-rpc';
import type { HistoryProofBroker, RoostWindow } from './roost-history';
import {
  createUpstreamRoostHistory,
  roostStorageAccount,
  type MobileRoostCloudHistory,
} from './upstream-roost-history';
import {
  buildPendingUserHistoryEntry,
  createWorkspaceAcceptedInputs,
  createSessionOperationScope,
  type MobileSendPorts,
  type MobileSendStore,
  type SendMetadata,
  type AcceptedInput,
  HistoryEntryWriteSchema,
  parseHistoryWrite,
  RoostCloudHistoryRequestError,
  type RoostHistorySyncState,
} from './upstream-roost.js';
import { retrySessionRead, wakeSessionReads } from './session-read';
import { resolveTurnRole, type TurnRole } from './agent-roles';
import { record, roleRunConfigApplied } from '../protocol/agent-roles';
import {
  migrateLegacyAntigravityModeId,
  migrateLegacyAntigravityModeOption,
} from '../protocol/capability.ts';
import type {
  CheckTurnQuotaResult,
  ControlTurnResult,
  EditSessionResult,
  SendTurnResult,
  RetryPendingInputResult,
  SessionRuntimeEvent,
  SessionTrace,
} from '../contract/methods.ts';
import { runtimeCalls } from '../contract/methods.ts';
import {
  editableUserTurn,
  editAttachments,
  validAttachmentBlocks,
  replacementInput,
  userTurnItems,
} from './edit-session';
import {
  billableTurnCount,
  quotaReason,
  type BillingEntitlement,
} from './billing';
import {
  parseQuestionMeta,
  questionOutcome,
  samePermissionOutcome,
} from '../protocol/permissionQuestions.ts';
export { projectSession, projectSessionFull } from './project';

type Grant = { token: string; gatewayBaseUrl: string };
export type SessionTarget =
  | { backend: 'loro' }
  | {
      backend: 'roost';
      cloud?: MobileRoostCloudHistory;
      accountId?: string | null;
      machineId: string;
      incremental: boolean;
      live: boolean;
      getHistoryProof: HistoryProofBroker;
      acceptsInput: boolean;
      dispatchesInput: boolean;
      latestUserMsgId?: string;
      isArchived?: boolean;
      patches?: boolean;
      coherentInspection?: boolean;
      isCurrent?: () => boolean;
    };
type ResolveSessionTarget = (() => SessionTarget | undefined) & {
  isCurrent?: () => boolean;
  legacyFallbackAllowed?: () => boolean;
};
export const MAX_BACKGROUND_SESSION_SYNCS = 3;
/**
 * How long a queued Roost send may wait for earlier inputs, measured from the call.
 * It leaves the host's sendTurn deadline room for the queue write itself.
 */
export const QUEUED_SEND_BUDGET_MS = runtimeCalls.sendTurn.timeoutMs - 15_000;
type SessionState = {
  id: string;
  workspace: string;
  doc: LoroDoc;
  target?: SessionTarget;
  resolveTarget?: ResolveSessionTarget;
  scopeIsCurrent?: () => boolean;
  historyReady?: boolean;
  historyReadable?: boolean;
  historySubscriptionFailure?: string;
  historySync?: RoostHistorySyncState;
  streamReady?: boolean;
  roostReader?: Awaited<ReturnType<typeof createUpstreamRoostHistory>>;
  roostWindow?: RoostWindow;
  roostMetadata?: Record<string, unknown>[];
  roostTail?: Promise<void>;
  roostLoading?: boolean;
  /**
   * Loro transcript window: the id of its first user entry, `null` for the
   * whole history, unset until the first ready projection fixes it.
   */
  historyAnchor?: string | null;
  resumeHistoryStart?: number;
  /** The last projection dropped window turns to fit the host envelope budget. */
  historyClipped?: boolean;
  client: StreamsClient;
  controller: AbortController;
  /** The read in flight, so a failed probe can restart it. */
  readController?: AbortController;
  /** When the hub last answered a read of this replica. */
  readAt: number;
  ready: boolean;
  sending: boolean;
  working?: boolean;
  sendingId?: string;
  /** A queued Roost send waiting for earlier inputs; it orders later sends only. */
  queueWaitId?: string;
  recovery?: {
    inputId: string;
    controller: AbortController;
    promise: Promise<RetryPendingInputResult>;
  };
  steerReceipts?: Map<string, SteerReceipt>;
  backgroundWork?: { id: string; turnId: string; guide?: boolean };
  status: string;
  reason?: string;
  pending?: ReturnType<typeof setTimeout>;
  firstQueuedAt: number;
  lastSignal: string;
  lastUsage?: string;
  unsent: Map<
    string,
    {
      version: ReturnType<LoroDoc['version']>;
      outcome: Record<string, unknown>;
    }
  >;
  getGrant: () => Promise<Grant>;
  markDispatch: (
    sessionId: string,
    turnId: string,
    queued?: boolean,
  ) => Promise<void>;
  emit: (event: SessionRuntimeEvent) => void;
  controlWaiters?: Array<(error?: Error) => void>;
  read?: { stage: ReadStage; startedAt: number; stalled?: boolean };
  readFailures: number;
};
type ReadStage = 'bootstrap' | 'catchup' | 'poll';
const readLimit: Record<ReadStage, number> = {
  bootstrap: 15_000,
  catchup: 15_000,
  poll: 35_000,
};
const stallGrace = 15_000;
let active: SessionState | undefined;
// Working sessions use visit order; idle visits never enter the background LRU.
const sessions = new Map<string, SessionState>();
const reserved = new Set<string>();
let acceptedInputs:
  ReturnType<typeof createWorkspaceAcceptedInputs> | undefined;

/** Bind the shared workspace coordinator to the existing mobile Streams replica. */
export function startAcceptedInputs(options: {
  accountId: string;
  workspaceId: string;
  getGrant: () => Promise<Grant>;
  emit: (event: SessionRuntimeEvent) => void;
  markDispatch: SessionState['markDispatch'];
  resolveTarget: (sessionId: string) => ResolveSessionTarget;
  getDocMeta: (roomId: string) => Promise<SendMetadata | undefined>;
}) {
  const previous = acceptedInputs;
  acceptedInputs = undefined;
  void previous
    ?.dispose()
    .catch(() => console.warn('Roost input cleanup failed'));

  const operations = createSessionOperationScope();
  const withSessionStore: MobileSendPorts['sendResources']['withSessionStore'] =
    (sessionId, work, signal) =>
      operations.run(async (owned) => {
        const resolveTarget = options.resolveTarget(sessionId);
        const alreadyReserved = reserved.has(sessionId);
        try {
          await ensureSession(
            sessionId,
            options.workspaceId,
            options.getGrant,
            options.emit,
            options.markDispatch,
            resolveTarget,
            owned,
          );
          const state = sessions.get(sessionId);
          const target = resolveTarget();
          if (
            !state ||
            !sessionControlsReady(state) ||
            !state.roostReader ||
            !targetIsCurrent(state)
          )
            throw new Error('session_not_ready');
          if (
            target?.backend !== 'roost' ||
            target.machineId !==
              state.roostReader.sessionData.inputAcceptance.targetMachineId
          )
            throw new Error('session_owner_changed');
          const signal = AbortSignal.any([owned, state.controller.signal]);
          const sessionData = state.roostReader.sessionData;
          const before = state.doc.version();
          let staged: LoroDoc | undefined;
          const store: MobileSendStore = {
            sessionData,
            waitUntilSynced: (signal = owned) =>
              waitForSessionControls(state, signal),
            getState: () => (staged ?? state.doc).toJSON(),
            setState: (change) => {
              const doc = (staged ??= state.doc.fork());
              const receipts = doc.getMap('humanInputReceipts');
              const draft = {
                humanInputReceipts: receipts.toJSON() as Record<
                  string,
                  { userId: string }
                >,
              };
              change(draft);
              for (const [key, value] of Object.entries(
                draft.humanInputReceipts ?? {},
              ))
                if (JSON.stringify(receipts.get(key)) !== JSON.stringify(value))
                  receipts.set(key, value);
              doc.commit();
            },
          };
          try {
            const value = await work(store, signal);
            signal.throwIfAborted();
            if (!targetIsCurrent(state)) throw new Error('workspace_changed');
            if (staged) {
              // Only a successful Streams write updates the live control document.
              const update = staged.export({ mode: 'update', from: before });
              const saved = await state.client.append({
                part: {
                  contentType: 'application/octet-stream',
                  body: encodeFrame(update),
                },
              });
              if (!saved.ok) throw new Error(saved.result.code);
              state.doc.import(update);
            }
            signal.throwIfAborted();
            return value;
          } finally {
            staged?.free();
          }
        } finally {
          if (!alreadyReserved && (resolveTarget.isCurrent?.() ?? true))
            releaseReserve(sessionId);
        }
      }, signal);

  const runtimeForDelivery = (
    deliverySignal?: AbortSignal,
  ): MobileSendPorts => {
    const request = async (
      machineId: string,
      method: string,
      params: Record<string, unknown>,
    ) => {
      const sessionId = params.sessionId;
      if (typeof sessionId !== 'string') throw new Error('session_not_ready');
      const resolve = options.resolveTarget(sessionId);
      const checkTarget = () => {
        const target = resolve();
        if (target?.backend !== 'roost' || target.machineId !== machineId)
          throw new Error('session_owner_changed');
      };
      const grant = async () => {
        checkTarget();
        const value = await options.getGrant();
        checkTarget();
        return value;
      };
      const deadline = AbortSignal.timeout(35000);
      const reply = await machineRpc(
        options.workspaceId,
        machineId,
        method,
        params,
        grant,
        deliverySignal ? AbortSignal.any([deliverySignal, deadline]) : deadline,
      );
      return reply.error ? null : reply.result;
    };
    return {
      repo: { getDocMeta: options.getDocMeta },
      writer: {
        async upsertDocMeta(roomId, patch) {
          if (!roomId.startsWith('session-') || !patch.latestUserMsgId)
            throw new Error('invalid_dispatch_metadata');
          const sessionId = roomId.slice('session-'.length);
          const resolve = options.resolveTarget(sessionId);
          if (resolve()?.backend !== 'roost')
            throw new Error('session_owner_changed');
          await options.markDispatch(sessionId, patch.latestUserMsgId);
        },
      },
      sendResources: {
        run: operations.run,
        withSessionStore: (id, work, signal) =>
          withSessionStore(id, work, signal ?? deliverySignal),
      },
      requestSessionSteer: (id, params) => request(id, 'session/steer', params),
      requestSessionDispatchTurn: (id, params) =>
        request(id, 'session/dispatch-turn', params),
    };
  };
  const input = createWorkspaceAcceptedInputs({
    accountId: roostStorageAccount(options.accountId),
    workspaceId: options.workspaceId,
    runtime: runtimeForDelivery(),
    runtimeForDelivery,
    async validateLocalAttachments(send) {
      const config = send.entry.inputConfig as
        { inputBlocks?: unknown } | undefined;
      const blocks = Array.isArray(config?.inputBlocks)
        ? config.inputBlocks
        : [];
      const invalid = blocks.some(
        (block: any) =>
          block?.type === 'local_attachment' &&
          (!send.targetMachineId ||
            block.machineId !== send.targetMachineId ||
            typeof block.path !== 'string' ||
            !block.path.trim()),
      );
      if (invalid) throw new Error('local_attachment_unsupported');
    },
    async visible(send) {
      return (
        sessions
          .get(send.sessionId)
          ?.roostWindow?.turns.some((turn) => turn.id === send.id) === true
      );
    },
    onGuideOutcome(sessionId, inputId, expectedTurnId, applied) {
      const state = sessions.get(sessionId);
      if (
        !state ||
        state.workspace !== options.workspaceId ||
        !targetIsCurrent(state)
      )
        return;
      state.steerReceipts ??= new Map();
      state.steerReceipts.set(inputId, {
        targetId: expectedTurnId,
        state:
          applied === undefined
            ? 'confirming'
            : applied
              ? 'accepted'
              : 'unknown',
      });
      const background = state.backgroundWork;
      if (
        applied !== undefined &&
        background?.guide &&
        background.turnId === inputId
      ) {
        state.backgroundWork = undefined;
        state.emit({
          type: 'sessionCache',
          sessionId,
          backgroundWork: {
            id: background.id,
            state: applied ? 'completed' : 'waiting',
          },
        });
      }
      scheduleEmit(state, state.status);
    },
  });
  const owner = {
    ...input,
    async dispose() {
      try {
        await input.dispose();
      } finally {
        await operations.dispose();
      }
    },
  };
  owner.subscribe(() => {
    for (const state of sessions.values())
      if (state.workspace === options.workspaceId)
        scheduleEmit(state, state.status);
  });
  acceptedInputs = owner;
  void owner.resume().catch(() => {});
}
export function resumeAcceptedInputs() {
  void acceptedInputs?.resume().catch(() => {});
}
export function resumeSessions() {
  wakeSessionReads();
  for (const state of sessions.values()) state.roostReader?.wake();
}
export async function stopAcceptedInputs() {
  const owner = acceptedInputs;
  acceptedInputs = undefined;
  await owner?.dispose();
}
export const retainedSessionIds = () => [...sessions.keys()];
export const reservedSessionIds = () => [...reserved];
const historyList = (state: SessionState) => {
  if (!state.roostWindow) return state.doc.getList('history');
  const turns = state.roostWindow.turns;
  return {
    length: turns.length,
    get: (index: number) => turns[index],
    toJSON: () => turns,
  };
};
const targetIsCurrent = (state: SessionState) =>
  (state.scopeIsCurrent?.() ?? true) &&
  (state.target?.backend !== 'roost' ||
    !state.target.isCurrent ||
    state.target.isCurrent());
const sessionControlsReady = (state: SessionState) =>
  !state.controller.signal.aborted &&
  state.status !== 'offline' &&
  (state.target?.backend === 'roost'
    ? state.streamReady === true && state.historyReadable === true
    : state.ready);
const sessionSendReady = (state: SessionState) =>
  sessionControlsReady(state) &&
  (state.target?.backend !== 'roost' || state.roostMetadata !== undefined);
const sessionGrant = async (state: SessionState) => {
  if (!targetIsCurrent(state)) throw new Error('workspace_changed');
  const grant = await state.getGrant();
  if (!targetIsCurrent(state)) throw new Error('workspace_changed');
  return grant;
};
export const sessionDoc = (id: string) => {
  const state = sessions.get(id);
  return state && targetIsCurrent(state) ? state.doc : undefined;
};
const snapshot = (state: SessionState) => ({
  ...state.doc.toJSON(),
  history: historyList(state).toJSON(),
});
export const sessionHistory = (id: string) => {
  const state = sessions.get(id);
  return state?.ready && targetIsCurrent(state)
    ? historyList(state).toJSON()
    : undefined;
};

/** Capture the full owner history for whole-conversation exports. */
export async function readyHistory(
  id: string,
): Promise<Record<string, unknown>[]> {
  const state = sessions.get(id);
  if (!state?.ready || !targetIsCurrent(state))
    throw new Error('session_not_ready');
  if (state.target?.backend !== 'roost') return historyList(state).toJSON();
  if (!state.roostReader) throw new Error('session_not_ready');
  const { history } = await state.roostReader.sessionData.snapshots.capture();
  if (sessions.get(id) !== state || !targetIsCurrent(state))
    throw new Error('workspace_changed');
  return history;
}
function installHistory(state: SessionState, window: RoostWindow) {
  state.roostWindow = window;
  void acceptedInputs
    ?.acknowledgeLanded(window.turns.map((turn) => turn.id))
    .catch(() => {});
}

export function canUseLegacyHistory(doc: LoroDoc, allowed: boolean) {
  return (
    allowed &&
    doc.getList('history').length > 0 &&
    doc.getByPath('roostHistoryCursor/cursor') === undefined
  );
}
function queueRoostRead(state: SessionState, work: () => Promise<void>) {
  const next = (state.roostTail ?? Promise.resolve()).then(work);
  state.roostTail = next.catch(() => {});
  return next;
}

async function waitForAcceptedInputSave(
  owner: NonNullable<typeof acceptedInputs>,
  sessionId: string,
  inputId: string,
) {
  await owner.capturePredecessors(sessionId);
  if (
    owner !== acceptedInputs ||
    !owner.getSnapshot().some((send) => send.id === inputId && send.persisted)
  )
    throw new Error('input_storage_unavailable');
}

export async function cancelRoostInputs(ids: readonly string[]) {
  if (ids.length) await acceptedInputs?.cancelSessions(ids);
}

export async function actOnPendingInput(
  sessionId: string,
  inputId: string,
  action: 'retry' | 'forget',
  recoveryTarget?: () => { userId: string; machineId: string },
) {
  const state = sessions.get(sessionId);
  if (state?.target?.backend === 'loro') {
    if (!targetIsCurrent(state)) throw new Error('workspace_changed');
    if (action === 'retry') {
      if (!recoveryTarget) throw new Error('session_not_ready');
      if (state.sending || state.queueWaitId)
        throw new Error('send_in_progress');
      if (state.recovery) {
        if (state.recovery.inputId !== inputId)
          throw new Error('send_in_progress');
        return state.recovery.promise;
      }
      const controller = new AbortController();
      const promise = recoverLoroInput(
        state,
        inputId,
        recoveryTarget,
        controller.signal,
      );
      const recovery = { inputId, controller, promise };
      state.recovery = recovery;
      try {
        return await promise;
      } finally {
        if (state.recovery === recovery) state.recovery = undefined;
      }
    }
    if (state.recovery?.inputId === inputId) {
      state.recovery.controller.abort();
      state.recovery = undefined;
    }
    // Loro has no record in the Roost pending-input owner. The caller removes
    // its native Outbox record; this never claims to cancel remote work.
    return { state: 'pending' as const };
  }
  const owner = acceptedInputs;
  if (!owner) throw new Error('session_not_ready');
  await owner.refresh();
  const input = owner
    .getSnapshot()
    .find((send) => send.sessionId === sessionId && send.id === inputId);
  if (!input || owner !== acceptedInputs) throw new Error('session_not_ready');
  if (action === 'forget') await owner.cancel(inputId);
  else if (input.error) owner.retry(inputId);
  return { state: 'pending' as const };
}

/** Reconcile an explicit user request; never replay the original history write. */
async function recoverLoroInput(
  state: SessionState,
  inputId: string,
  resolve: () => { userId: string; machineId: string },
  cancelled: AbortSignal,
): Promise<RetryPendingInputResult> {
  const target = resolve();
  const signal = AbortSignal.any([
    state.controller.signal,
    cancelled,
    AbortSignal.timeout(25_000),
  ]);
  const check = () => {
    signal.throwIfAborted();
    if (sessions.get(state.id) !== state || !targetIsCurrent(state))
      throw new Error('workspace_changed');
    const current = resolve();
    if (
      current.machineId !== target.machineId ||
      current.userId !== target.userId
    )
      throw new Error('workspace_changed');
  };
  // The session replica may contain the unacknowledged local write. Only a
  // fresh server snapshot/catch-up proves that the original input was saved.
  const remote = new LoroDoc();
  try {
    check();
    const initial = await state.client.bootstrap({ signal });
    check();
    if (!initial.ok) throw new Error(initial.result.code);
    let size = 0;
    const consume = (bytes: Uint8Array, snapshot = false) => {
      size += bytes.length;
      if (size > 32 * 1024 * 1024) throw new Error('session_limit');
      if (snapshot) remote.import(unpack(bytes));
      else importUpdates(remote, bytes);
    };
    const data = initial.result;
    if (data.snapshotOffset !== '-1' && data.snapshot)
      consume(data.snapshot.body, true);
    for (const part of data.updates) consume(part.body);
    let { nextOffset: offset, cursor, upToDate } = data;
    for (let pages = 0; !upToDate; pages++) {
      if (pages >= 100) throw new Error('session_limit');
      const next = await state.client.readOnce({ offset, cursor, signal });
      check();
      if (!next.ok) throw new Error(next.result.code);
      if (next.result.closed) throw new Error('stream_closed');
      if (next.result.payload) consume(next.result.payload.body);
      if (next.result.nextOffset === offset && !next.result.upToDate)
        throw new Error('stalled_cursor');
      ({ nextOffset: offset, cursor, upToDate } = next.result);
    }
    const history = remote.getList('history').toJSON() as Record<string, any>[];
    const entry = history.find(
      (entry) => entry.id === inputId && entry.role === 'user',
    );
    if (!entry) throw new Error('input_not_confirmed');
    if (entry.userId !== target.userId) throw new Error('input_owner_changed');
    if (
      ['handled', 'failed', 'canceled'].includes(entry.status) ||
      history.some(
        (entry) => entry.role === 'assistant' && entry.userTurnId === inputId,
      )
    )
      return { state: 'settled' };
    if (entry.status === 'processing') return { state: 'accepted' };
    if (
      !['pending', 'seen'].includes(entry.status) ||
      entry.inputConfig?._lodyDeliveryKind === 'steer' ||
      (remote.getMovableList('mq').toJSON() as Record<string, any>[]).some(
        (item) => item.userTurnId === inputId,
      )
    )
      throw new Error('input_not_recoverable');
    if (!entry.inputConfig || typeof entry.timestamp !== 'string')
      throw new Error('input_not_recoverable');
    check();
    const reply = await machineRpc(
      state.workspace,
      target.machineId,
      'session/dispatch-turn',
      {
        sessionId: state.id,
        userTurnId: inputId,
        userId: target.userId,
        timestamp: entry.timestamp,
        inputConfig: entry.inputConfig,
      },
      async () => {
        check();
        const grant = await sessionGrant(state);
        check();
        return grant;
      },
      signal,
    );
    check();
    const result = reply.result as
      { accepted?: boolean; disposition?: string } | undefined;
    if (!result?.accepted) throw new Error('dispatch_unconfirmed');
    return {
      state: result.disposition === 'already-terminal' ? 'settled' : 'accepted',
    };
  } finally {
    remote.free();
  }
}

/** User turns in a Loro transcript's first window and in each older page. */
const HISTORY_PAGE_TURNS = 6;
/** UTF-8 budget per envelope; the iOS host replaces envelopes above 12 MiB with an overflow marker. */
const ENVELOPE_BUDGET_BYTES = 8 * 1024 * 1024;
const entryField = (entry: unknown, key: string) =>
  entry instanceof LoroMap ? entry.get(key) : (entry as any)?.[key];
/** Index of the `turns`-th user entry before `end`, or 0 when fewer exist. */
function pageStart(history: LoroList, end: number, turns: number) {
  let seen = 0;
  for (let i = end - 1; i > 0; i--)
    if (entryField(history.get(i), 'role') === 'user' && ++seen === turns)
      return i;
  return 0;
}
function userTurnsFrom(history: LoroList, start: number) {
  let count = 0;
  for (let i = start; i < history.length; i++)
    if (entryField(history.get(i), 'role') === 'user') count += 1;
  return count;
}
/**
 * Loro sessions keep the whole document locally, but only a window of the
 * transcript crosses to the host. The window starts at a user entry, follows
 * new entries and grows backwards only on an explicit older-history request.
 */
function loroWindowStart(state: SessionState, history: LoroList) {
  if (state.historyAnchor === null) return 0;
  if (state.historyAnchor !== undefined)
    for (let i = history.length - 1; i >= 0; i--)
      if (entryField(history.get(i), 'id') === state.historyAnchor) return i;
  const latest = pageStart(history, history.length, HISTORY_PAGE_TURNS);
  const start =
    state.ready &&
    state.resumeHistoryStart !== undefined &&
    state.resumeHistoryStart < latest
      ? pageStart(history, state.resumeHistoryStart + 1, 1)
      : latest;
  const anchor = entryField(history.get(start), 'id');
  // An empty or still-bootstrapping replica must not fix the window at 0.
  if (state.ready && history.length) {
    state.historyAnchor =
      start === 0 ? null : typeof anchor === 'string' ? anchor : undefined;
    state.resumeHistoryStart = undefined;
  }
  return start;
}

function isRoostHistorySuperseded(error: unknown): boolean {
  return (
    error instanceof Error &&
    (error.message === 'history_observation_superseded' ||
      error.message === 'Roost history observation was superseded' ||
      error.message === 'Roost cached page cursor needs rebasing' ||
      error.message === 'Roost history source changed')
  );
}

export async function loadOlderSession(sessionId: string) {
  const state = sessions.get(sessionId);
  if (!state || !targetIsCurrent(state)) throw new Error('session_not_ready');
  if (state.target?.backend !== 'roost') {
    const history = state.doc.getList('history');
    const start = loroWindowStart(state, history);
    if (start === 0 || state.historyClipped) return;
    const next = pageStart(history, start, HISTORY_PAGE_TURNS);
    const anchor = entryField(history.get(next), 'id');
    state.historyAnchor =
      next === 0 ? null : typeof anchor === 'string' ? anchor : null;
    scheduleEmit(state, state.status);
    return;
  }
  if (!state.roostReader || !state.roostWindow?.cursor || state.roostLoading)
    return;
  state.roostLoading = true;
  scheduleEmit(state, state.status);
  try {
    await queueRoostRead(state, async () => {
      if (!state.roostWindow?.cursor) return;
      const next = await state.roostReader!.older(state.roostWindow);
      if (sessions.get(sessionId) !== state || !targetIsCurrent(state)) return;
      installHistory(state, next);
      if (next.start === 0)
        state.roostMetadata = next.turns.map((turn) => ({ ...turn }));
    });
  } catch (error) {
    // The active reader will refresh the window after a source change.
    if (!isRoostHistorySuperseded(error)) throw error;
  } finally {
    state.roostLoading = false;
    if (sessions.get(sessionId) === state) scheduleEmit(state, state.status);
  }
}
function traceCode(value: unknown) {
  const pattern = /^[a-z][a-z0-9_]{0,47}$/;
  if (typeof value === 'string') return pattern.test(value) ? value : undefined;
  if (!(value instanceof Error)) return undefined;
  if (pattern.test(value.message)) return value.message;
  return value.name
    .toLowerCase()
    .replace(/[^a-z0-9_]/g, '_')
    .slice(0, 48);
}
/**
 * Sends that never move the dispatch pointer (a guide, an edit and resend)
 * still count as sending a message: the runtime clears Later / Settled then.
 * Dispatches report through `markDispatch` instead.
 */
let sendObserver: (sessionId: string) => void = () => {};
export function setSessionSendObserver(observer: typeof sendObserver) {
  sendObserver = observer;
}
let traceSink: (event: SessionTrace) => void = () => {};
export function setSessionTraceSink(sink: typeof traceSink) {
  traceSink = sink;
}
function trace(
  state: SessionState,
  event: SessionTrace['event'],
  fields: Omit<SessionTrace, 'sessionId' | 'event'> = {},
) {
  traceSink({ sessionId: state.id, event, ...fields });
}
async function readAttempt<T>(
  state: SessionState,
  stage: ReadStage,
  read: () => Promise<T>,
) {
  const attempt = { stage, startedAt: Date.now() };
  state.read = attempt;
  try {
    const result = await read();
    const ageMs = Date.now() - attempt.startedAt;
    if (ageMs > readLimit[stage] + stallGrace)
      trace(state, 'slow', { stage, ageMs, attempts: state.readFailures + 1 });
    state.readFailures = 0;
    return result;
  } catch (error) {
    if (!state.controller.signal.aborted) {
      state.readFailures += 1;
      trace(state, 'retry', {
        stage,
        code: traceCode(error),
        ageMs: Date.now() - attempt.startedAt,
        attempts: state.readFailures,
      });
    }
    throw error;
  } finally {
    if (state.read === attempt) state.read = undefined;
  }
}
export function traceStalledReads(now = Date.now()) {
  for (const state of sessions.values()) {
    const read = state.read;
    if (!read || read.stalled) continue;
    const ageMs = now - read.startedAt;
    if (ageMs < readLimit[read.stage] + stallGrace) continue;
    read.stalled = true;
    trace(state, 'stalled', { stage: read.stage, ageMs, status: state.status });
  }
}
export function traceSessionResume() {
  const state = active;
  if (!state) return;
  const read = state.read;
  trace(state, 'resume', {
    status: state.status,
    ...(read ? { stage: read.stage, ageMs: Date.now() - read.startedAt } : {}),
  });
}
function signalOf(state: SessionState, status: string) {
  const history = historyList(state);
  let finished = 0;
  for (let i = 0; i < history.length; i++) {
    const entry = history.get(i);
    if (
      (entry instanceof LoroMap
        ? entry.get('finished')
        : (entry as any)?.finished) === true
    )
      finished++;
  }
  const awaiting = state.doc.getMap('session').get('awaitingUserSince') != null;
  return `${status}|${awaiting}|${finished}|${sessionControlsReady(state)}|${sessionSendReady(state)}`;
}
function backgroundStatus(
  state: SessionState,
  reply: { finished?: boolean } | undefined,
) {
  if (state.status === 'offline') return 'failed';
  if (state.status !== 'live') return 'syncing';
  if (!reply) return 'sent';
  if (reply.finished === true) return 'completed';
  if (state.doc.getMap('session').get('awaitingUserSince') != null)
    return 'waiting';
  return 'receiving';
}
/** The newest reply to `turnId`, read field by field from the end of history. */
function latestReply(state: SessionState, turnId: string) {
  const history = state.doc.getList('history');
  for (let i = history.length - 1; i >= 0; i--) {
    const entry = history.get(i);
    const get = (key: string) =>
      entry instanceof LoroMap
        ? plainField(entry.get(key))
        : (entry as any)?.[key];
    if (get('role') === 'assistant' && get('userTurnId') === turnId)
      return { finished: get('finished') };
  }
  return undefined;
}
function plainField(value: unknown): any {
  if (value instanceof LoroText) return value.toString();
  return value instanceof LoroMap || value instanceof LoroList
    ? value.toJSON()
    : value;
}
function backgroundProgress(state: SessionState) {
  const work = state.backgroundWork;
  if (!work || work.guide) return undefined;
  const reply = state.roostWindow
    ? (state.roostWindow.turns.findLast(
        (entry) =>
          entry?.role === 'assistant' && entry.userTurnId === work.turnId,
      ) as { finished?: boolean } | undefined)
    : latestReply(state, work.turnId);
  const status = backgroundStatus(state, reply);
  if (['completed', 'waiting', 'failed'].includes(status))
    state.backgroundWork = undefined;
  return { id: work.id, state: status } as const;
}
type QuotaProjection = Pick<
  SessionUsage,
  'context' | 'quota' | 'quotaEligible' | 'modelId' | 'modelLabel'
>;
let readUsage: (
  sessionId: string,
  modelId?: string,
) => QuotaProjection = () => ({
  context: null,
  quota: null,
  quotaEligible: false,
});
export function setSessionUsageReader(read: typeof readUsage) {
  readUsage = read;
}
/** Catalog updates (quota and context occupancy) reuse retained session owners; no new stream or timer. */
export function refreshSessionUsage() {
  for (const state of sessions.values()) {
    const history = state.doc.getList('history').toJSON() as any[];
    const modelId = history.findLast((e) => e?.role === 'user')?.inputConfig
      ?.modelId;
    const usage = JSON.stringify(readUsage(state.id, modelId));
    if (usage !== state.lastUsage) flush(state);
  }
}
function flush(state: SessionState) {
  clearTimeout(state.pending);
  state.pending = undefined;
  state.firstQueuedAt = 0;
  if (sessions.get(state.id) !== state || !targetIsCurrent(state)) return;
  const loro = state.target?.backend !== 'roost';
  const history = state.doc.getList('history');
  let start = loro ? loroWindowStart(state, history) : 0;
  const project = () =>
    projectSession(
      state.doc,
      state.status,
      state.reason,
      new Map(
        [...state.unsent].map(([key, pending]) => [key, pending.outcome]),
      ),
      state.steerReceipts,
      state.roostWindow?.turns,
      state.roostMetadata,
      start,
    );
  state.historyClipped = false;
  let snapshot = project();
  // The composer comes from the whole history, so every window shares this catalog usage.
  const quota = readUsage(state.id, snapshot.composer?.modelId);
  state.lastUsage = JSON.stringify(quota);
  const finish = (next: typeof snapshot) => {
    if (next.usage) next.usage = { ...next.usage, ...quota };
    if (loro) next.historyHasMore = start > 0 && !state.historyClipped;
    return next;
  };
  snapshot = finish(snapshot);
  if (state.target?.backend === 'roost') {
    snapshot.controlReady = sessionControlsReady(state);
    snapshot.sendReady = sessionSendReady(state);
    snapshot.historyHasMore = !!state.roostWindow?.cursor;
    snapshot.historyLoading = state.roostLoading === true;
    snapshot.historySync = state.historySync;
    const pending = (acceptedInputs?.getSnapshot() ?? []).filter(
      (send) =>
        send.sessionId === state.id &&
        !snapshot.entries.some((entry) => entry.id === send.id),
    );
    snapshot.pendingRoostInputs = projectPendingInputs(
      state.doc,
      pending.map((send) => send.entry),
    ).map((entry, index) => ({
      ...entry,
      inputState: pending[index].inputState,
      inputRetryable: !!pending[index].error,
    }));
    if (state.roostMetadata)
      snapshot.billableTurnCount = billableTurnCount({
        history: state.roostMetadata,
        mq: state.doc.getMovableList('mq').toJSON(),
      });
    else delete snapshot.billableTurnCount;
  }
  let session = JSON.stringify(snapshot);
  // A window of long turns can still exceed the host limit: keep the newest
  // half of its turns until it fits or one turn remains. Older history then
  // stays unavailable, because loading it would exceed the limit again.
  while (loro && envelopeBytes(session) > ENVELOPE_BUDGET_BYTES) {
    const turns = userTurnsFrom(history, start);
    if (turns <= 1) break;
    start = pageStart(history, history.length, Math.ceil(turns / 2));
    state.historyClipped = true;
    snapshot = finish(project());
    session = JSON.stringify(snapshot);
  }
  state.emit({
    type: active === state ? 'session' : 'sessionCache',
    sessionId: state.id,
    synced: state.status === 'live',
    ...(active === state &&
    snapshot.entries.length &&
    (state.status === 'live' || snapshot.controlReady)
      ? { historyStart: loro ? start : state.roostWindow?.start }
      : {}),
    backgroundWork: backgroundProgress(state),
    session,
  });
}
const encoder = new TextEncoder();
/** A UTF-16 code unit encodes to at most three UTF-8 bytes. */
const envelopeBytes = (json: string) =>
  json.length * 3 <= ENVELOPE_BUDGET_BYTES
    ? json.length
    : encoder.encode(json).length;
function isWorking(state: SessionState) {
  if (state.doc.getMovableList('mq').length) return true;
  const history = historyList(state);
  let replied = false;
  let latestUser = true;
  for (let i = history.length - 1; i >= 0; i--) {
    const entry = history.get(i);
    const get = (key: string) =>
      entry instanceof LoroMap ? entry.get(key) : (entry as any)?.[key];
    if (get('role') === 'assistant') {
      if (!get('finished')) return true;
      replied = true;
    }
    if (get('role') === 'user' && latestUser) {
      // A submitted turn is working before its first assistant event arrives.
      if (
        !replied &&
        ['pending', 'seen', 'processing', 'pending_apply'].includes(
          get('status'),
        )
      )
        return true;
      latestUser = false;
    }
  }
  return false;
}
function scheduleEmit(state: SessionState, status: string, reason?: string) {
  if (status === 'syncing') reason ??= state.historySubscriptionFailure;
  if (status !== state.status && sessions.get(state.id) === state)
    trace(state, 'status', { status, code: traceCode(reason) });
  state.status = status;
  state.reason = reason;
  if (sessions.get(state.id) !== state) return;
  if (state.ready) {
    const working = isWorking(state);
    if (working && state.working !== true) {
      sessions.delete(state.id);
      sessions.set(state.id, state);
    }
    state.working = working;
    trimSessions();
    if (sessions.get(state.id) !== state) return;
  }
  clearTimeout(state.pending);
  const now = Date.now();
  const foreground = active === state;
  const signal = foreground ? signalOf(state, status) : '';
  const maxDelay = foreground ? 200 : 1000;
  if (
    (foreground && signal !== state.lastSignal) ||
    (state.firstQueuedAt && now - state.firstQueuedAt >= maxDelay)
  ) {
    state.lastSignal = signal;
    flush(state);
    return;
  }
  if (!state.firstQueuedAt) state.firstQueuedAt = now;
  state.pending = setTimeout(() => flush(state), foreground ? 100 : 1000);
}
function settleControls(state: SessionState, error?: Error) {
  const waiters = state.controlWaiters;
  state.controlWaiters = undefined;
  waiters?.forEach((waiter) => waiter(error));
}
function evict(state: SessionState) {
  settleControls(state, new Error('session_not_ready'));
  // Publish completion before retiring an idle replica's background allowance.
  if (state.ready) flush(state);
  if (state.backgroundWork) {
    state.emit({
      type: 'sessionCache',
      sessionId: state.id,
      backgroundWork: { id: state.backgroundWork.id, state: 'failed' },
    });
    state.backgroundWork = undefined;
  }
  clearTimeout(state.pending);
  state.controller.abort();
  releaseProjection(state.doc);
  sessions.delete(state.id);
}
function trimSessions() {
  const before = sessions.size;
  const notify = (active ?? sessions.values().next().value)?.emit;
  const background: SessionState[] = [];
  for (const state of sessions.values()) {
    if (state === active || reserved.has(state.id)) continue;
    if (state.working === false) evict(state);
    else if (state.working === true) background.push(state);
  }
  for (const state of background.slice(0, -MAX_BACKGROUND_SESSION_SYNCS))
    evict(state);
  if (sessions.size !== before)
    notify?.({
      type: 'sessionSubscriptions',
      ids: retainedSessionIds(),
      reserved: reservedSessionIds(),
    });
}
export function closeSession() {
  if (active?.working === undefined && active && !reserved.has(active.id))
    evict(active);
  active = undefined;
  trimSessions();
}
export function releaseDeletedSessions(ids: string[]) {
  for (const id of ids) {
    reserved.delete(id);
    const state = sessions.get(id);
    if (active === state) active = undefined;
    if (state) evict(state);
  }
}
export function releaseReserve(id: string) {
  if (!reserved.delete(id)) return;
  const state = sessions.get(id);
  if (state) {
    sessions.delete(id);
    sessions.set(id, state);
  }
  trimSessions();
}
export function stopSessions() {
  for (const state of sessions.values()) {
    settleControls(state, new Error('session_not_ready'));
    clearTimeout(state.pending);
    state.controller.abort();
    releaseProjection(state.doc);
  }
  sessions.clear();
  reserved.clear();
  uncertain.clear();
  active = undefined;
}
// Turn ids whose append result was lost. This runtime never writes them again.
const uncertain = new Set<string>();
/** Replaces a replica that holds a write the hub never acknowledged with a fresh read. */
function resync(state: SessionState) {
  if (sessions.get(state.id) !== state) return;
  const foreground = active === state;
  // The unacknowledged write must not be published as session history.
  state.ready = false;
  evict(state);
  if (foreground) active = undefined;
  void openSession(
    state.id,
    state.workspace,
    state.getGrant,
    state.emit,
    state.markDispatch,
    foreground,
    state.resolveTarget,
    undefined,
    state.target,
    state.client,
  );
}
/**
 * Appends exactly once even when the request is sent twice: the hub drops a
 * repeat of one producer tuple, so the client may retry a lost acknowledgement.
 */
export const appendOnce = (
  client: StreamsClient,
  part: { contentType: string; body: Uint8Array | string },
) =>
  client.append({
    part,
    producer: { producerId: crypto.randomUUID(), epoch: 0, seq: 0 },
  });
/** A replica is taken as connected for this long after the hub answered it. */
export const REPLICA_FRESH_MS = 3000;
/**
 * Asks the hub before a write when the replica has not heard from it lately:
 * a route that died silently is found while nothing has been written yet.
 */
async function reachable(state: SessionState) {
  if (Date.now() - state.readAt < REPLICA_FRESH_MS) return true;
  const probe = await state.client.head({ signal: AbortSignal.timeout(5000) });
  if (probe.ok) {
    state.readAt = Date.now();
    return true;
  }
  // A stalled read would hold the replica until its own timeout; start it again.
  state.readController?.abort();
  return false;
}
/**
 * Settles a turn whose send result was lost. A ready replica was read after
 * every write this runtime attempted, so a turn it lacks never reached the hub.
 */
export function confirmTurn(args: { sessionId: string; id: string }) {
  const state = sessions.get(args.sessionId);
  if (!state?.ready || state.sending) return { state: 'pending' as const };
  const raw = state.doc.toJSON();
  if (((raw.mq ?? []) as any[]).some((item) => item?.userTurnId === args.id))
    return { state: 'queued' as const };
  const history = (raw.history ?? []) as any[];
  const index = history.findIndex((entry) => entry?.id === args.id);
  if (index < 0)
    // A late copy of the lost write must never share an id with the retry.
    return { state: 'absent' as const, retryId: crypto.randomUUID() };
  return {
    state: 'uploaded' as const,
    // Only the newest turn, still untouched by the machine, may need its pointer.
    // Any client viewing the session marks it `seen`; only the machine moves it on.
    undispatched:
      ['pending', 'seen'].includes(history[index].status) &&
      !history
        .slice(index + 1)
        .some((entry) => entry?.role === 'user' || entry?.role === 'assistant'),
  };
}
export function unpack(bytes: Uint8Array) {
  return bytes[0] === 0x28 &&
    bytes[1] === 0xb5 &&
    bytes[2] === 0x2f &&
    bytes[3] === 0xfd
    ? decompress(bytes)
    : bytes;
}
export function importUpdates(doc: LoroDoc, bytes: Uint8Array) {
  for (const frame of decodeFrames(bytes)) doc.import(frame);
}
export async function clientFor(id: string, getGrant: () => Promise<Grant>) {
  const grant = await getGrant();
  return new StreamsClient({
    url: `${grant.gatewayBaseUrl.replace(/\/$/, '')}/ds/lody/${encodeURIComponent(id)}`,
    auth: async () => (await getGrant()).token,
    retry: { maxAttempts: 1 },
    // Keep writes within the native command budget; SDK 0.12+ defaults uploads to 60s.
    timeout: {
      connectTimeoutMs: 15000,
      uploadTimeoutMs: 15000,
      pollTimeoutMs: 35000,
    },
  });
}
export async function ensureSession(
  id: string,
  workspace: string,
  getGrant: () => Promise<Grant>,
  emit: (event: SessionRuntimeEvent) => void,
  markDispatch: (
    sessionId: string,
    turnId: string,
    queued?: boolean,
  ) => Promise<void>,
  resolveTarget?: ResolveSessionTarget,
  signal?: AbortSignal,
) {
  if ([...sessions.values()].some((state) => state.workspace !== workspace))
    stopSessions();
  reserved.add(id);
  const result = await openSession(
    id,
    workspace,
    getGrant,
    emit,
    markDispatch,
    false,
    resolveTarget,
  );
  const state = sessions.get(id);
  if (!state) throw new Error('session_not_ready');
  await waitForSessionControls(state, signal);
  return result;
}

async function waitForSessionControls(
  state: SessionState,
  signal?: AbortSignal,
) {
  signal?.throwIfAborted();
  state.controller.signal.throwIfAborted();
  if (sessionControlsReady(state)) return;
  await new Promise<void>((resolve, reject) => {
    const abort = () => done(signal!.reason ?? new Error('cancelled'));
    const done = (error?: Error) => {
      state.controlWaiters = state.controlWaiters?.filter(
        (item) => item !== done,
      );
      signal?.removeEventListener('abort', abort);
      if (error) reject(error);
      else resolve();
    };
    (state.controlWaiters ??= []).push(done);
    signal?.addEventListener('abort', abort, { once: true });
  });
}
export async function openSession(
  id: string,
  workspace: string,
  getGrant: () => Promise<Grant>,
  emit: (event: SessionRuntimeEvent) => void,
  markDispatch: (
    sessionId: string,
    turnId: string,
    queued?: boolean,
  ) => Promise<void>,
  activate = true,
  resolveTarget?: ResolveSessionTarget,
  resumeHistoryStart?: number,
  initialTarget?: SessionTarget,
  initialClient?: StreamsClient,
) {
  if ([...sessions.values()].some((state) => state.workspace !== workspace))
    stopSessions();
  const existing = sessions.get(id);
  if (
    activate &&
    active &&
    active !== existing &&
    active.working === undefined &&
    !reserved.has(active.id)
  )
    evict(active);
  if (existing && existing.status !== 'offline') {
    existing.emit = emit;
    if (activate) {
      if (!existing.ready && !existing.historyReadable)
        existing.resumeHistoryStart ??= resumeHistoryStart;
      active = existing;
      sessions.delete(id);
      sessions.set(id, existing);
    }
    trimSessions();
    flush(existing);
    return 'watching';
  }
  if (existing) evict(existing);
  const controller = new AbortController();
  const state: SessionState = {
    id,
    workspace,
    target: initialTarget,
    resolveTarget,
    scopeIsCurrent: resolveTarget?.isCurrent,
    doc: new LoroDoc(),
    resumeHistoryStart,
    client: initialClient ?? (undefined as unknown as StreamsClient),
    controller,
    readAt: 0,
    ready: false,
    sending: false,
    status: 'syncing',
    firstQueuedAt: 0,
    lastSignal: '',
    unsent: new Map(),
    getGrant,
    markDispatch,
    emit,
    readFailures: 0,
  };
  if (activate) active = state;
  sessions.set(id, state);
  trimSessions();
  const event = (status: string, reason?: string) => {
    // A terminal read failure still needs a reopen even if the other reader
    // keeps receiving data or retrying.
    if (status === 'syncing' && state.status === 'offline') return;
    scheduleEmit(state, status, reason);
  };
  const retrying = (error: unknown) => {
    state.ready = false;
    event('syncing', error instanceof Error ? error.message : 'sync_failed');
  };
  const retryStream = (error: unknown) => {
    if (
      error instanceof Error &&
      (error.message === 'unauthorized' || error.message === 'forbidden')
    )
      (state.getGrant as { invalidate?: () => void }).invalidate?.();
    state.streamReady = false;
    retrying(error);
  };
  const retryHistory = (error: unknown) => {
    if (error instanceof RoostCloudHistoryRequestError && !error.retryable)
      throw error;
    state.historyReadable = false;
    state.historyReady = false;
    retrying(error);
  };
  const updateReadiness = () => {
    state.ready =
      state.status !== 'offline' &&
      state.streamReady === true &&
      (state.target?.backend !== 'roost' ||
        (state.historyReadable === true && state.historyReady === true));
    if (sessionControlsReady(state)) settleControls(state);
  };
  event('syncing');
  void (async () => {
    try {
      const data = await retrySessionRead(
        controller.signal,
        () =>
          readAttempt(state, 'bootstrap', async () => {
            state.client = await clientFor(`${workspace}:s:${id}`, () =>
              sessionGrant(state),
            );
            controller.signal.throwIfAborted();
            const initial = await state.client.bootstrap({
              signal: controller.signal,
            });
            if (!initial.ok) throw new Error(initial.result.code);
            return initial.result;
          }),
        retryStream,
      );
      if (sessions.get(id) !== state) return;
      state.readAt = Date.now();
      let size = 0;
      const consume = (bytes: Uint8Array, snapshot = false) => {
        size += bytes.length;
        if (size > 32 * 1024 * 1024) throw new Error('session_limit');
        if (snapshot) state.doc.import(unpack(bytes));
        else importUpdates(state.doc, bytes);
        state.roostReader?.wake();
      };
      if (data.snapshotOffset !== '-1' && data.snapshot)
        consume(data.snapshot.body, true);
      for (const part of data.updates) consume(part.body);
      let offset = data.nextOffset,
        cursor = data.cursor,
        upToDate = data.upToDate;
      let pages = 0;
      while (!upToDate && !controller.signal.aborted) {
        if (++pages > 100) throw new Error('session_limit');
        const next = await retrySessionRead(
          controller.signal,
          () =>
            readAttempt(state, 'catchup', async () => {
              const result = await state.client.readOnce({
                offset,
                cursor,
                signal: controller.signal,
              });
              if (!result.ok) throw new Error(result.result.code);
              return result;
            }),
          retryStream,
        );
        if (sessions.get(id) !== state) return;
        if (next.result.payload) consume(next.result.payload.body);
        if (next.result.nextOffset === offset && !next.result.upToDate)
          throw new Error('stalled_cursor');
        offset = next.result.nextOffset;
        cursor = next.result.cursor;
        upToDate = next.result.upToDate;
        if (next.result.closed) throw new Error('stream_closed');
      }
      let target: SessionTarget | undefined = resolveTarget
        ? undefined
        : { backend: 'loro' };
      if (resolveTarget) {
        try {
          target = resolveTarget();
        } catch {
          /* Wait for authoritative metadata. */
        }
        if (
          !target &&
          targetIsCurrent(state) &&
          canUseLegacyHistory(
            state.doc,
            resolveTarget.legacyFallbackAllowed?.() ?? true,
          )
        )
          target = { backend: 'loro' };
        // The catalog watcher owns network retries. This lookup reads local metadata.
        if (!target)
          target = await retrySessionRead(
            controller.signal,
            async () => {
              const value = resolveTarget();
              if (!value) throw new Error('metadata_not_ready');
              return value;
            },
            (error) => {
              const reason =
                error instanceof Error ? error.message : 'sync_failed';
              if (reason !== state.reason) event('syncing', reason);
            },
            { fixedDelayMs: 250 },
          );
      }
      if (!target) throw new Error('metadata_not_ready');
      if (sessions.get(id) !== state) return;
      state.target = target;
      if (target.backend === 'roost') {
        let cloudActive = false;
        let ownerCheckpoint: string | undefined;
        let metadataController: AbortController | undefined;
        let metadataRefreshPending = false;
        const resetMetadata = () => {
          metadataController?.abort();
          metadataController = undefined;
          metadataRefreshPending = false;
          state.roostMetadata = undefined;
        };
        const confirmHistory = () => {
          if (
            (!cloudActive && !target.live) ||
            (ownerCheckpoint &&
              ownerCheckpoint === state.roostWindow?.checkpoint)
          ) {
            state.historyReady = true;
            state.historySubscriptionFailure = undefined;
          }
          updateReadiness();
          event(state.ready ? 'live' : 'syncing');
        };
        const reader = createUpstreamRoostHistory({
          cloud: target.cloud,
          accountId: target.accountId,
          workspaceId: workspace,
          machineId: target.machineId,
          sessionId: id,
          getGrant,
          signal: controller.signal,
          isCurrent: target.isCurrent,
          patches: target.patches,
          coherentInspection: target.coherentInspection,
          incremental: target.incremental,
          live: target.live,
          getHistoryProof: target.getHistoryProof,
          onCloudRoute: (active) => {
            if (active === cloudActive) return;
            cloudActive = active;
            ownerCheckpoint = undefined;
            state.historyReady = false;
            resetMetadata();
            updateReadiness();
          },
          onHistorySync: (next) => {
            if (
              controller.signal.aborted ||
              sessions.get(id) !== state ||
              !targetIsCurrent(state)
            )
              return;
            state.historySync = next;
            scheduleEmit(state, state.status, state.reason);
          },
          onSubscription: (observation) => {
            if (
              controller.signal.aborted ||
              sessions.get(id) !== state ||
              state.status === 'offline'
            )
              return;
            if ('reason' in observation) {
              ownerCheckpoint = undefined;
              state.historySubscriptionFailure = observation.reason;
              state.historyReady = false;
              if (observation.reason === 'roost_cloud_history_changed')
                resetMetadata();
              retrying(new Error(observation.reason));
            } else {
              ownerCheckpoint = observation.checkpoint;
              if (state.historyReady) return;
              // A published replica's checkpoint includes its forward offset,
              // which can advance without a history change event. Reload the
              // window so readiness confirms against the caught-up checkpoint.
              if (
                cloudActive &&
                ownerCheckpoint !== state.roostWindow?.checkpoint
              )
                state.roostReader?.reload();
              else confirmHistory();
            }
          },
        });
        state.roostReader = reader;
        let window = await retrySessionRead(
          controller.signal,
          () => reader.latest(),
          retryHistory,
        );
        // Replay the reader's window through the same checked cursors as an
        // explicit page read. A failed optional page leaves the usable tail intact.
        const historyStart = state.resumeHistoryStart;
        if (historyStart !== undefined) {
          try {
            while (window.cursor && window.start > historyStart)
              window = await reader.older(window);
          } catch {
            controller.signal.throwIfAborted();
          }
        }
        state.resumeHistoryStart = undefined;
        if (sessions.get(id) !== state || !targetIsCurrent(state)) return;
        installHistory(state, window);
        state.historyReadable = true;
        const refreshMetadata = () => {
          if (state.roostWindow?.start === 0) {
            resetMetadata();
            state.roostMetadata = state.roostWindow.turns.map((turn) => ({
              ...turn,
            }));
            return;
          }
          // Keep the current source's coherent result while it catches up.
          // New history requests one follow-up without cancelling the current read.
          if (metadataController) {
            metadataRefreshPending = true;
            return;
          }
          const request = new AbortController();
          metadataController = request;
          const signal = AbortSignal.any([controller.signal, request.signal]);
          void retrySessionRead(
            signal,
            () => reader.metadata(),
            () => {},
          )
            .then((metadata) => {
              if (
                sessions.get(id) !== state ||
                signal.aborted ||
                !targetIsCurrent(state) ||
                state.roostWindow?.start === 0
              )
                return;
              state.roostMetadata = metadata;
              scheduleEmit(state, state.status);
            })
            .catch(() => {})
            .finally(() => {
              if (metadataController !== request) return;
              metadataController = undefined;
              if (!metadataRefreshPending || signal.aborted) return;
              metadataRefreshPending = false;
              refreshMetadata();
            });
        };
        refreshMetadata();
        reader.metadataChanged(state.roostMetadata);
        confirmHistory();
        void (async () => {
          const retryNonSuperseded = async <T>(work: () => Promise<T>) => {
            for (let attempt = 0; ; attempt++) {
              try {
                return await work();
              } catch (error) {
                if (!isRoostHistorySuperseded(error) || attempt >= 3)
                  throw error;
                controller.signal.throwIfAborted();
              }
            }
          };
          try {
            while (!controller.signal.aborted) {
              const next = await retrySessionRead(
                controller.signal,
                () => retryNonSuperseded(() => reader.waitForChange(window)),
                retryHistory,
              );
              if (sessions.get(id) !== state) return;
              await retrySessionRead(
                controller.signal,
                () =>
                  queueRoostRead(state, () =>
                    retryNonSuperseded(async () => {
                      let retained = await reader.latest();
                      const start = state.roostWindow?.start ?? next.start;
                      while (retained.cursor && retained.start > start)
                        retained = await reader.older(retained);
                      if (sessions.get(id) !== state) return;
                      installHistory(state, retained);
                      window = retained;
                    }),
                  ),
                retryHistory,
              );
              if (reader.metadataChanged(state.roostMetadata))
                refreshMetadata();
              state.historyReadable = true;
              confirmHistory();
            }
          } catch (error) {
            if (!controller.signal.aborted && sessions.get(id) === state) {
              state.historyReady = false;
              state.historyReadable = false;
              state.ready = false;
              settleControls(
                state,
                error instanceof Error ? error : new Error('history_failed'),
              );
              event(
                'offline',
                error instanceof Error ? error.message : 'history_failed',
              );
            }
          }
        })();
      }
      pages = 0;
      let changed = true;
      while (!controller.signal.aborted) {
        if (upToDate) {
          state.streamReady = true;
          updateReadiness();
          if (changed || state.status !== 'live')
            event(state.ready ? 'live' : 'syncing');
          changed = false;
          pages = 0;
        } else {
          if (!state.streamReady) event('syncing');
          if (++pages > 100) throw new Error('session_limit');
        }
        let livePoll = false;
        const next = await retrySessionRead(
          controller.signal,
          () =>
            readAttempt(state, upToDate ? 'poll' : 'catchup', async () => {
              livePoll = upToDate && state.streamReady === true;
              const read = new AbortController();
              state.readController = read;
              const result = await state.client.readOnce({
                offset,
                cursor,
                signal: AbortSignal.any([controller.signal, read.signal]),
                ...(livePoll ? { live: 'long-poll' as const } : {}),
              });
              if (!result.ok && result.result.code === 'gone') return undefined;
              if (!result.ok) throw new Error(result.result.code);
              return result;
            }),
          retryStream,
        );
        if (sessions.get(id) !== state) return;
        if (!next) {
          resync(state);
          return;
        }
        state.readAt = Date.now();
        if (next.result.payload) {
          consume(next.result.payload.body);
          changed = true;
        }
        if (next.result.nextOffset === offset && !next.result.upToDate)
          throw new Error('stalled_cursor');
        offset = next.result.nextOffset;
        cursor = next.result.cursor;
        upToDate = next.result.upToDate;
        if (next.result.closed) throw new Error('stream_closed');
        if (livePoll && !next.result.payload?.body.length && upToDate)
          await new Promise((resolve) => setTimeout(resolve, 1000));
      }
    } catch (error) {
      const failed = error instanceof Error ? error : new Error('sync_failed');
      settleControls(state, failed);
      if (controller.signal.aborted || sessions.get(id) !== state) return;
      state.streamReady = false;
      state.ready = false;
      event('offline', failed.message);
    }
  })();
  return 'watching';
}
/** Only human-send entry points stamp provenance; imports and queue moves do not. */
function recordHumanInputReceipt(doc: LoroDoc, id: string, userId: string) {
  const trimmed = userId.trim();
  const receipts = doc.getMap('humanInputReceipts');
  const existing = receipts.get(id);
  if (existing instanceof LoroMap && existing.get('userId') === trimmed)
    return false;
  receipts.setContainer(id, new LoroMap()).set('userId', trimmed);
  return true;
}
function activeAssistantTurn<T extends Record<string, any>>(
  entries: readonly T[],
): T | undefined {
  for (let i = entries.length - 1; i >= 0; i--) {
    const entry = entries[i];
    if (!entry || entry.role !== 'assistant') continue;
    if (entry.finished === true || typeof entry.endedAt === 'number')
      return undefined;
    return entry;
  }
  return undefined;
}

export function appendUserTurn(
  doc: LoroDoc,
  id: string,
  text: string,
  userId: string,
  config: Record<string, any>,
  timestamp: string,
  status = 'pending',
) {
  const history = doc.getList('history');
  const entry = history.pushContainer(new LoroMap());
  for (const [key, value] of Object.entries({
    id,
    role: 'user',
    userId,
    // Lody's `MessageAuthor`: a turn typed here is a person's, not an agent's.
    author: { v: 1, kind: 'human', userId },
    timestamp,
    status,
    read: false,
    finished: true,
    fileDiff: [],
  }))
    entry.set(key, value);
  const items = entry.setContainer('items', new LoroList());
  for (const block of config.inputBlocks ?? [{ type: 'text', text }]) {
    const item = items.pushContainer(new LoroMap());
    for (const [key, value] of Object.entries(block)) {
      if (key === 'text')
        item.setContainer('text', new LoroText()).insert(0, String(value));
      else if (value !== undefined) item.set(key, value);
    }
  }
  const input = entry.setContainer('inputConfig', new LoroMap());
  for (const [key, value] of Object.entries(config))
    if (value !== undefined) input.set(key, value);
  doc.commit();
}
export function checkTurnQuota(args: {
  sessionId: string;
  billingEntitlement?: BillingEntitlement | null;
}): CheckTurnQuotaResult {
  const state = sessions.get(args.sessionId);
  if (!state || !sessionSendReady(state)) return { state: 'allowed' };
  let count: number | null = billableTurnCount(snapshot(state));
  if (state.target?.backend === 'roost') {
    count = state.roostMetadata
      ? billableTurnCount({
          history: state.roostMetadata,
          mq: state.doc.getMovableList('mq').toJSON(),
        })
      : null;
  }
  const reason = quotaReason('turn', args.billingEntitlement, count);
  return reason ? { state: 'not_sent', reason } : { state: 'allowed' };
}

export async function sendTurn(
  args: {
    id?: string;
    backgroundTaskId?: string;
    queue?: boolean;
    guide?: boolean;
    /** `continue` marks a turn that resumes an interrupted one, as Lody's composer does. */
    deliveryKind?: 'continue';
    sessionId: string;
    machineId: string;
    userId?: string;
    text: string;
    attachmentBlocks?: Record<string, any>[];
    /** Composer quote cards, appended after the rewritten text (web message quotes). */
    quotes?: unknown;
    cliType?: string;
    agentType?: string;
    resume?: string;
    modelId?: string | null;
    modeId?: string;
    reasoningEffort?: string | null;
    reasoningEffortConfigId?: string;
    configOptionValues?: Record<string, unknown>;
    /**
     * The Role this turn runs as (resolved here, see `resolveTurnRole`); null is an explicit
     * None that ends the conversation's Role, and undefined inherits it.
     */
    agentRoleId?: string | null;
    /** The session's own Agent Config, from trusted state (meta / the creator), never the wire. */
    agentConfigId?: string;
    billingEntitlement?: BillingEntitlement | null;
  },
  expand: (
    text: string,
  ) => Promise<string | { text: string; spans: MessageReference[] }> = async (
    text,
  ) => text,
  selectMcp: (persisted: unknown) => Promise<string[]> = async (ids) =>
    Array.isArray(ids) ? ids : [],
  protocolCapabilities?: Record<string, number>,
): Promise<SendTurnResult> {
  if (args.id && uncertain.has(args.id))
    return { id: args.id, state: 'unknown', reason: 'turn_already_exists' };
  const state = sessions.get(args.sessionId);
  if (!state || !sessionSendReady(state))
    return { state: 'not_sent', reason: 'session_not_ready' };
  if (!targetIsCurrent(state))
    return { state: 'not_sent', reason: 'workspace_changed' };
  if (
    args.id !== undefined &&
    (typeof args.id !== 'string' ||
      !/^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i.test(args.id))
  )
    return { state: 'not_sent', reason: 'invalid_message_id' };
  if (
    args.id &&
    (state.sendingId === args.id ||
      [
        ...((snapshot(state).history as any[]) ?? []),
        ...((state.doc.toJSON().mq as any[]) ?? []).map((item) => ({
          id: item.userTurnId,
        })),
      ].some((entry) => entry.id === args.id))
  )
    // The local entry may come from a lost append ACK. Never replay its write.
    return { id: args.id, state: 'unknown', reason: 'turn_already_exists' };
  if (state.sending || state.queueWaitId || state.recovery)
    return { state: 'not_sent', reason: 'session_not_ready' };
  const quota = checkTurnQuota(args);
  if (quota.state === 'not_sent') return quota;
  if (typeof args.text !== 'string')
    return { state: 'not_sent', reason: 'invalid_message' };
  const quotes = messageQuotes(args.quotes);
  if (!quotes) return { state: 'not_sent', reason: 'invalid_message' };
  let text = args.text.trim();
  if (
    args.configOptionValues !== undefined &&
    (!args.configOptionValues ||
      typeof args.configOptionValues !== 'object' ||
      Array.isArray(args.configOptionValues) ||
      Object.keys(args.configOptionValues).length > 64 ||
      Object.entries(args.configOptionValues).some(
        ([id, value]) =>
          !id ||
          id.length > 128 ||
          /(?:api[_-]?key|auth|bearer|credential|password|passwd|secret|token)/i.test(
            id,
          ) ||
          !(
            typeof value === 'boolean' ||
            (typeof value === 'string' &&
              value.length > 0 &&
              value.length <= 512)
          ),
      ))
  )
    return { state: 'not_sent', reason: 'invalid_config_options' };
  const attachments = args.attachmentBlocks ?? [];
  if (!validAttachmentBlocks(attachments))
    return { state: 'not_sent', reason: '附件信息无效，请重新选择' };
  if (
    (!text && !attachments.length && !quotes.length) ||
    text.length > 32000 ||
    !args.userId ||
    !args.machineId ||
    !args.agentType ||
    !args.cliType ||
    (args.reasoningEffort !== undefined &&
      args.reasoningEffort !== null &&
      (typeof args.reasoningEffort !== 'string' ||
        !args.reasoningEffort ||
        args.reasoningEffort.length > 128)) ||
    (args.reasoningEffortConfigId !== undefined &&
      (typeof args.reasoningEffortConfigId !== 'string' ||
        !args.reasoningEffortConfigId ||
        args.reasoningEffortConfigId.length > 128))
  )
    return { state: 'not_sent', reason: 'invalid_message' };
  const id = args.id ?? crypto.randomUUID(),
    timestamp = new Date().toISOString();
  const startedAt = Date.now();
  reserved.add(state.id);
  state.sending = true;
  state.sendingId = id;
  let holdsSession = true;
  let uploaded = false;
  let writeStarted = false;
  try {
    const expanded = await expand(text);
    text = typeof expanded === 'string' ? expanded : expanded.text;
    let spans: (MessageReference | MessageQuoteSpan)[] | undefined =
      typeof expanded === 'string' ? undefined : expanded.spans;
    // Everything below reads the replica, so the hub is asked first.
    if (!(await reachable(state))) throw new Error('session_not_ready');
    if (sessions.get(state.id) !== state || !sessionControlsReady(state))
      throw new Error('session_not_ready');
    if (text.length > 32000) throw new Error('invalid_message');
    if (quotes.length) {
      // Web order: the rewritten main text, then each quote block and its comment.
      ({ text, spans } = appendMessageQuotes(text, spans ?? [], quotes));
    }
    const configSnapshot = snapshot(state);
    const configs = conversationConfigs(
      (configSnapshot.history as any[] | undefined) ?? [],
      (configSnapshot.mq as any[] | undefined) ?? [],
    );
    const previous =
      configs[0] ??
      state.roostMetadata?.findLast((entry) => entry.role === 'user')
        ?.inputConfig ??
      {};
    // Lody keeps a Role sticky from the newest turn that names one, or None.
    const roleTurn = configs.find(
      (config) => config?.agentRoleId !== undefined,
    );
    const configOptionValues = migrateLegacyAntigravityModeOption({
      ...(previous.configOptionValues &&
      typeof previous.configOptionValues === 'object' &&
      !Array.isArray(previous.configOptionValues)
        ? previous.configOptionValues
        : {}),
      ...args.configOptionValues,
    });
    if (args.reasoningEffort !== undefined) {
      const id = args.reasoningEffortConfigId || 'reasoning_effort';
      if (args.reasoningEffort === null) delete configOptionValues[id];
      else configOptionValues[id] = args.reasoningEffort;
    }
    // An explicit pick wins; otherwise the turn inherits what the session
    // already used, and an unset value leaves the machine on its default.
    const rawModeId = args.modeId ?? previous.modeId;
    const modeId =
      typeof rawModeId === 'string'
        ? migrateLegacyAntigravityModeId(rawModeId)
        : rawModeId;
    const modelId =
      args.modelId === null ? undefined : (args.modelId ?? previous.modelId);
    // A Role runs a turn only while every value it pins is what will run (web). Any turn
    // may pick one, but its prompt prefix only ever starts the conversation.
    let role: TurnRole | undefined;
    const started = (
      state.roostMetadata ??
      (configSnapshot.history as any[] | undefined) ??
      []
    ).some((entry) => entry.role === 'user');
    if (args.agentRoleId !== undefined && args.agentRoleId !== null) {
      if (
        typeof args.agentRoleId !== 'string' ||
        !args.agentRoleId ||
        !args.agentConfigId
      )
        throw new Error('role_unavailable');
      role = await resolveTurnRole(
        {
          workspaceId: state.workspace,
          roleId: args.agentRoleId,
          userId: args.userId!,
          machineId: args.machineId,
          agentConfigId: args.agentConfigId,
        },
        () => sessionGrant(state),
        AbortSignal.any([state.controller.signal, AbortSignal.timeout(30000)]),
      );
      if (sessions.get(state.id) !== state || !sessionControlsReady(state))
        throw new Error('session_not_ready');
      const applied = roleRunConfigApplied(role.runConfig, {
        modelId:
          args.modelId === null ? null : (args.modelId ?? previous.modelId),
        modeId,
        configOptionValues,
      });
      if (!applied) throw new Error('role_changed');
    }
    let inheritedRole: {
      agentRoleId?: string | null;
      agentRoleRevision?: number;
      agentRoleSnapshot?: Record<string, unknown>;
    } = {};
    if (!role && args.agentRoleId === undefined) {
      if (typeof roleTurn?.agentRoleId === 'string') {
        inheritedRole = { agentRoleId: roleTurn.agentRoleId };
        if (Number.isInteger(roleTurn.agentRoleRevision))
          inheritedRole.agentRoleRevision = roleTurn.agentRoleRevision;
        if (roleTurn.agentRoleSnapshot)
          inheritedRole.agentRoleSnapshot = roleTurn.agentRoleSnapshot;
      } else if (roleTurn?.agentRoleId === null) {
        inheritedRole = { agentRoleId: null };
      }
    }
    const pendingQueue = (state.doc.toJSON().mq ?? []) as any[];
    let persistedMcp: unknown =
      pendingQueue.findLast((item) =>
        Array.isArray(item.acpSessionConfig?.mcpServerIds),
      )?.acpSessionConfig.mcpServerIds ?? previous.mcpServerIds;
    if (!Array.isArray(persistedMcp) && (started || pendingQueue.length > 0))
      persistedMcp = [];
    const mcpServerIds = await selectMcp(persistedMcp);
    if (
      !(await reachable(state)) ||
      sessions.get(state.id) !== state ||
      !sessionControlsReady(state)
    )
      throw new Error('session_not_ready');
    const inputConfig = {
      cliType: args.cliType,
      agentType: args.agentType,
      // Web `buildAgentPrompt`: the Role's instruction, then the task. The visible
      // input stays the user's own text.
      prompt: [started ? '' : (role?.promptPrefix ?? ''), text]
        .filter((part) => part.trim())
        .join('\n\n'),
      inputBlocks: [
        ...(text
          ? [{ type: 'text', text, ...(spans?.length ? { spans } : {}) }]
          : []),
        ...attachments,
      ],
      modeId,
      modelId,
      configOptionValues: Object.keys(configOptionValues).length
        ? configOptionValues
        : undefined,
      // The machine restarts the agent when a turn names another memory than
      // the one it runs with, so the binding travels with the turn. It is the
      // Role instance's, and a turn recorded as None names none, as in Lody.
      memory:
        args.agentRoleId === null || inheritedRole.agentRoleId === null
          ? undefined
          : previous.memory,
      mcpServerIds,
      taskToolsEnabled: previous.taskToolsEnabled ?? false,
      ...inheritedRole,
      ...(role
        ? {
            agentRoleId: role.id,
            agentRoleRevision: role.revision,
            ...(role.runConfig.memory ? { memory: role.runConfig.memory } : {}),
            agentRoleSnapshot: {
              id: role.id,
              revision: role.revision,
              name: role.name,
              emoji: role.emoji,
            },
          }
        : {}),
      resume: args.resume,
      ...(args.deliveryKind === 'continue'
        ? { _lodyDeliveryKind: 'continue' }
        : {}),
    };
    if (args.agentRoleId === null) {
      // An explicit None: the conversation no longer runs as its Role.
      inputConfig.agentRoleId = null;
      inputConfig.agentRoleRevision = undefined;
      inputConfig.agentRoleSnapshot = undefined;
      inputConfig.memory = undefined;
    } else if (!role && inputConfig.agentRoleId) {
      const previousOptions = migrateLegacyAntigravityModeOption(
        previous.configOptionValues &&
          typeof previous.configOptionValues === 'object' &&
          !Array.isArray(previous.configOptionValues)
          ? previous.configOptionValues
          : {},
      );
      const previousModeId =
        typeof previous.modeId === 'string'
          ? migrateLegacyAntigravityModeId(previous.modeId)
          : previous.modeId;
      const previousComparable: Record<string, unknown> = {
        cliType: previous.cliType,
        agentType: previous.agentType,
        modelId: previous.modelId,
        modeId: previousModeId,
      };
      const changed =
        ['cliType', 'agentType', 'modelId', 'modeId'].some(
          (key) =>
            previousComparable[key] !== undefined &&
            inputConfig[key as keyof typeof inputConfig] !==
              previousComparable[key],
        ) ||
        JSON.stringify(inputConfig.mcpServerIds) !==
          JSON.stringify(previous.mcpServerIds ?? []) ||
        Object.keys(configOptionValues).length !==
          Object.keys(previousOptions).length ||
        Object.entries(configOptionValues).some(
          ([key, value]) => previousOptions[key] !== value,
        );
      if (changed) {
        // A changed run configuration no longer represents the frozen Role.
        inputConfig.agentRoleId = null;
        inputConfig.agentRoleRevision = undefined;
        inputConfig.agentRoleSnapshot = undefined;
        inputConfig.memory = undefined;
      }
    }
    const raw = snapshot(state);
    const history = (raw.history ?? []) as any[];
    const lastUser = history.findLastIndex((entry) => entry.role === 'user');
    // Re-evaluate after attachment upload, mention expansion and MCP selection. A completed
    // target must follow the ordinary dispatch/queue path, never orphan a guide.
    const activeAssistant = activeAssistantTurn(history);
    const guide = args.guide === true ? activeAssistant : undefined;
    const queued =
      !guide &&
      (args.queue === true ||
        (raw.mq as any[] | undefined)?.length ||
        Boolean(activeAssistant) ||
        (lastUser >= 0 &&
          ['pending', 'seen', 'processing'].includes(
            history[lastUser].status,
          ) &&
          !history
            .slice(lastUser + 1)
            .some((entry) => entry.role === 'assistant')));
    if (!targetIsCurrent(state))
      return { id, state: 'not_sent', reason: 'workspace_changed' };
    if (state.target?.backend === 'roost') {
      if (state.target.machineId !== args.machineId)
        return { id, state: 'not_sent', reason: 'session_owner_changed' };
      if (
        !state.roostReader ||
        (!queued &&
          (!state.target.acceptsInput ||
            (!guide && !state.target.dispatchesInput)))
      )
        return { id, state: 'not_sent', reason: 'roost_input_unsupported' };
      if (!queued) {
        const prepared = buildPendingUserHistoryEntry({
          userId: args.userId,
          inputBlocks: inputConfig.inputBlocks,
          timestamp,
          status: guide ? 'pending_apply' : 'pending',
          inputConfig,
        });
        if (!prepared)
          return { id, state: 'not_sent', reason: 'invalid_message' };
        const entry = parseHistoryWrite(HistoryEntryWriteSchema, {
          ...prepared,
          id,
        });
        const owner = acceptedInputs;
        if (!owner)
          return { id, state: 'not_sent', reason: 'input_storage_unavailable' };
        if (args.backgroundTaskId)
          state.backgroundWork = {
            id: args.backgroundTaskId,
            turnId: id,
            guide: !!guide,
          };
        owner.enqueue({
          id,
          sessionId: state.id,
          workspaceId: state.workspace,
          targetMachineId: args.machineId,
          historyBackend: 'roost',
          entry,
          delivery: guide
            ? { kind: 'guide', expectedTurnId: guide.id }
            : { kind: 'dispatch' },
          attachments: [],
        });
        writeStarted = true;
        await waitForAcceptedInputSave(owner, state.id, id);
        if (guide) sendObserver(state.id);
        return guide
          ? { id, state: 'uploaded', awaitingGuide: true }
          : { id, state: 'uploaded' };
      }
    }
    if (queued) {
      const writeQueue = async (): Promise<SendTurnResult> => {
        if (!targetIsCurrent(state)) throw new Error('workspace_changed');
        const before = state.doc.version();
        writeStarted = true;
        recordHumanInputReceipt(state.doc, id, args.userId!);
        const item = state.doc
          .getMovableList('mq')
          .pushContainer(new LoroMap());
        for (const [key, value] of Object.entries({
          task: text,
          userId: args.userId,
          userTurnId: id,
          author: { v: 1, kind: 'human', userId: args.userId },
          timestamp,
        }))
          item.set(key, value);
        const config = item.setContainer('acpSessionConfig', new LoroMap());
        for (const [key, value] of Object.entries({
          ...inputConfig,
          chainDepth: 0,
        }))
          if (value !== undefined) config.set(key, value);
        state.doc.commit();
        const result = await appendOnce(state.client, {
          contentType: 'application/octet-stream',
          body: encodeFrame(state.doc.export({ mode: 'update', from: before })),
        });
        if (!result.ok) throw new Error(result.result.code);
        uploaded = true;
        await state.markDispatch(state.id, id, true);
        scheduleEmit(state, state.status);
        return { id, state: 'queued' };
      };
      if (state.target?.backend === 'roost') {
        const owner = acceptedInputs;
        if (!owner)
          return { id, state: 'not_sent', reason: 'input_storage_unavailable' };
        const predecessors = await owner.capturePredecessors(state.id);
        // Earlier inputs wait for their owner, which can be slow or offline. Stop,
        // steer and edits must stay usable meanwhile, so only later sends of this
        // session wait behind this one. The wait ends before the host's call
        // deadline, so nothing is written after the host has given up on it.
        holdsSession = false;
        state.sending = false;
        state.queueWaitId = id;
        const waitEnded = new AbortController();
        const timer = setTimeout(
          () => waitEnded.abort(),
          Math.max(0, QUEUED_SEND_BUDGET_MS - (Date.now() - startedAt)),
        );
        try {
          return await owner.afterInputs(
            state.id,
            predecessors,
            AbortSignal.any([state.controller.signal, waitEnded.signal]),
            writeQueue,
          );
        } catch (error) {
          if (!writeStarted && waitEnded.signal.aborted)
            return { id, state: 'not_sent', reason: 'previous_input_pending' };
          throw error;
        } finally {
          clearTimeout(timer);
          // Release the combined signal's hold on the session signal.
          waitEnded.abort();
        }
      }
      return await writeQueue();
    }
    if (guide) {
      state.steerReceipts ??= new Map();
      state.steerReceipts.set(id, { targetId: guide.id, state: 'confirming' });
    }
    // Receipt and turn share one update. A failed append discards this replica
    // and reads it again before another turn can depend on the unconfirmed write.
    const before = state.doc.version();
    writeStarted = true;
    recordHumanInputReceipt(state.doc, id, args.userId);
    if (guide)
      state.doc
        .getMap('lodySteerLinks')
        .set(id, { targetId: guide.id, mode: 'native' });
    appendUserTurn(
      state.doc,
      id,
      text,
      args.userId,
      inputConfig,
      timestamp,
      guide ? 'pending_apply' : 'pending',
    );
    const update = state.doc.export({ mode: 'update', from: before });
    const result = await appendOnce(state.client, {
      contentType: 'application/octet-stream',
      body: encodeFrame(update),
    });
    if (!result.ok) throw new Error(result.result.code);
    uploaded = true;
    if (guide) {
      sendObserver(state.id);
      // History is durable; receipt tracking belongs to this message, not the
      // session-wide write lock. A later guide can be persisted while RPC waits.
      void steerTurn(state, args.machineId, {
        sessionId: state.id,
        expectedTurnId: guide.id,
        userTurnId: id,
        userId: args.userId,
        timestamp,
        inputConfig,
      })
        .catch(() => ({ state: 'not_applied' }))
        .then((result) => {
          if (args.backgroundTaskId)
            state.emit({
              type: 'sessionCache',
              sessionId: state.id,
              backgroundWork: {
                id: args.backgroundTaskId,
                state: result.state === 'applied' ? 'completed' : 'failed',
              },
            });
        });
      return { id, state: 'uploaded', awaitingGuide: true };
    }
    if (state.backgroundWork) {
      state.emit({
        type: 'sessionCache',
        sessionId: state.id,
        backgroundWork: { id: state.backgroundWork.id, state: 'failed' },
      });
    }
    state.backgroundWork = args.backgroundTaskId
      ? { id: args.backgroundTaskId, turnId: id }
      : undefined;
    await state.markDispatch(state.id, id);
    if (sessions.get(state.id) !== state) throw new Error('runtime_replaced');
    scheduleEmit(state, 'live');
    const replyTo = `${state.workspace}:rpc:res:${args.machineId}:${crypto.randomUUID()}`;
    const responseClient = await clientFor(replyTo, () => sessionGrant(state));
    const created = await responseClient.create({
      contentType: 'application/json',
      ttlSeconds: 300,
    });
    if (!created.ok) throw new Error(created.result.code);
    const requestId = crypto.randomUUID(),
      now = Date.now();
    const requestClient = await clientFor(
      `${state.workspace}:rpc:req:${args.machineId}`,
      () => sessionGrant(state),
    );
    const dispatched = await appendOnce(requestClient, {
      contentType: 'application/json',
      body: JSON.stringify({
        jsonrpc: '2.0',
        id: requestId,
        rpcVersion: '1',
        workspaceId: state.workspace,
        machineId: args.machineId,
        replyTo,
        sentAt: now,
        expiresAt: now + 15000,
        method: 'session/dispatch-turn',
        params: {
          ...((protocolCapabilities?.operationInbox ?? 0) >= 1
            ? { inputOrigin: 'human' }
            : {}),
          sessionId: state.id,
          userTurnId: id,
          userId: args.userId,
          timestamp,
          inputConfig,
        },
      }),
    });
    if (!dispatched.ok) throw new Error(dispatched.result.code);
    const signal = AbortSignal.any([
      state.controller.signal,
      AbortSignal.timeout(18000),
    ]);
    let offset = '-1';
    while (!signal.aborted) {
      const read = await responseClient.readOnce({
        offset,
        live: 'long-poll',
        signal,
      });
      if (!read.ok) throw new Error(read.result.code);
      offset = read.result.nextOffset;
      if (!read.result.payload) continue;
      const parsed = JSON.parse(
        new TextDecoder().decode(read.result.payload.body),
      );
      for (const reply of Array.isArray(parsed) ? parsed : [parsed]) {
        if (reply.id !== requestId) continue;
        if (!reply.result?.accepted)
          throw new Error(
            reply.error?.message ??
              reply.result?.error ??
              reply.result?.disposition ??
              'dispatch_rejected',
          );
        return { id, state: 'accepted' };
      }
    }
    throw new Error('ack_timeout');
  } catch (error) {
    let delivery: 'not_sent' | 'unknown' | 'uploaded' = 'not_sent';
    if (
      writeStarted ||
      (error instanceof Error && error.message === 'input_already_pending')
    )
      delivery = 'unknown';
    if (uploaded) delivery = 'uploaded';
    if (delivery === 'unknown') {
      // The replica now differs from the hub; later writes would depend on it.
      uncertain.add(id);
      resync(state);
    }
    return {
      id,
      state: delivery,
      reason: error instanceof Error ? error.message : 'send_failed',
      // The native outbox can release inflight and wait only while nothing was
      // written. Preserve the diagnostic reason; never replay unknown writes.
      ...(!writeStarted &&
      error instanceof Error &&
      error.message === 'mcp_catalog_unavailable' &&
      'retryable' in error &&
      error.retryable === true
        ? { retryable: true }
        : {}),
    };
  } finally {
    // A released session may already belong to a later control or edit.
    if (holdsSession) state.sending = false;
    if (state.sendingId === id) state.sendingId = undefined;
    if (state.queueWaitId === id) state.queueWaitId = undefined;
  }
}

export async function controlTurn(
  args: {
    action: 'stop' | 'steer';
    sessionId: string;
    machineId: string;
    turnId: string;
    messageId?: string;
    interrupt?: boolean;
  },
  options?: { supportsOperationInbox?: boolean },
): Promise<ControlTurnResult> {
  const state = active;
  if (
    !state ||
    state.id !== args.sessionId ||
    !sessionControlsReady(state) ||
    state.sending
  )
    throw new Error('session_not_ready');
  if (!targetIsCurrent(state)) throw new Error('workspace_changed');
  if (
    state.target?.backend === 'roost' &&
    state.target.machineId !== args.machineId
  )
    throw new Error('session_owner_changed');
  if (
    !['stop', 'steer'].includes(args.action) ||
    typeof args.machineId !== 'string' ||
    !args.machineId.trim() ||
    typeof args.turnId !== 'string' ||
    !args.turnId.trim()
  )
    throw new Error('invalid_control');
  const history = historyList(state);
  const entries = history.toJSON() as any[];
  const activeTurn = activeAssistantTurn(entries);
  if (!activeTurn || activeTurn.id !== args.turnId)
    throw new Error('stale_turn');
  state.sending = true;
  let trackedSteerId = args.messageId;
  try {
    let params: Record<string, unknown> = {
      sessionId: state.id,
      turnId: args.turnId,
    };
    if (args.action === 'steer') {
      if (typeof args.messageId !== 'string' || !args.messageId.trim())
        throw new Error('invalid_message');
      const queue = state.doc.getMovableList('mq');
      const index = (queue.toJSON() as any[]).findIndex(
        (item) => item.userTurnId === args.messageId,
      );
      const entry = entries.find((item) => item.id === args.messageId);
      const linked = state.doc.getMap('lodySteerLinks').get(args.messageId);
      if (
        entry &&
        (entry.role !== 'user' ||
          entry.status !== 'pending' ||
          (entry.inputConfig?._lodyDeliveryKind !== 'steer' && !linked) ||
          entries.some(
            (item) =>
              item.role === 'assistant' && item.userTurnId === args.messageId,
          ))
      )
        throw new Error('message_not_queued');
      const item = index >= 0 ? (queue.toJSON() as any[])[index] : undefined;
      const config = entry?.inputConfig ?? item?.acpSessionConfig;
      const userId = entry?.userId ?? item?.userId;
      const timestamp = entry?.timestamp ?? item?.timestamp;
      if (
        !config ||
        typeof config !== 'object' ||
        Array.isArray(config) ||
        typeof userId !== 'string' ||
        !userId ||
        typeof timestamp !== 'string' ||
        !timestamp
      )
        throw new Error('message_not_queued');
      if (args.interrupt && (index !== 0 || entry))
        throw new Error('message_not_first');
      state.steerReceipts ??= new Map();
      state.steerReceipts.set(args.messageId, {
        targetId: args.turnId,
        state: 'confirming',
      });
      if (state.target?.backend === 'roost' && !args.interrupt) {
        if (
          !state.target.acceptsInput ||
          !state.roostReader ||
          entry ||
          index < 0
        )
          throw new Error('message_not_queued');
        const prepared = buildPendingUserHistoryEntry({
          userId,
          inputBlocks: config.inputBlocks ?? [
            { type: 'text', text: item.task },
          ],
          timestamp,
          status: 'pending_apply',
          inputConfig: config,
        });
        if (!prepared) throw new Error('invalid_message');
        const input = parseHistoryWrite(HistoryEntryWriteSchema, {
          ...prepared,
          id: args.messageId,
        });
        const owner = acceptedInputs;
        if (!owner) throw new Error('input_storage_unavailable');
        owner.enqueue({
          id: args.messageId,
          sessionId: state.id,
          workspaceId: state.workspace,
          targetMachineId: args.machineId,
          historyBackend: 'roost',
          entry: input,
          delivery: { kind: 'guide', expectedTurnId: args.turnId },
          attachments: [],
        });
        await waitForAcceptedInputSave(owner, state.id, args.messageId);
        if (!targetIsCurrent(state)) throw new Error('workspace_changed');
        const currentIndex = (queue.toJSON() as any[]).findIndex(
          (queued) => queued.userTurnId === args.messageId,
        );
        if (currentIndex < 0) throw new Error('message_not_queued');
        const beforeRemove = state.doc.version();
        state.doc
          .getMap('lodySteerLinks')
          .set(args.messageId, { targetId: args.turnId, mode: 'native' });
        queue.delete(currentIndex, 1);
        state.doc.commit();
        const removed = await state.client.append({
          part: {
            contentType: 'application/octet-stream',
            body: encodeFrame(
              state.doc.export({ mode: 'update', from: beforeRemove }),
            ),
          },
        });
        if (!removed.ok) throw new Error('steer_unconfirmed');
        scheduleEmit(state, state.status);
        return { state: 'not_applied', reason: 'steer_pending' };
      }
      const before = state.doc.version();
      if (args.interrupt) {
        // Cancellation resumes the existing FIFO queue. Persist the exact edge
        // before cancellation; do not move/replay the machine-owned queue.
        const queued = queue.get(index);
        if (!(queued instanceof LoroMap)) throw new Error('invalid_queue');
        const queuedConfig = queued.get('acpSessionConfig');
        if (!(queuedConfig instanceof LoroMap))
          throw new Error('invalid_queue');
        const paused = queued.get('paused') === true;
        const steerMessageId = paused
          ? `queue-resend:${args.messageId}`
          : args.messageId;
        trackedSteerId = steerMessageId;
        if (paused) {
          queued.delete('paused');
          queued.set('userTurnId', steerMessageId);
          state.steerReceipts.delete(args.messageId);
          state.steerReceipts.set(steerMessageId, {
            targetId: args.turnId,
            state: 'confirming',
          });
        }
        recordHumanInputReceipt(state.doc, steerMessageId, userId);
        state.doc.getMap('lodySteerLinks').set(steerMessageId, {
          targetId: args.turnId,
          mode: 'interrupt',
        });
        queuedConfig.delete('_lodyDeliveryKind');
        queuedConfig.set('_lodySteerTarget', args.turnId);
        queuedConfig.set('_lodySteerMode', 'interrupt');
        state.doc.commit();
        scheduleEmit(state, state.status);
        const uploaded = await state.client.append({
          part: {
            contentType: 'application/octet-stream',
            body: encodeFrame(
              state.doc.export({ mode: 'update', from: before }),
            ),
          },
        });
        if (!uploaded.ok) throw new Error('steer_unconfirmed');
        const reply = await machineRpc(
          state.workspace,
          args.machineId,
          'session/cancel',
          {
            sessionId: state.id,
            turnId: args.turnId,
            ...(options?.supportsOperationInbox ? { pauseInbox: false } : {}),
          },
          () => sessionGrant(state),
          AbortSignal.any([
            state.controller.signal,
            AbortSignal.timeout(35000),
          ]),
        );
        if (
          reply.error ||
          (reply.result as { success?: boolean })?.success !== true
        )
          throw new Error('steer_unconfirmed');
        return { state: 'applied' };
      }
      recordHumanInputReceipt(state.doc, args.messageId, userId);
      state.doc.getMap('lodySteerLinks').set(args.messageId, {
        targetId: args.turnId,
        mode: 'native',
      });
      // Move the same id atomically. pending_apply is durable intent, not delivery.
      // A lost append/RPC ACK must never trigger an automatic replay.
      const { _lodyDeliveryKind: _ignoredDeliveryKind, ...steerConfig } =
        config;
      if (!entry) {
        appendUserTurn(
          state.doc,
          args.messageId,
          item.task,
          userId,
          steerConfig,
          timestamp,
          'pending_apply',
        );
      } else {
        const pending = history.get(entries.indexOf(entry));
        if (!(pending instanceof LoroMap)) throw new Error('invalid_history');
        pending.set('status', 'pending_apply');
        pending.set('read', false);
      }
      if (index >= 0) queue.delete(index, 1);
      state.doc.commit();
      const uploaded = await state.client.append({
        part: {
          contentType: 'application/octet-stream',
          body: encodeFrame(state.doc.export({ mode: 'update', from: before })),
        },
      });
      scheduleEmit(state, state.status);
      if (!uploaded.ok) throw new Error('steer_unconfirmed');
      params = {
        sessionId: state.id,
        expectedTurnId: args.turnId,
        userTurnId: args.messageId,
        userId,
        timestamp,
        inputConfig: steerConfig,
      };
      // Release the write lock in finally while this message awaits its receipt.
      return steerTurn(state, args.machineId, params);
    }
    const reply = await machineRpc(
      state.workspace,
      args.machineId,
      'session/cancel',
      params,
      () => sessionGrant(state),
      AbortSignal.any([state.controller.signal, AbortSignal.timeout(35000)]),
    );
    if (reply.error) throw new Error(reply.error.message ?? 'control_failed');
    const result = reply.result as
      { success?: boolean; error?: string } | undefined;
    if (result?.success !== true)
      throw new Error(result?.error ?? 'stop_failed');
    return { state: 'stopped' };
  } catch (error) {
    if (
      args.action === 'steer' &&
      trackedSteerId &&
      state.steerReceipts?.has(trackedSteerId)
    ) {
      state.steerReceipts?.set(trackedSteerId, {
        targetId: args.turnId,
        state: 'unknown',
      });
    }
    throw error;
  } finally {
    state.sending = false;
    scheduleEmit(state, state.status);
  }
}

async function promoteUndeliveredSteer(
  state: SessionState,
  machineId: string,
  params: Record<string, unknown>,
) {
  const history = state.doc.getList('history');
  const before = state.doc.version();
  let promoted = false;
  for (let i = 0; i < history.length; i++) {
    const entry = history.get(i);
    if (
      entry instanceof LoroMap &&
      entry.get('id') === params.userTurnId &&
      entry.get('status') === 'pending_apply'
    ) {
      entry.set('status', 'pending');
      entry.set('read', false);
      promoted = true;
    }
  }
  if (!promoted) return;
  state.doc.commit();
  scheduleEmit(state, state.status);
  const uploaded = await state.client
    .append({
      part: {
        contentType: 'application/octet-stream',
        body: encodeFrame(state.doc.export({ mode: 'update', from: before })),
      },
    })
    .catch(() => null);
  if (
    !uploaded?.ok ||
    sessions.get(state.id) !== state ||
    !targetIsCurrent(state)
  )
    return;
  await state.markDispatch(state.id, String(params.userTurnId)).catch(() => {});
  await machineRpc(
    state.workspace,
    machineId,
    'session/dispatch-turn',
    {
      sessionId: state.id,
      userTurnId: params.userTurnId,
      userId: params.userId,
      timestamp: params.timestamp,
      inputConfig: params.inputConfig,
    },
    () => sessionGrant(state),
    AbortSignal.any([state.controller.signal, AbortSignal.timeout(15000)]),
  ).catch(() => {});
}

async function steerTurn(
  state: SessionState,
  machineId: string,
  params: Record<string, unknown>,
): Promise<ControlTurnResult> {
  state.steerReceipts ??= new Map();
  const record = (delivery: SteerReceipt['state']) => {
    state.steerReceipts!.set(String(params.userTurnId), {
      targetId: String(params.expectedTurnId),
      state: delivery,
    });
    scheduleEmit(state, state.status);
  };
  record('confirming');
  const reply = await machineRpc(
    state.workspace,
    machineId,
    'session/steer',
    params,
    () => sessionGrant(state),
    AbortSignal.any([state.controller.signal, AbortSignal.timeout(35000)]),
  ).catch((error: unknown): RpcReply => ({
    error: {
      message: error instanceof Error ? error.message : 'control_failed',
    },
  }));
  if (reply.error) {
    record('unknown');
    return { state: 'not_applied', reason: reply.error.message };
  }
  const result = reply.result as
    | { applied?: boolean; disposition?: string; recoveryOwned?: boolean }
    | undefined;
  if (result?.applied !== true) {
    if (!result?.recoveryOwned && result?.disposition === 'promotion-failed') {
      await promoteUndeliveredSteer(state, machineId, params);
      record('waiting');
      return { state: 'not_applied', reason: result.disposition };
    }
    const requeued =
      result?.recoveryOwned === true &&
      ['no-active-turn', 'stale-turn', 'unsupported', 'busy'].includes(
        result.disposition ?? '',
      );
    record(requeued ? 'waiting' : 'unknown');
    return { state: 'not_applied', reason: result?.disposition ?? 'unknown' };
  }
  record('accepted');
  const history = state.doc.getList('history');
  const before = state.doc.version();
  for (let i = 0; i < history.length; i++) {
    const entry = history.get(i);
    if (
      entry instanceof LoroMap &&
      entry.get('id') === params.userTurnId &&
      entry.get('status') === 'pending_apply'
    ) {
      entry.set('status', 'processing');
      entry.set('read', true);
      const input = entry.get('inputConfig');
      if (input instanceof LoroMap) input.set('_lodyDeliveryKind', 'steer');
    }
  }
  state.doc.commit();
  scheduleEmit(state, state.status);
  // Delivery is confirmed even if this redundant display-status append fails.
  await state.client
    .append({
      part: {
        contentType: 'application/octet-stream',
        body: encodeFrame(state.doc.export({ mode: 'update', from: before })),
      },
    })
    .catch(() => {});
  return { state: 'applied' };
}

export function docSnapshot() {
  return active && targetIsCurrent(active) ? snapshot(active) : undefined;
}

export async function editSession(
  args: {
    action: 'read' | 'send';
    sessionId: string;
    expectedUserTurnId: string;
    backgroundTaskId?: string;
    id?: string;
    text?: string;
    retainedIds?: string[];
    attachmentBlocks?: Record<string, any>[];
    quotes?: unknown;
    userId: string;
    billingEntitlement?: BillingEntitlement | null;
  },
  meta: Record<string, any>,
  capability?: Record<string, any>,
): Promise<EditSessionResult> {
  const state = sessions.get(args.sessionId);
  if (!state?.ready || state.sending)
    return { state: 'not_sent', reason: 'session_not_ready' };
  if (!targetIsCurrent(state))
    return { state: 'not_sent', reason: 'workspace_changed' };
  const history = historyList(state).toJSON() as Record<string, any>[];
  if (args.id && history.some((entry) => entry.id === args.id))
    return { state: 'accepted', id: args.id };
  const turn = editableUserTurn(history, meta, capability);
  if (!turn || turn.id !== args.expectedUserTurnId)
    return { state: 'not_sent', reason: 'message_no_longer_editable' };
  if (args.action === 'read') {
    // Quote spans restore into composer cards; the rest is the main text.
    let joined = '';
    const spans: Record<string, any>[] = [];
    for (const item of userTurnItems(turn)) {
      if (item.type !== 'text') continue;
      if (joined) joined += '\n\n';
      const offset = joined.length;
      for (const span of Array.isArray(item.spans) ? item.spans : [])
        if (span && typeof span === 'object')
          spans.push({
            ...span,
            start: span.start + offset,
            end: span.end + offset,
          });
      joined += item.text ?? '';
    }
    const restored = splitMessageQuotes(joined, spans);
    return {
      state: 'ready',
      id: turn.id,
      text: restored.text,
      ...(restored.quotes.length ? { quotes: restored.quotes } : {}),
      attachments: editAttachments(turn),
    };
  }
  if (
    !args.id ||
    args.id === turn.id ||
    !args.userId ||
    typeof args.text !== 'string'
  )
    return { state: 'not_sent', reason: 'invalid_message' };
  const quota = checkTurnQuota(args);
  if (quota.state === 'not_sent') return quota;
  const quotes = messageQuotes(args.quotes);
  if (!quotes) return { state: 'not_sent', reason: 'invalid_message' };
  let inputConfig;
  try {
    inputConfig = replacementInput(
      turn,
      args.text,
      args.retainedIds ?? [],
      args.attachmentBlocks ?? [],
      quotes,
    );
  } catch {
    return { state: 'not_sent', reason: 'invalid_message' };
  }
  state.sending = true;
  let receiptUnconfirmed = false;
  try {
    if (!(await reachable(state)))
      return { state: 'not_sent', reason: 'session_not_ready' };
    // The machine owns the replacement history. Confirm its receipt before
    // the RPC can write/activate it; a failed append discards this replica.
    const before = state.doc.version();
    if (recordHumanInputReceipt(state.doc, args.id, args.userId)) {
      receiptUnconfirmed = true;
      state.doc.commit();
      const update = state.doc.export({ mode: 'update', from: before });
      const result = await appendOnce(state.client, {
        contentType: 'application/octet-stream',
        body: encodeFrame(update),
      });
      if (!result.ok) throw new Error(result.result.code);
      receiptUnconfirmed = false;
    }

    const response = await machineRpc(
      state.workspace,
      meta.machineId,
      'session/edit-and-resend',
      {
        sessionId: args.sessionId,
        expectedUserTurnId: turn.id,
        replacementUserTurnId: args.id,
        requestedByUserId: args.userId,
        timestamp: new Date().toISOString(),
        inputConfig,
      },
      () => sessionGrant(state),
      AbortSignal.any([state.controller.signal, AbortSignal.timeout(120000)]),
    );
    if (response.error)
      return { state: 'unknown', reason: response.error.message };
    const result = response.result as
      { success?: boolean; error?: { message?: string } } | undefined;
    if (result?.success === true) {
      if (args.backgroundTaskId)
        state.backgroundWork = { id: args.backgroundTaskId, turnId: args.id };
      sendObserver(state.id);
      return { state: 'accepted', id: args.id };
    }
    if (result?.success === false)
      return {
        state: 'not_sent',
        reason: result.error?.message ?? 'edit_failed',
      };
    return { state: 'unknown' };
  } catch (error) {
    if (receiptUnconfirmed) {
      resync(state);
      return {
        state: 'not_sent',
        reason: error instanceof Error ? error.message : 'send_failed',
      };
    }
    return { state: 'unknown' };
  } finally {
    state.sending = false;
    scheduleEmit(state, state.status);
  }
}
function scalar(value: unknown) {
  return value instanceof LoroText ? value.toString() : value;
}
function locateItem(entryId: string, itemId: string) {
  const state = active;
  if (!state) return undefined;
  const history = historyList(state);
  for (let i = 0; i < history.length; i++) {
    const entry = history.get(i);
    if (!(entry instanceof LoroMap) && entry && typeof entry === 'object') {
      const raw = entry as Record<string, any>;
      if (raw.id !== entryId || !Array.isArray(raw.items)) continue;
      for (let j = 0; j < raw.items.length; j++) {
        const item = raw.items[j];
        if (!item || typeof item !== 'object') continue;
        let id = state.roostWindow ? `idx:${entryId}:${j}` : `idx:${i}:${j}`;
        if (item.type === 'tool_call' && typeof item.toolCallId === 'string')
          id = item.toolCallId;
        if (id === itemId)
          return {
            get: (key: string) => item[key],
            toJSON: () => item,
            set: () => {
              throw new Error('readonly_history');
            },
          };
      }
      return undefined;
    }
    if (!(entry instanceof LoroMap) || entry.get('id') !== entryId) continue;
    const items = entry.get('items');
    if (!(items instanceof LoroList)) return undefined;
    for (let j = 0; j < items.length; j++) {
      const item = items.get(j);
      if (!(item instanceof LoroMap)) continue;
      // Desktop writes toolCallId as LoroText; the projection reads it via toJSON.
      const callId = scalar(item.get('toolCallId'));
      const id =
        scalar(item.get('type')) === 'tool_call' && typeof callId === 'string'
          ? callId
          : identityAt(items, j);
      if (id === itemId) return item;
    }
    return undefined;
  }
  return undefined;
}
const DETAIL_LIMIT = 512 * 1024;
function locateRunItem(entryId: string, itemId: string) {
  let path: unknown;
  try {
    path = JSON.parse(itemId);
  } catch {
    return;
  }
  if (
    !Array.isArray(path) ||
    path.length !== 2 ||
    !path.every((id) => typeof id === 'string')
  )
    return;
  const parent: any = locateItem(entryId, path[0])?.toJSON();
  if (parent?.type !== 'subagent_task' || !Array.isArray(parent.run?.items))
    return;
  return parent.run.items.find((item: any, index: number) => {
    const id =
      item?.type === 'tool_call' && typeof item.toolCallId === 'string'
        ? item.toolCallId
        : `run:${index}`;
    return id === path[1];
  });
}
export async function itemDetail(args: {
  sessionId: string;
  entryId: string;
  itemId: string;
  cursor?: string;
  /** Reads every step of a sub-agent run instead of content blocks. */
  run?: boolean;
}) {
  if (!active || active.id !== args.sessionId || !active.ready)
    throw new Error('session_not_ready');
  if (!targetIsCurrent(active)) throw new Error('workspace_changed');
  const item = locateItem(args.entryId, args.itemId);
  if (args.run && item)
    return {
      itemId: args.itemId,
      rev: itemRev(active.doc, args.entryId, args.itemId),
      run: subagentRun(active.doc, args.entryId, args.itemId, item) ?? null,
      blocks: [] as unknown[],
      rawInput: undefined as unknown,
      rawOutput: undefined as unknown,
      options: undefined as unknown,
      outcome: undefined as unknown,
      truncated: false,
      nextCursor: undefined as string | undefined,
    };
  const raw: any = item?.toJSON() ?? locateRunItem(args.entryId, args.itemId);
  if (!raw) throw new Error('item_not_found');
  const content: unknown[] = Array.isArray(raw.content) ? raw.content : [];
  const start = Math.max(0, Number(args.cursor ?? 0) || 0);
  const blocks: unknown[] = [];
  let size = 0;
  let next = content.length;
  for (let i = start; i < content.length; i++) {
    const bytes = JSON.stringify(content[i]).length;
    if (blocks.length && size + bytes > DETAIL_LIMIT) {
      next = i;
      break;
    }
    blocks.push(content[i]);
    size += bytes;
  }
  const truncated = next < content.length;
  return {
    itemId: args.itemId,
    rev: itemRev(active.doc, args.entryId, args.itemId),
    blocks,
    rawInput: raw.rawInput,
    rawOutput: raw.rawOutput,
    options: raw.permissionRequest?.options,
    outcome: raw.permissionRequest?.outcome,
    truncated,
    nextCursor: truncated ? String(next) : undefined,
  };
}
export async function respondPermission(args: {
  sessionId: string;
  entryId: string;
  itemId: string;
  requestId: string;
  optionId: string;
  answers?: unknown;
}) {
  const state = active;
  if (!state || state.id !== args.sessionId || !sessionControlsReady(state))
    throw new Error('session_not_ready');
  if (!targetIsCurrent(state)) throw new Error('workspace_changed');
  const item = locateItem(args.entryId, args.itemId);
  const request = item?.get('permissionRequest');
  const current: any =
    request instanceof LoroMap ? request.toJSON() : (request ?? undefined);
  if (!item || !current || current.requestId !== args.requestId)
    return { state: 'stale' as const };
  const options: any[] = Array.isArray(current.options) ? current.options : [];
  if (!options.some((o) => o?.optionId === args.optionId))
    throw new Error('invalid_option');
  const key = `${args.entryId}/${args.itemId}/${args.requestId}`;
  const meta = parseQuestionMeta(current._meta);
  const selected = options.find((o) => o?.optionId === args.optionId);
  const isReject = selected?.kind?.startsWith('reject');
  if (
    !meta &&
    (current.kind === 'ask_user_question' ||
      item.get('kind') === 'ask_user_question') &&
    !isReject
  )
    throw new Error('invalid_answers');
  let outcome: Record<string, unknown> = {
    outcome: 'selected',
    optionId: args.optionId,
  };
  if (meta && !isReject)
    outcome = questionOutcome(args.optionId, meta, args.answers);
  if (current.outcome != null) {
    if (!samePermissionOutcome(current.outcome, outcome))
      return { state: 'conflict' as const };
    if (!state.unsent.has(key)) return { state: 'accepted' as const };
  }
  if (state.target?.backend === 'roost') {
    if (!state.roostReader) throw new Error('session_not_ready');
    const accepted =
      await state.roostReader.sessionData.commands.respondPermission(
        args.requestId,
        outcome,
        { turnId: args.entryId },
      );
    return { state: accepted ? ('accepted' as const) : ('stale' as const) };
  }
  const before = state.unsent.get(key)?.version ?? state.doc.version();
  if (current.outcome == null) {
    if (request instanceof LoroMap) request.set('outcome', outcome);
    else item.set('permissionRequest', { ...current, outcome });
    state.doc.commit();
  }
  // Register before awaiting: a thrown transport error also needs explicit retry.
  state.unsent.set(key, { version: before, outcome });
  const result = await state.client.append({
    part: {
      contentType: 'application/octet-stream',
      body: encodeFrame(state.doc.export({ mode: 'update', from: before })),
    },
  });
  if (!result.ok) {
    // A user-initiated retry re-exports from this version; nothing replays on its own.
    state.unsent.set(key, { version: before, outcome });
    throw new Error('upload_failed');
  }
  state.unsent.delete(key);
  if (active === state) scheduleEmit(state, 'live');
  return { state: 'accepted' as const };
}

type NoticeTarget = {
  sessionId: string;
  entryId: string;
  itemId: string;
};

async function readRoostNotice(state: SessionState, args: NoticeTarget) {
  const data = state.roostReader?.sessionData;
  if (!data || !targetIsCurrent(state)) throw new Error('session_not_ready');
  const read = await data.history.readTurn(args.entryId);
  if (active !== state || !targetIsCurrent(state))
    throw new Error('session_not_ready');
  const turn = read.turn;
  if (
    read.state !== 'ready' ||
    !record(turn) ||
    turn.id !== args.entryId ||
    !Array.isArray(turn.items)
  )
    return undefined;
  const index = turn.items.findIndex(
    (_, index) => args.itemId === `idx:${args.entryId}:${index}`,
  );
  const item: unknown = turn.items[index];
  if (
    !record(item) ||
    item.type !== 'system_notice' ||
    typeof item.name !== 'string'
  )
    return undefined;
  return { data, turn, items: turn.items, index, item, name: item.name };
}

/** A `system_notice` in the open session, read for an action on it. */
export async function noticeAt(args: NoticeTarget) {
  const state = active;
  if (!state || state.id !== args.sessionId || !state.ready)
    throw new Error('session_not_ready');
  if (state.target?.backend === 'roost') {
    const notice = await readRoostNotice(state, args);
    return notice && { name: notice.name, meta: notice.item.meta };
  }
  const item = locateItem(args.entryId, args.itemId);
  if (!item) return undefined;
  const raw: any = item.toJSON();
  if (raw?.type !== 'system_notice' || typeof raw.name !== 'string')
    return undefined;
  return { name: raw.name, meta: raw.meta };
}

/**
 * Record a decision in a notice's meta (web writes the whole turn back with the
 * changed item). Only the fields given change; the upload is never replayed: a
 * failed append keeps the local version so an explicit retry re-exports it.
 */
export async function writeNoticeMeta(
  args: NoticeTarget & {
    name: string;
    patch: Record<string, unknown>;
  },
) {
  const state = active;
  if (!state || state.id !== args.sessionId || !state.ready)
    throw new Error('session_not_ready');
  if (state.target?.backend === 'roost') {
    const notice = await readRoostNotice(state, args);
    if (!notice || notice.name !== args.name)
      throw new Error('proposal_unavailable');
    const current = record(notice.item.meta) ? notice.item.meta : {};
    if (
      Object.entries(args.patch).every(([key, value]) => current[key] === value)
    )
      return;
    const items = [...notice.items];
    items[notice.index] = {
      ...notice.item,
      meta: { ...current, ...args.patch },
    };
    await notice.data.commands.replaceTurn(args.entryId, {
      ...notice.turn,
      id: args.entryId,
      items,
    });
    return;
  }
  const item = locateItem(args.entryId, args.itemId);
  if (!item || scalar(item.get('type')) !== 'system_notice')
    throw new Error('proposal_unavailable');
  if (scalar(item.get('name')) !== args.name)
    throw new Error('proposal_unavailable');
  const key = `${args.entryId}/${args.itemId}/notice`;
  const meta = item.get('meta');
  const current: Record<string, unknown> =
    meta instanceof LoroMap
      ? (meta.toJSON() as Record<string, unknown>)
      : meta && typeof meta === 'object'
        ? (meta as Record<string, unknown>)
        : {};
  const applied = Object.entries(args.patch).every(
    ([field, value]) => current[field] === value,
  );
  if (applied && !state.unsent.has(key)) return;
  const before = state.unsent.get(key)?.version ?? state.doc.version();
  if (!applied) {
    if (meta instanceof LoroMap)
      for (const [field, value] of Object.entries(args.patch))
        meta.set(field, value);
    else item.set('meta', { ...current, ...args.patch });
    state.doc.commit();
  }
  state.unsent.set(key, { version: before, outcome: args.patch });
  const result = await state.client.append({
    part: {
      contentType: 'application/octet-stream',
      body: encodeFrame(state.doc.export({ mode: 'update', from: before })),
    },
  });
  if (!result.ok) throw new Error('upload_failed');
  state.unsent.delete(key);
  if (active === state) scheduleEmit(state, 'live');
}
