// Browser-safe exports needed by the upstream Roost bridge.
export { createRoostSessionData, createRoostDirectoryRow, projectRoostSegments } from './packages/shared/src/session-data/roost';
export { applySessionHistoryPatches } from './packages/shared/src/session-data/history-patches';
export { readSessionHistoryMetadata, selectTurnOutput } from './packages/shared/src/session-data/read';
