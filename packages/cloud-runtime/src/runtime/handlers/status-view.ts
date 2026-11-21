import { projectRows } from '../../protocol/catalog.ts';
import { serverClock } from '../server-clock.ts';
import {
  applyStatusViewWrites,
  pinSectionRows,
  planCommand,
  snoozePresets,
} from '../status-view.ts';
import type { RuntimeContext } from './context.ts';

export function registerStatusView(ctx: RuntimeContext) {
  const { channel, state } = ctx;
  channel.handle(
    'statusViewCommand',
    async ({ workspaceId, command, scope }) => {
      if (workspaceId !== state.workspace) throw new Error('workspace_changed');
      const meta = state.metaReplica;
      const sources = ctx.statusSources();
      if (!meta || state.unhealthy.has('meta') || !sources)
        throw new Error('metadata_not_ready');
      const workspace = state.workspaceReplica;
      const writes = planCommand(sources, command, scope);
      const count = await applyStatusViewWrites(writes, meta, workspace);
      if (!count) return { writes: 0 };
      // Show the result before the stream reads it back.
      if (state.metaReplica === meta)
        state.catalogs.set('meta', projectRows(meta.flock.scan(), 'meta'));
      if (workspace && state.workspaceReplica === workspace)
        state.pinSections = {
          sections: pinSectionRows(
            workspace.flock.scan({ prefix: ['pinSection'] }),
          ),
          loaded: true,
        };
      ctx.publish();
      return { writes: count };
    },
  );
  channel.handle('snoozePresets', () => snoozePresets(serverClock.now()));
}
