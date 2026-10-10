export type MentionCategory =
  'file' | 'skill' | 'session' | 'role' | 'issue' | 'pr' | 'cmd';
export type MentionItem = {
  path: string;
  name: string;
  kind: MentionCategory | 'directory';
  subtitle: string;
  insertText?: string;
  /** A Role entry runs the instance `path` names: its Role, and the name of the instance's group. */
  role?: { id: string; name: string; instance: string };
};
export type MentionSource = {
  workspaceId: string;
  sessionId?: string;
  projectId?: string;
  machineId?: string;
  agentConfigId?: string;
  cliType?: string;
  agentType?: string;
};
export type MentionCatalog = {
  items: MentionItem[];
  truncated: boolean;
  incomplete: boolean;
};
