import type { MachineState } from '../models/machines.ts';
import type { SessionPresenceDetail } from './machine-presence.ts';

/** Bounded wait so manual Run now never hangs on an unreachable host. */
export const SESSION_LIVE_STATUS_TIMEOUT_MS = 3_500;
/** Matches `@lody/components` `UNSTARTED_TRAILING_USER_TURN_TIMEOUT_MS`. */
export const UNSTARTED_TRAILING_USER_TURN_TIMEOUT_MS = 30_000;

export type SessionLiveState = 'idle' | 'busy' | 'unknown';
export type SessionLiveStatusSource = 'presence' | 'pointer' | 'rpc' | 'none';
export type SessionLiveStatusReason =
  'machine_offline' | 'presence_unsynced' | 'rpc_failed' | 'session_not_found';

export type SessionLiveStatusSnapshot = {
  presenceDetail: SessionPresenceDetail | undefined;
  machineState: MachineState;
  sessionMeta: Record<string, unknown> | undefined;
  nowMs: number;
};

export type SessionLiveStatusInspection = {
  sessionId: string;
  state: SessionLiveState;
  detail?: SessionPresenceDetail;
  source?: SessionLiveStatusSource;
  reason?: SessionLiveStatusReason;
};

function isMissingHistoryUserTurn(
  meta: Record<string, unknown>,
  turnId: string,
): boolean {
  if (meta.lastMissingHistoryUserMsgId === turnId) return true;
  const map = meta.missingHistoryUserMsgIds;
  if (!map || typeof map !== 'object' || Array.isArray(map)) return false;
  return (map as Record<string, unknown>)[turnId] === true;
}

/** Matches `@lody/shared` `hasPendingUserTurnActivation`. */
export function hasPendingUserTurnActivation(
  meta: Record<string, unknown> | undefined,
): boolean {
  if (!meta) return false;
  const settled =
    typeof meta.settledActivationUserMsgId === 'string'
      ? meta.settledActivationUserMsgId
      : undefined;
  const processing = meta.processingUserMsgId;
  if (
    typeof processing === 'string' &&
    processing.length > 0 &&
    !isMissingHistoryUserTurn(meta, processing) &&
    processing !== settled
  )
    return true;
  const latest = meta.latestUserMsgId;
  if (
    typeof latest === 'string' &&
    latest.length > 0 &&
    latest !== meta.lastHandledUserMsgId &&
    !isMissingHistoryUserTurn(meta, latest) &&
    latest !== settled
  )
    return true;
  const steers = meta.steerTurnStatuses;
  if (!steers || typeof steers !== 'object' || Array.isArray(steers))
    return false;
  return Object.entries(steers as Record<string, unknown>).some(
    ([id, status]) =>
      status === 'pending' &&
      !isMissingHistoryUserTurn(meta, id) &&
      id !== settled,
  );
}

export function hasFreshPendingUserTurnActivation(
  meta: Record<string, unknown> | undefined,
  nowMs: number,
): boolean {
  if (!meta || !hasPendingUserTurnActivation(meta)) return false;
  let dispatchedAtMs = NaN;
  if (
    typeof meta.lastMessageAt === 'number' &&
    Number.isFinite(meta.lastMessageAt)
  ) {
    dispatchedAtMs = meta.lastMessageAt;
  } else if (typeof meta.createdAt === 'string') {
    dispatchedAtMs = Date.parse(meta.createdAt);
  }
  return (
    Number.isFinite(dispatchedAtMs) &&
    nowMs - dispatchedAtMs < UNSTARTED_TRAILING_USER_TURN_TIMEOUT_MS
  );
}

function classifyLocalBusy(
  sessionId: string,
  snapshot: SessionLiveStatusSnapshot,
): SessionLiveStatusInspection | undefined {
  if (snapshot.presenceDetail) {
    return {
      sessionId,
      state: 'busy',
      detail: snapshot.presenceDetail,
      source: 'presence',
    };
  }
  if (hasFreshPendingUserTurnActivation(snapshot.sessionMeta, snapshot.nowMs)) {
    return {
      sessionId,
      state: 'busy',
      detail: 'initializing',
      source: 'pointer',
    };
  }
  return undefined;
}

/**
 * Inspect whether a schedule's bound chat is currently busy before manual
 * Run now. Checks ephemeral presence and fresh pending dispatch pointers first,
 * then queries the owning daemon's authoritative `session/live-status` RPC and
 * re-reads local state after the await to close check-to-dispatch races.
 */
export async function inspectBoundSessionLiveStatus(args: {
  sessionId: string;
  machineId: string | undefined;
  getSnapshot: () => SessionLiveStatusSnapshot;
  requestDaemonLiveStatus?: () => Promise<unknown>;
}): Promise<SessionLiveStatusInspection> {
  const { sessionId, machineId } = args;
  const initial = args.getSnapshot();
  const localBusy = classifyLocalBusy(sessionId, initial);
  if (localBusy) return localBusy;

  if (!machineId) {
    return {
      sessionId,
      state: 'unknown',
      source: 'none',
      reason: 'session_not_found',
    };
  }

  if (initial.machineState === 'offline') {
    return {
      sessionId,
      state: 'unknown',
      source: 'none',
      reason: 'machine_offline',
    };
  }

  if (!args.requestDaemonLiveStatus) {
    if (initial.machineState === 'online') {
      return { sessionId, state: 'idle', source: 'presence' };
    }
    return {
      sessionId,
      state: 'unknown',
      source: 'none',
      reason: 'presence_unsynced',
    };
  }

  let daemonResult: unknown;
  try {
    daemonResult = await args.requestDaemonLiveStatus();
  } catch {
    daemonResult = undefined;
  }

  // Re-read local presence/pointer after the async RPC to catch a chat that
  // started running while the status query was in flight.
  const latest = args.getSnapshot();
  const latestBusy = classifyLocalBusy(sessionId, latest);
  if (latestBusy) return latestBusy;

  if (daemonResult && typeof daemonResult === 'object') {
    const reply = daemonResult as Record<string, unknown>;
    const matchesSession =
      reply.sessionId === undefined || reply.sessionId === sessionId;
    if (reply.success === true && matchesSession) {
      if (
        reply.state === 'running' ||
        reply.state === 'initializing' ||
        reply.state === 'waiting'
      ) {
        return {
          sessionId,
          state: 'busy',
          detail: reply.state,
          source: 'rpc',
        };
      }
      if (reply.state === 'idle' || reply.state === 'unknown') {
        return { sessionId, state: 'idle', source: 'rpc' };
      }
    }
  }

  return {
    sessionId,
    state: 'unknown',
    source: 'none',
    reason: 'rpc_failed',
  };
}
