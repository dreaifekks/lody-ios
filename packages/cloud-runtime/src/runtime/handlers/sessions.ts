import { projectRows } from '../../protocol/catalog.ts';
import {
  archiveSession,
  deleteSession,
  markSessionRead,
  pinSession,
  renameSession,
} from '../archive-session';
import {
  creationOptions,
  createSession,
  forgetCreation,
} from '../create-session';
import { sessionMcpSelection } from '../mcp';
import { expandMentions } from '../mention-expansion';
import { expandShortcuts, shortcutAccess } from '../prompt-shortcuts';
import {
  checkTurnQuota,
  controlTurn,
  editSession,
  releaseDeletedSessions,
  respondPermission,
  sendTurn,
  confirmTurn,
  sessionQueue,
  sessionDoc,
} from '../session';
import {
  scopedShortcutCloud,
  type MetaReplica,
  type RuntimeContext,
} from './context.ts';
import type { registerMentions } from './mentions.ts';

const cleared = (value?: { value: string | null }) =>
  value === undefined ? undefined : value.value;

export function registerSessions(
  ctx: RuntimeContext,
  getMentions: ReturnType<typeof registerMentions>,
) {
  const { channel, state, getGrant } = ctx;
  let creating = false;
  const creationEnded = new Map<string, number>();
  function metaWrite(args: { workspaceId: string }, healthy = false) {
    if (
      args.workspaceId !== state.workspace ||
      !state.metaReplica ||
      (healthy && state.unhealthy.size)
    )
      throw new Error('metadata_not_ready');
    return state.metaReplica;
  }
  function republish(replica: MetaReplica) {
    if (state.metaReplica !== replica) return;
    state.catalogs.set('meta', projectRows(replica.flock.scan(), 'meta'));
    ctx.publish();
  }
  channel.handle('createSession', async (args) => {
    if (args.workspaceId !== state.workspace) return { state: 'rejected' };
    if (creating || !state.metaReplica || state.unhealthy.size)
      return { state: 'rejected', reason: 'metadata_not_ready' };
    const replica = state.metaReplica;
    creating = true;
    try {
      const options = creationOptions(
        args.projectId,
        replica.flock,
        state.machineReplicas,
      );
      const result = await createSession(args, options, replica, getGrant);
      if (result.state === 'created') republish(replica);
      return result;
    } catch (error) {
      if (error instanceof Error && error.message === 'session_already_exists')
        return { state: 'unknown' };
      if (
        error instanceof Error &&
        ['timeout', 'network_error', 'metadata_not_ready'].includes(
          error.message,
        )
      )
        return { state: 'rejected', reason: 'metadata_not_ready' };
      return { state: 'rejected' };
    } finally {
      creating = false;
      creationEnded.set(args.sessionId, Date.now());
    }
  });
  channel.handle('confirmSessionCreation', (args) => {
    if (
      args.workspaceId !== state.workspace ||
      !state.metaReplica ||
      state.unhealthy.size
    )
      return { state: 'not_ready' };
    if (creating) return { state: 'pending' };
    if (
      state.metaReplica.flock.get(['e', `session-${args.sessionId}`]) !==
      undefined
    )
      return { state: 'seen' };
    if ((state.metaReadAt ?? 0) <= (creationEnded.get(args.sessionId) ?? 0))
      return { state: 'pending' };
    forgetCreation(args.sessionId);
    return { state: 'absent' };
  });
  channel.handle('confirmSessionTurn', async (args) => {
    if (
      !state.metaReplica ||
      state.unhealthy.size ||
      !sessionDoc(args.sessionId)
    )
      return { state: 'not_ready' };
    const result = confirmTurn(args);
    if (result.state === 'queued')
      await ctx.markDispatch(args.sessionId, args.id, true);
    if (result.state === 'uploaded' && result.undispatched) {
      const room = `session-${args.sessionId}`;
      const meta = state.metaReplica?.flock;
      const pointer =
        meta?.get(['m', room, 'latestUserMsgId']) ??
        (meta?.get(['m', room]) as Record<string, unknown> | undefined)
          ?.latestUserMsgId;
      if (pointer !== args.id) await ctx.markDispatch(args.sessionId, args.id);
    }
    if (result.state === 'uploaded' || result.state === 'queued')
      return { state: 'seen', delivery: result.state };
    return result;
  });
  channel.handle('deleteSession', async (args) => {
    const replica = metaWrite(args, true);
    const sessionIds = await deleteSession(args, replica);
    if (state.metaReplica === replica) releaseDeletedSessions(sessionIds);
    republish(replica);
    return { sessionIds };
  });
  channel.handle('archiveSession', async (args) => {
    const replica = metaWrite(args);
    await archiveSession(args, replica, state.machineReplicas, getGrant);
    republish(replica);
    return {};
  });
  channel.handle('pinSession', async (args) => {
    const replica = metaWrite(args);
    await pinSession(args, replica);
    republish(replica);
    return {};
  });
  channel.handle('markSessionRead', async (args) => {
    const replica = metaWrite(args);
    await markSessionRead(args, replica);
    republish(replica);
    return {};
  });
  channel.handle('renameSession', async (args) => {
    const replica = metaWrite(args);
    await renameSession(args, replica);
    republish(replica);
    return {};
  });
  channel.handle('sessionQueue', (args) => {
    if (
      args.userId !== state.userId ||
      !state.metaReplica ||
      state.unhealthy.size
    )
      throw new Error('metadata_not_ready');
    const meta = state.metaReplica.flock.get([
      'm',
      `session-${args.sessionId}`,
    ]) as Record<string, any> | undefined;
    if (!meta || meta.isArchived) throw new Error('session_not_ready');
    return sessionQueue(args);
  });
  channel.handle('respondPermission', respondPermission);
  channel.handle('controlTurn', controlTurn);
  channel.handle('checkTurnQuota', checkTurnQuota);
  channel.handle('editSession', (args) => {
    if (!state.metaReplica || state.unhealthy.size)
      return { state: 'not_sent', reason: 'metadata_not_ready' };
    const meta = state.metaReplica.flock.get([
      'm',
      `session-${args.sessionId}`,
    ]) as Record<string, any> | undefined;
    if (!meta) return { state: 'not_sent', reason: 'session_not_ready' };
    const capability = state.machineReplicas
      .get(meta.machineId)
      ?.get(['acpCapability', meta.agentConfigId]) as
      Record<string, any> | undefined;
    return editSession(args, meta, capability);
  });
  channel.handle('sendTurn', (wire) => {
    if (!state.metaReplica)
      return { state: 'not_sent', reason: 'metadata_not_ready' };
    const args = {
      ...wire,
      modelId: cleared(wire.modelId),
      reasoningEffort: cleared(wire.reasoningEffort),
    };
    const sourceWorkspace = state.workspace;
    const source = {
      workspaceId: sourceWorkspace,
      sessionId: args.sessionId,
      userId: args.userId ?? '',
      cliType: args.cliType,
      agentType: args.agentType,
    };
    const access = shortcutAccess(
      sourceWorkspace,
      state.userId,
      scopedShortcutCloud(ctx, sourceWorkspace, state.userId),
      AbortSignal.timeout(30000),
    );
    const scoped = () => {
      if (state.workspace !== sourceWorkspace || state.userId !== args.userId)
        throw new Error('workspace_changed');
    };
    const room = `machine-${args.machineId}`;
    const protocolCapabilities = (state.metaReplica.flock.get([
      'm',
      room,
      'protocolCapabilities',
    ]) ??
      (
        state.metaReplica.flock.get(['m', room]) as
          Record<string, any> | undefined
      )?.protocolCapabilities) as Record<string, number> | undefined;
    return sendTurn(
      args,
      (text) => {
        const expand = (part: string) =>
          expandMentions(
            part,
            (category) => getMentions({ ...source, category }),
            sourceWorkspace,
          );
        if (globalThis.location?.protocol === 'lody-hub:') return expand(text);
        return expandShortcuts(text, access.list, access.read, expand);
      },
      async (persisted) => {
        scoped();
        const ids = await sessionMcpSelection(
          sourceWorkspace,
          getGrant,
          persisted,
          AbortSignal.timeout(30000),
        );
        scoped();
        return ids;
      },
      protocolCapabilities,
    );
  });
}
