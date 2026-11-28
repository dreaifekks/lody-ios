import type { Flock } from '@loro-dev/flock-wasm/base64';
import type { StreamsClient } from '@loro-dev/streams-client';
import type { Catalog, Project } from '../../models/catalog.ts';
import type { MachinePresence } from '../../models/machines.ts';
import type { PinSection } from '../../contract/status-view.ts';
import type { Grant, SessionRuntimeEvent } from '../../contract/methods.ts';
import type { createChannel } from '../channel.ts';
import type { FileContext } from '../files';
import { sessionFileRootMounts } from '../../protocol/session-file-roots.ts';

export type RuntimeChannel = ReturnType<typeof createChannel>;
export type MetaReplica = { flock: Flock; client: StreamsClient };
export type GrantProvider = (() => Promise<Grant>) & {
  invalidate?: (failedToken?: string) => void;
};

export type RuntimeState = {
  workspace: string;
  userId: string;
  /** From `start`: the member cannot write the workspace (viewer). */
  workspaceReadOnly: boolean;
  metaReplica: MetaReplica | undefined;
  presence: MachinePresence;
  getLiveSessionPresence?: (
    sessionId: string,
  ) => 'running' | 'initializing' | 'waiting' | undefined;
  knownProjects: Pick<Project, 'id' | 'repoFullName'>[];
  readonly machineReplicas: Map<string, Flock>;
  readonly catalogs: Map<string, Catalog>;
  readonly unhealthy: Set<string>;
  /** Active error-free stream catch-ups keyed by watcher mode (`meta` or `machineId`). */
  readonly catchingUp?: Map<string, Promise<void>>;
  /** Live `${workspace}:wf:workspace` replica, shared by Status view and Agent Roles. */
  workspaceReplica:
    (MetaReplica & { missing?: boolean; synced?: boolean }) | undefined;
  /** Last read `pinSection` rows; `loaded` is false until the first read. */
  pinSections: { sections: PinSection[]; loaded: boolean };
};

export type RuntimeContext = {
  channel: RuntimeChannel;
  state: RuntimeState;
  getGrant: GrantProvider;
  broker: (operation: string, args: object) => Promise<unknown>;
  publish: () => void;
  publishSubscriptions: () => void;
  emitSession: (event: SessionRuntimeEvent) => void;
  markDispatch: (
    sessionId: string,
    turnId: string,
    queued?: boolean,
  ) => Promise<void>;
  /** Status view inputs from the current replicas; undefined before metadata. */
  statusSources: () =>
    import('../status-view.ts').StatusViewSources | undefined;
  /** One server-clock calibration sample; resolves whether it was accepted. */
  syncClock?: () => Promise<boolean>;
  /** The host is active; time-based Status view republishing runs only then. */
  setForeground?: (active: boolean) => void;
  /** Drops a replica holding a commit its append never landed, and re-bootstraps it. */
  discardReplica: (
    replica: import('../status-view.ts').StatusViewDirtyReplica,
    flock: Flock,
  ) => void;
  /** Observes the current meta replica, following it across reconnects. */
  observeMeta: (wake: () => void) => () => void;
  /** Restarts the live workspace settings read, keeping the current replica. */
  refreshWorkspace: () => void;
  watch: (mode: string) => void;
  startPresence: () => void;
  stopPresence: () => void;
  disposeProviderOperations?: () => Promise<{ unconfirmedFlowIds: string[] }>;
};

export function scopedWorkspaceGrant(
  { state, getGrant }: RuntimeContext,
  workspaceId: string,
  userId: string,
): GrantProvider {
  const check = () => {
    if (state.workspace !== workspaceId || state.userId !== userId)
      throw new Error('workspace_changed');
  };
  return Object.assign(
    async () => {
      check();
      const value = await getGrant();
      check();
      return value;
    },
    {
      invalidate: (failedToken?: string) => {
        if (state.workspace === workspaceId && state.userId === userId)
          getGrant.invalidate?.(failedToken);
      },
    },
  );
}

export function machineFor(
  { state, getGrant }: RuntimeContext,
  sessionId: string,
  path: string,
): FileContext & { localProjectId?: string } {
  if (!state.metaReplica || state.unhealthy.size)
    throw new Error('metadata_not_ready');
  if (typeof path !== 'string' || path.length > 32768 || path.includes('\0'))
    throw new Error('invalid_path');
  const sessions = state.catalogs.get('meta')?.sessions;
  const session = sessions?.find((item) => item.id === sessionId);
  if (!session || !state.machineReplicas.has(session.machineId))
    throw new Error('machine_unavailable');
  const localPrefix = `${session.machineId}:local:`;
  // File roots belong to the owner: a child Tab reads its parent's Project group.
  const owner = session.parentSessionId
    ? sessions?.find((item) => item.id === session.parentSessionId)
    : session;
  return {
    workspaceId: state.workspace,
    machineId: session.machineId,
    // Code Collab ownership lives in workspace Meta Flock, not the session doc.
    ownerSessionId: session.parentSessionId ?? session.id,
    mounts: sessionFileRootMounts((owner ?? session).projectRun),
    localProjectId: session.projectId.startsWith(localPrefix)
      ? session.projectId.slice(localPrefix.length)
      : undefined,
    getGrant,
    signal: AbortSignal.timeout(35000),
  };
}
