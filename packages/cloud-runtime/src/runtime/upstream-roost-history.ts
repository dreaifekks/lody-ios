import {
  createRemoteRoostSessionDataFactory,
  createRoostHistoryReplica,
  parseRoostCloudHistoryReadResult,
  readSessionHistoryMetadata,
  roostCloudHistoryBinding,
  RoostCloudHistoryRequestError,
  RoostCloudHistoryTransportError,
  type RoostHistorySyncState,
} from './upstream-roost.js';
import { createRoostHistoryTransport, type RoostWindow } from './roost-history';

declare const LODY_MOBILE_STORAGE_SUFFIX: string;

export function roostStorageAccount(accountId: string): string {
  const suffix =
    typeof LODY_MOBILE_STORAGE_SUFFIX === 'undefined'
      ? ''
      : LODY_MOBILE_STORAGE_SUFFIX;
  return suffix ? JSON.stringify([suffix, accountId]) : accountId;
}

export type MobileRoostCloudHistory = {
  metadata: () => Record<string, unknown> | undefined;
  observe: (wake: () => void) => () => void;
};

type RoostSessionOptions = Parameters<typeof createRoostHistoryTransport>[0] & {
  accountId?: string | null;
  patches?: boolean;
  coherentInspection?: boolean;
  incremental?: boolean;
  live?: boolean;
  onSubscription?: (state: { checkpoint: string } | { reason: string }) => void;
  cloud?: MobileRoostCloudHistory;
  onCloudRoute?: (active: boolean) => void;
  onHistorySync?: (state: RoostHistorySyncState) => void;
};

export function createMobileRoostSessionData(
  options: RoostSessionOptions,
  subscribeWake?: (wake: () => void) => () => void,
) {
  const transport = createRoostHistoryTransport(options);
  const cloud = options.cloud;
  let cloudActive = false;
  return createRemoteRoostSessionDataFactory({
    ...options,
    accountId: options.accountId
      ? roostStorageAccount(options.accountId)
      : options.accountId,
    active: () => !options.signal.aborted && (options.isCurrent?.() ?? true),
    ...(cloud && {
      onCloudHistoryRoute: (active: boolean) => {
        cloudActive = active;
        options.onCloudRoute?.(active);
      },
      cloudHistory: (sessionId: string) => {
        return createRoostHistoryReplica({
          accountId: options.accountId
            ? roostStorageAccount(options.accountId)
            : options.accountId,
          workspaceId: options.workspaceId,
          machineId: options.machineId,
          sessionId,
          replicaNamespace: 'mobile',
          getBinding: () => roostCloudHistoryBinding(cloud.metadata()),
          observeBinding: cloud.observe,
          requestGrant: async (signal) => {
            const scope = AbortSignal.any([signal, options.signal]);
            scope.throwIfAborted();
            if (options.isCurrent && !options.isCurrent())
              throw new Error('workspace_changed');
            const grant = await options.getHistoryProof({
              workspaceId: options.workspaceId,
              sessionId,
              machineId: options.machineId,
              cloudHistory: true,
            });
            scope.throwIfAborted();
            if (options.isCurrent && !options.isCurrent())
              throw new Error('workspace_changed');
            if (grant && typeof grant === 'object') {
              if ('failure' in grant && grant.failure === 'transport')
                throw new RoostCloudHistoryTransportError();
              if ('status' in grant && typeof grant.status === 'number')
                throw new RoostCloudHistoryRequestError(grant.status);
            }
            return parseRoostCloudHistoryReadResult(grant);
          },
          onSyncState: (sync) => {
            if (cloudActive) options.onSubscription?.(sync);
          },
        });
      },
    }),
    subscribeWake,
    subscribeHistory: async (_machineId, _sessionId, open, publish, signal) => {
      let published = false;
      try {
        await transport.subscribe(
          open,
          (publication) => {
            published = true;
            publish(publication);
            if (!cloudActive)
              options.onSubscription?.({ checkpoint: publication.checkpoint });
          },
          signal,
        );
        if (!published && !signal.aborted)
          throw new Error('history_subscription_unavailable');
      } catch (error) {
        if (!cloudActive && !signal.aborted && !options.signal.aborted)
          options.onSubscription?.({
            reason:
              error instanceof Error && error.message
                ? error.message
                : 'history_subscription_unavailable',
          });
        throw error;
      }
    },
    requestHistoryRead: (_machineId, _sessionId, query) =>
      transport.read(query),
    requestHistoryWrite: ({ operation, payload }) =>
      transport.write(operation, payload),
  })({ sessionId: options.sessionId });
}

/** Observe the upstream history in the native transcript's window format. */
export function createUpstreamRoostHistory(options: RoostSessionOptions) {
  let wake: (() => void) | undefined;
  let cloudActive = false;
  let sourceVersion = 0;
  const data = createMobileRoostSessionData(
    {
      ...options,
      onCloudRoute(active) {
        if (active !== cloudActive) sourceVersion++;
        cloudActive = active;
        options.onCloudRoute?.(active);
      },
    },
    (next) => {
      wake = next;
      return () => {
        wake = undefined;
      };
    },
  );
  let generation = 0;
  let consumed = 0;
  const changes: unknown[] = [];
  let notify: (() => void) | undefined;
  const observation = data.history.observe((change) => {
    changes.push(change);
    generation++;
    notify?.();
  });
  // The upstream observation exposes both rows and page promises. Observe
  // the unused rows rejection as well when the initial page fails.
  void observation.initial.catch(() => {});
  let initial: typeof observation.initialPage | undefined =
    observation.initialPage;
  const pageWindow = async (
    page: Awaited<typeof observation.initialPage>,
  ): Promise<RoostWindow> => {
    const source = sourceVersion;
    const turns = await Promise.all(
      page.rows.map(async (row) => {
        if (row.state !== 'ready' || !row.turnId)
          throw new Error('history_turn_unavailable');
        const read = await data.history.readTurn(row.turnId);
        if (
          read.state !== 'ready' ||
          !read.turn ||
          typeof read.turn !== 'object'
        )
          throw new Error('history_turn_unavailable');
        return read.turn as RoostWindow['turns'][number];
      }),
    );
    options.signal.throwIfAborted();
    if (source !== sourceVersion)
      throw new Error('history_observation_superseded');
    return {
      checkpoint: page.checkpoint,
      count: page.totalCount,
      start: page.startPosition,
      cursor: page.cursor,
      turns,
    };
  };
  options.signal.addEventListener(
    'abort',
    () => {
      observation.unsubscribe();
      data.dispose();
      notify?.();
    },
    { once: true },
  );
  return {
    sessionData: data,
    wake() {
      wake?.();
    },
    /** Re-reads the latest window even without a history change event. */
    reload() {
      generation++;
      notify?.();
    },
    metadataChanged(metadata: readonly Record<string, unknown>[] | undefined) {
      const seen = changes.splice(0);
      if (!metadata) return true;
      const roles = new Map(metadata.map((row) => [row.id, row.role]));
      return seen.some((change) => {
        if (!change || typeof change !== 'object') return true;
        const value = change as { kind?: unknown; ids?: unknown };
        return (
          value.kind !== 'changed' ||
          !Array.isArray(value.ids) ||
          value.ids.some((id) => !roles.has(id) || roles.get(id) === 'user')
        );
      });
    },
    async metadata() {
      if (cloudActive) return readSessionHistoryMetadata(data.history);
      return readSessionHistoryMetadata({
        readDirectory: data.history.readDirectory,
      });
    },
    async latest() {
      const started = generation;
      const pending = initial;
      initial = undefined;
      const page = pending
        ? await pending
        : await data.history.readLatestDirectoryPage(40);
      const window = await pageWindow(page);
      consumed = started;
      return window;
    },
    async older(window: RoostWindow) {
      if (!window.cursor) return window;
      const page = await pageWindow(
        await data.history.readOlderDirectoryPage(window.cursor, 40),
      );
      if (
        page.start + page.turns.length !== window.start ||
        page.count !== window.count ||
        (page.checkpoint &&
          window.checkpoint &&
          page.checkpoint !== window.checkpoint)
      )
        throw new Error('history_observation_superseded');
      return { ...page, turns: [...page.turns, ...window.turns] };
    },
    async waitForChange(_window: RoostWindow) {
      if (consumed === generation)
        await new Promise<void>((resolve) => {
          notify = resolve;
        });
      notify = undefined;
      options.signal.throwIfAborted();
      const started = generation;
      const window = await pageWindow(
        await data.history.readLatestDirectoryPage(40),
      );
      consumed = started;
      return window;
    },
  };
}
