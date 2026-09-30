export type Project = {
  id: string;
  machineId: string;
  name: string;
  rootPath: string;
};
export type Session = {
  lastModel?: { modelId?: string; name?: string } | null;
  cliType?: string;
  agentType?: string;
  resume?: string;
  id: string;
  machineId: string;
  title: string;
  openedBySessionId?: string;
  openedByRootSessionId?: string;
  parentSessionId?: string;
  status: string;
  archived: boolean;
  pinned: boolean;
  projectId: string;
  createdAt: string;
  latestUserMsgId?: string;
  lastMessageAt?: number;
  lastReadAt?: number;
  lastRunningSeen?: number;
  awaitingUserSince?: number;
  branchName?: string;
  pullRequests?: import('./pull-request').PullRequestReference[];
  diff?: { add: number; del: number };
};
export type Catalog = {
  agentUsage?: Record<string, import('./agent-usage.ts').AgentUsage>;
  projects: Project[];
  sessions: Session[];
  machineIds: string[];
  machineNames?: Record<string, string>;
  /** Where each LAN member accepts terminal connections; absent off a LAN. */
  machineTerminals?: Record<string, LanTerminalEndpoint>;
};
export type LanTerminalEndpoint = { host: string; port: number };
export type SavedCatalog = { catalog: Catalog; syncedAt: number };
export type Connection = {
  state: 'live' | 'syncing' | 'offline';
  machines: number;
  syncedAt?: number;
};
