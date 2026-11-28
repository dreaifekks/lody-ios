export { createRemoteRoostSessionDataFactory } from './packages/components/src/lib/roost-session-bridge';
export { createRoostHistoryReplica } from './packages/components/src/lib/roost-history-replica';
export { roostCloudHistoryBinding, RoostCloudHistoryRequestError, RoostCloudHistoryTransportError } from './packages/shared/src/roost-cloud-history';
import { roostCloudHistoryReadResultSchema } from './packages/shared/src/roost-cloud-history';
export const parseRoostCloudHistoryReadResult = (value: unknown) => roostCloudHistoryReadResultSchema.parse(value);
export { readSessionHistoryMetadata } from './session-data';
export { buildPendingUserHistoryEntry } from './packages/shared/src/session-input';
export { HistoryEntryWriteSchema, parseHistoryWrite } from './packages/shared/src/history-write-schema';
export { resolveNewSessionHistoryBackend, machineSupportsSessionHistoryProtocol, machineSupportsSessionHistoryIncremental, machineSupportsSessionHistorySubscription, machineSupportsSessionHistoryPatches, machineSupportsSessionHistoryInspection, machineSupportsSessionInputAcceptance, machineSupportsSessionInputDispatch } from './packages/shared/src/machine-protocol-capabilities';
export { createAcceptedSessionInputs, SessionInputNotSentError } from './packages/components/src/lib/session-accepted-inputs';
export { createSessionInputStorage } from './packages/components/src/lib/session-input-storage';

export { createWorkspaceAcceptedInputs } from './packages/components/src/lib/workspace-accepted-inputs';
export { createSessionOperationScope } from './packages/components/src/lib/session-send-resources';

export { sessionHistoryWriteIntentDigest } from './packages/shared/src/session-access';
export { SESSION_HISTORY_SUBSCRIPTION_TIMEOUT_MS } from './packages/shared/src/message-schemas';
import { SessionHistorySubscriptionResponseSchema } from './packages/shared/src/message-schemas';
export const parseHistorySubscriptionResponse = (value: unknown) => SessionHistorySubscriptionResponseSchema.parse(value);
