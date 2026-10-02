/** A computer of the workspace, as its metadata names it. */
export type WorkspaceMachine = {
  id: string;
  name?: string;
  /** The short name the members of a LAN gave it. */
  alias?: string;
  os?: string;
  version?: string;
};

/** How a computer answered its last ping through the hub. */
export type MachineReach =
  | { state: 'checking' }
  | { state: 'online'; ms: number }
  | { state: 'offline' };
