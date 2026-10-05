/** A computer of the workspace, as its metadata names it. */
export type WorkspaceMachine = {
  id: string;
  name?: string;
  /** The short name the members of a LAN gave it. */
  alias?: string;
  os?: string;
  version?: string;
  /** Whether its presence heartbeat is fresh; undefined while the presence channel is not synced. */
  online?: boolean;
};

/** Whether a computer is online, and how long its last ping took when it answered one. */
export type MachineReach =
  | { state: 'checking' }
  | { state: 'online'; ms?: number }
  | { state: 'offline' };
