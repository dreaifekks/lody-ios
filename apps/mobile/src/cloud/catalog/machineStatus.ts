import { lanHubLatency, machineStatusRaw } from '@lody-ios/kit';
import type { WorkspaceMachine } from '../../models/connection.ts';

export type ConnectionService = {
  machines(workspaceId: string): Promise<WorkspaceMachine[]>;
  /** Milliseconds for the computer to answer through the hub; rejects when it does not. */
  ping(workspaceId: string, machineId: string): Promise<number>;
  /** Milliseconds for the LAN hub to answer a request, or null when it does not. */
  hubLatency(): Promise<number | null>;
};

const text = (value: unknown) =>
  typeof value === 'string' && value ? value : undefined;

async function machines(workspaceId: string) {
  const result: unknown = JSON.parse(
    await machineStatusRaw(JSON.stringify({ workspaceId, action: 'list' })),
  );
  const list = (result as { machines?: unknown } | null)?.machines;
  if (!Array.isArray(list)) throw new Error('invalid_machines');
  return list
    .filter((item) => typeof item?.id === 'string' && item.id)
    .map((item): WorkspaceMachine => ({
      id: item.id,
      name: text(item.name),
      alias: text(item.alias),
      os: text(item.os),
      version: text(item.version),
      online: typeof item.online === 'boolean' ? item.online : undefined,
    }));
}

async function ping(workspaceId: string, machineId: string) {
  const result: unknown = JSON.parse(
    await machineStatusRaw(
      JSON.stringify({ workspaceId, action: 'ping', machineId }),
    ),
  );
  const ms = (result as { ms?: unknown } | null)?.ms;
  if (typeof ms !== 'number' || !Number.isFinite(ms) || ms < 0)
    throw new Error('invalid_ping');
  return ms;
}

export const connectionService: ConnectionService = {
  machines,
  ping,
  hubLatency: () => lanHubLatency(),
};
