import { lanTerminalEndpoint } from '../../protocol/catalog.ts';
import { machineRpc } from '../machine-rpc';
import type { RuntimeContext } from './context.ts';

/** LAN diagnostics use the same heartbeat projection as creation and Role discovery. */
export function registerLan(ctx: RuntimeContext) {
  const { channel, state, getGrant } = ctx;
  const field = (room: string, key: string) =>
    state.metaReplica?.flock.get(['m', room, key]) ??
    (
      state.metaReplica?.flock.get(['m', room]) as
        Record<string, unknown> | undefined
    )?.[key];
  const text = (room: string, key: string) => {
    const value = field(room, key);
    return typeof value === 'string' && value ? value : undefined;
  };
  channel.handle('machineStatus', async (args) => {
    if (args.workspaceId !== state.workspace || !state.metaReplica)
      throw new Error('metadata_not_ready');
    const machineIds = state.catalogs.get('meta')?.machineIds ?? [];
    if (args.action === 'list') {
      const online = new Set(state.presence.onlineMachineIds);
      return {
        machines: machineIds.map((id) => ({
          id,
          name: text(`machine-${id}`, 'name'),
          alias: text(`machine-${id}`, 'lanAlias'),
          os: text(`machine-${id}`, 'os'),
          version: text(`machine-${id}`, 'cliVersion'),
          online: state.presence.state === 'live' ? online.has(id) : undefined,
        })),
      };
    }
    if (!args.machineId || !machineIds.includes(args.machineId))
      throw new Error('machine_unavailable');
    let sentAt = 0;
    const reply = await machineRpc(
      state.workspace,
      args.machineId,
      'machine/ping',
      { requestId: crypto.randomUUID() },
      getGrant,
      AbortSignal.timeout(6000),
      undefined,
      30000,
      () => {
        sentAt = performance.now();
      },
    );
    if (
      reply.error ||
      (reply.result as { success?: unknown })?.success !== true
    )
      throw new Error('machine_ping_failed');
    return { ms: Math.round(performance.now() - sentAt) };
  });
  channel.handle('lanFileTarget', (args) => {
    if (!state.metaReplica) return {};
    const owner = args.sessionId
      ? field(`session-${args.sessionId}`, 'machineId')
      : undefined;
    const machineId =
      typeof owner === 'string' && owner ? owner : args.machineId;
    if (!machineId) return {};
    const room = `machine-${machineId}`;
    const caps = field(room, 'protocolCapabilities');
    const endpoint = lanTerminalEndpoint(field(room, 'lanTerminal'));
    return {
      machineId,
      name: text(room, 'name'),
      lanTerminal: endpoint ? { version: 1 as const, ...endpoint } : undefined,
      protocolCapabilities:
        caps && typeof caps === 'object'
          ? Object.fromEntries(
              Object.entries(caps).filter(
                (entry): entry is [string, number] =>
                  typeof entry[1] === 'number' && Number.isFinite(entry[1]),
              ),
            )
          : undefined,
    };
  });
}
