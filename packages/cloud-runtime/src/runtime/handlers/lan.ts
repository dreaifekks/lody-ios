import { lanTerminalEndpoint } from '../../protocol/catalog.ts';
import { machineRpc } from '../machine-rpc';
import { openSettings } from '../settings';
import {
  machineHostsVoice,
  sharedVoiceAgent,
  voiceAgentOptions,
  voiceReply,
} from '../voice';
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
  channel.handle('voiceAgents', async (args) => {
    if (args.workspaceId !== state.workspace || !state.metaReplica)
      throw new Error('metadata_not_ready');
    const replica = state.metaReplica;
    const { flock } = await openSettings(
      `${args.workspaceId}:wf:workspace`,
      getGrant,
      AbortSignal.timeout(30000),
    );
    if (state.workspace !== args.workspaceId || state.metaReplica !== replica)
      throw new Error('workspace_changed');
    return {
      shared: sharedVoiceAgent(flock.scan()),
      agents: voiceAgentOptions(replica.flock, state.machineReplicas),
    };
  });
  channel.handle('machineVoice', async (args) => {
    if (args.workspaceId !== state.workspace || !state.metaReplica)
      throw new Error('metadata_not_ready');
    const replica = state.metaReplica;
    const { request } = args;
    if (typeof request.action !== 'string')
      throw new Error('invalid_voice_request');
    let machineId = args.machineId;
    let params = request;
    if (request.action === 'start') {
      let agent = args.agent;
      if (!agent) {
        const { flock } = await openSettings(
          `${args.workspaceId}:wf:workspace`,
          getGrant,
          AbortSignal.timeout(30000),
        );
        agent = sharedVoiceAgent(flock.scan()) ?? undefined;
      }
      if (!agent) return { success: false, error: 'voice_no_agent' };
      machineId = agent.machineId;
      params = { ...request, configId: agent.configId };
    }
    if (state.workspace !== args.workspaceId || state.metaReplica !== replica)
      throw new Error('workspace_changed');
    if (
      !machineId ||
      !(state.catalogs.get('meta')?.machineIds ?? []).includes(machineId)
    )
      return { success: false, error: 'machine_unavailable' };
    if (!machineHostsVoice(replica.flock, machineId))
      return { success: false, error: 'voice_unsupported' };
    const reply = await machineRpc(
      args.workspaceId,
      machineId,
      'machine/voice',
      params,
      getGrant,
      AbortSignal.timeout(request.action === 'start' ? 180000 : 30000),
    );
    return { ...voiceReply(reply), machineId };
  });
}
