import {
  isEnvelope,
  machineRpc,
  openPayload,
  sealPayload,
  subscribeMachineHistory,
  type RpcReply,
} from './machine-rpc';
import type { HistoryTokenIntent } from '../contract/sharing.ts';
import {
  parseHistorySubscriptionResponse,
  SESSION_HISTORY_SUBSCRIPTION_TIMEOUT_MS,
  sessionHistoryWriteIntentDigest,
  type HistoryPublication,
  type HistorySubscriptionOpen,
} from './upstream-roost.js';

export type HistoryProofBroker = (
  intent: HistoryTokenIntent,
) => Promise<unknown>;

type Grant = () => Promise<{ token: string; gatewayBaseUrl: string }>;
type OwnerResponse = {
  type: string;
  sessionId: string;
  success: boolean;
  operation?: string;
  result?: unknown;
  historyRevision?: number;
  historyCount?: number;
  pageTurns?: unknown;
  error?: string;
  retryReason?: 'superseded';
  historyChange?: unknown;
};

type Turn = {
  id: string;
  role: 'user' | 'assistant' | 'system';
  timestamp: string;
} & Record<string, unknown>;
export type RoostWindow = {
  checkpoint?: string;
  count: number;
  start: number;
  cursor: string | null;
  turns: readonly Turn[];
};

/** The machine remains the authority for a Roost session's history. */
export function createRoostHistoryTransport(options: {
  workspaceId: string;
  machineId: string;
  sessionId: string;
  getGrant: Grant;
  getHistoryProof: HistoryProofBroker;
  signal: AbortSignal;
  isCurrent?: () => boolean;
}) {
  const { workspaceId, machineId, sessionId, signal } = options;
  const checkScope = () => {
    if (options.isCurrent && !options.isCurrent())
      throw new Error('workspace_changed');
  };
  const getGrant = async () => {
    checkScope();
    const grant = await options.getGrant();
    checkScope();
    return grant;
  };
  const getProof = async (
    requestSignal: AbortSignal,
    edit?: { requestId: string; intentDigest: string },
  ) => {
    requestSignal.throwIfAborted();
    checkScope();
    const proof = await options.getHistoryProof({
      workspaceId,
      machineId,
      sessionId,
      ...edit,
    });
    requestSignal.throwIfAborted();
    checkScope();
    if (typeof proof !== 'string' || !proof || proof.length > 8192)
      throw new Error('history_authorization_unavailable');
    return proof;
  };
  const decode = async (reply: RpcReply, requestSignal: AbortSignal) => {
    requestSignal.throwIfAborted();
    checkScope();
    if (reply.error) throw new Error(reply.error.code ?? 'history_rpc_failed');
    if (!isEnvelope(reply.result) || reply.result.ownerSessionId !== sessionId)
      throw new Error('invalid_history_envelope');
    const response = await openPayload(reply.result);
    requestSignal.throwIfAborted();
    checkScope();
    if (!response || typeof response !== 'object')
      throw new Error('invalid_history_response');
    return response;
  };
  const request = async (
    method: 'session/history-read' | 'session/history-write',
    payload: Record<string, unknown>,
    edit?: { requestId: string; intentDigest: string },
  ): Promise<OwnerResponse> => {
    const proof = await getProof(signal, edit);
    const params = await sealPayload(sessionId, {
      sessionId,
      ...payload,
      ...(edit ? { writeProof: proof } : { readProof: proof }),
    });
    signal.throwIfAborted();
    checkScope();
    const reply = await machineRpc(
      workspaceId,
      machineId,
      method,
      params,
      getGrant,
      AbortSignal.any([signal, AbortSignal.timeout(30_000)]),
      undefined,
      30_000,
      edit?.requestId,
    );
    const result = (await decode(reply, signal)) as OwnerResponse;
    const expected =
      method === 'session/history-write'
        ? 'session/history-write_response'
        : 'session/history-read_response';
    if (
      result.type !== expected ||
      result.sessionId !== sessionId ||
      typeof result.success !== 'boolean' ||
      (edit && result.operation !== payload.operation) ||
      (payload.operation === 'respond_permission' &&
        result.success &&
        typeof result.result !== 'boolean')
    )
      throw new Error('invalid_history_response');
    return result;
  };
  return {
    read: (query: { kind: string; [key: string]: unknown }) =>
      request('session/history-read', { query }),
    write: async (operation: string, payload: Record<string, unknown>) => {
      const requestId = crypto.randomUUID();
      const intentDigest = await sessionHistoryWriteIntentDigest(
        requestId,
        operation,
        payload,
      );
      return request(
        'session/history-write',
        { operation, payload },
        { requestId, intentDigest },
      );
    },
    subscribe: async (
      open: HistorySubscriptionOpen,
      publish: (publication: HistoryPublication) => void,
      readerSignal: AbortSignal,
    ) => {
      const bound = AbortSignal.any([signal, readerSignal]);
      const readProof = await getProof(bound);
      const lease = AbortSignal.any([
        bound,
        AbortSignal.timeout(SESSION_HISTORY_SUBSCRIPTION_TIMEOUT_MS),
      ]);
      const params = await sealPayload(sessionId, {
        sessionId,
        readProof,
        subscription: open,
      });
      lease.throwIfAborted();
      await subscribeMachineHistory({
        workspaceId,
        machineId,
        params,
        getGrant,
        signal: lease,
        timeoutMs: SESSION_HISTORY_SUBSCRIPTION_TIMEOUT_MS,
        closeParams: () =>
          sealPayload(sessionId, {
            sessionId,
            readProof,
            subscription: { action: 'close', id: open.id },
          }),
        onReply: async (reply) => {
          const frame = parseHistorySubscriptionResponse(
            await decode(reply, lease),
          );
          if (frame.sessionId !== sessionId || frame.subscriptionId !== open.id)
            throw new Error('invalid_history_subscription');
          if (frame.event === 'publication') {
            publish(frame.publication);
            return false;
          }
          if (frame.error) throw new Error(frame.error);
          return true;
        },
      });
    },
  };
}
