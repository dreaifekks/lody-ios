export type UsageWindow = {
  label?: string;
  usedPercent: number;
  duration: number | null;
  resetsAt: number | null;
};
export type AgentQuota = {
  id: string;
  provider: string;
  /** The provider (agent config) whose account the quota belongs to; absent on legacy rows. */
  configId?: string;
  name?: string;
  windows: UsageWindow[];
};
export type AgentUsage = {
  configs: { id: string; name: string; provider: string; eligible: boolean }[];
  quotas: AgentQuota[];
};
