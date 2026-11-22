import type { Flock } from '@loro-dev/flock-wasm/base64';
import type { StreamsClient } from '@loro-dev/streams-client';
import type { Catalog, Session } from '../models/catalog.ts';
import type {
  CatalogStatusView,
  PinSection,
  StatusViewCommand as HostStatusViewCommand,
} from '../contract/status-view.ts';
import {
  comparePinSections,
  normalizePinSection,
} from '../protocol/lody-shared/pinned-sections.ts';
import { encodeFrame } from '../frames.ts';
import {
  buildSnoozePresets,
  buildStatusViewLayout,
  planStatusViewCommand,
  statusViewPinnedIds,
  type StatusViewCommand,
  type StatusViewLayoutInput,
  type StatusViewSession,
  type StatusViewState,
  type StatusViewWrite,
} from '../protocol/lody-shared/status-view/index.ts';

/** Watcher key of the live `${workspace}:wf:workspace` read; never a machine id. */
export const WORKSPACE_STREAM = '@wf:workspace';

type Row = { key: unknown[]; value?: unknown };
type FlockValue = NonNullable<Parameters<Flock['set']>[1]>;

/** Valid `['pinSection', id]` rows in render order (Lody `parseWorkspaceFlockRow`). */
export function pinSectionRows(rows: readonly Row[]): PinSection[] {
  const sections: PinSection[] = [];
  for (const row of rows) {
    if (row.key.length !== 2 || row.key[0] !== 'pinSection') continue;
    const section = normalizePinSection(row.value);
    if (section && section.id === row.key[1]) sections.push(section);
  }
  return sections.sort(comparePinSections);
}

/**
 * Port of the web session-management guard (`isSessionEditableToUser`) with
 * what the runtime knows. The machine's owner may always manage. Another member
 * may manage once the machine stream was readable (a catalog exists for it),
 * except for a local-project conversation, a Project group with a local member
 * included: whether that project is shared with the team is server access
 * state the runtime cannot read, and a machine Flock lists private projects
 * too. Preferences (pin) additionally admit the session's own author. Read
 * grants on another member's machine are not discoverable here and are refused.
 */
export function sessionPermissions(
  session: Pick<Session, 'machineId' | 'projectId' | 'userId' | 'projectRun'>,
  meta: Pick<Catalog, 'machineOwners'>,
  machineCatalogs: ReadonlyMap<string, unknown>,
  userId: string,
): { canManage: boolean; canPrefer: boolean } {
  const machineId = session.machineId;
  const owned =
    !!userId && !!machineId && meta.machineOwners?.[machineId] === userId;
  const local =
    session.projectId.startsWith(`${machineId}:local:`) ||
    !!session.projectRun?.members.some((member) => member.kind === 'local');
  const canManage =
    owned || (!!machineId && machineCatalogs.has(machineId) && !local);
  const canPrefer = canManage || (!!userId && session.userId === userId);
  return { canManage, canPrefer };
}

/**
 * The listed conversation a session id stands for: a Tab or side chat
 * (`parentSessionId`) resolves to the conversation it belongs to.
 */
export function conversationOf(
  sessions: readonly Pick<Session, 'id' | 'parentSessionId'>[],
  id: string,
) {
  const indexed = new Map(sessions.map((s) => [s.id, s]));
  let current = id;
  const seen = new Set([id]);
  for (;;) {
    const parent = indexed.get(current)?.parentSessionId;
    if (!parent || seen.has(parent)) return current;
    seen.add(parent);
    current = parent;
  }
}

/** Synced durable status, as the native lists read it (`SessionRows.swift` `SessionState`). */
const LIVE = new Set([
  'running',
  'initializing',
  'processing',
  'in_progress',
  'queued',
]);
const ATTENTION = new Set(['requestPermission', 'waiting']);
const isLive = (session: Session) => LIVE.has(session.status);
const isWaiting = (session: Session) =>
  !isLive(session) &&
  (ATTENTION.has(session.status) || session.awaitingUserSince !== undefined);
const isTab = (session: Session) => !!session.parentSessionId;
const createdMs = (session: Session) => {
  const value = Date.parse(session.createdAt);
  return Number.isFinite(value) ? value : null;
};

export type StatusViewSources = {
  /** The published catalog (sessions, machine owners). */
  catalog: Pick<Catalog, 'sessions' | 'machineOwners'>;
  /** Machine catalogs whose stream was readable. */
  machineCatalogs: ReadonlyMap<string, Pick<Catalog, 'projects'>>;
  userId: string;
  readOnly: boolean;
  sections: PinSection[];
  sectionsLoaded: boolean;
  nowMs: number;
};

export type StatusViewScope = 'mine' | 'team';

/**
 * The layout input for one scope, built the way the native lists group today
 * (Sessions/AGENTS.md): Tabs and side chats (`parentSessionId`) never list and
 * lend their running / waiting state to their conversation; a row nests under
 * `openedBySessionId`, then `openedByRootSessionId`, resolved through Tabs to a
 * listed conversation. As on desktop, a conversation's activity is the latest of
 * its own and its non-archived Tabs' and side chats' (`getEffectiveLatestMessageAt`),
 * while unread stays its own; My tasks lists each conversation the user owns
 * (`isSessionInMyScope`) and counts, by pinned root section, the Pinned-area
 * rows it hid. Archived and scope-hidden rows stay reachable as `related`.
 */
export function statusViewState(
  sources: StatusViewSources,
  scope: StatusViewScope,
): StatusViewState {
  const { catalog, machineCatalogs, userId, readOnly, nowMs } = sources;
  const indexed = new Map(catalog.sessions.map((s) => [s.id, s]));
  const conversation = (id: string) => {
    let current = id;
    const seen = new Set([id]);
    for (;;) {
      const parent = indexed.get(current)?.parentSessionId;
      if (!parent || seen.has(parent)) return current;
      seen.add(parent);
      current = parent;
    }
  };
  const listed = new Map(
    catalog.sessions.filter((s) => !isTab(s)).map((s) => [s.id, s]),
  );
  const openerOf = (session: Session) => {
    for (const candidate of [
      session.openedBySessionId,
      session.openedByRootSessionId,
    ]) {
      if (!candidate) continue;
      const id = conversation(candidate);
      if (id !== session.id && listed.get(id)?.archived === session.archived)
        return id;
    }
    return null;
  };
  // Internal Tabs on the same machine contribute their status (not side chats).
  const tabs = new Map<string, Session[]>();
  const childActivity = new Map<string, number>();
  for (const session of catalog.sessions) {
    if (!isTab(session) || session.archived) continue;
    const at = session.lastMessageAt ?? createdMs(session) ?? 0;
    const parent = session.parentSessionId!;
    childActivity.set(parent, Math.max(childActivity.get(parent) ?? 0, at));
    if (session.childSessionPlacement === 'side-panel') continue;
    const owner = listed.get(conversation(session.id));
    if (!owner || owner.machineId !== session.machineId) continue;
    const list = tabs.get(owner.id) ?? [];
    list.push(session);
    tabs.set(owner.id, list);
  }
  const toInput = (session: Session): StatusViewSession => {
    const family = [session, ...(tabs.get(session.id) ?? [])];
    const working = family.some(isLive);
    const permissions = readOnly
      ? { canManage: false, canPrefer: false }
      : sessionPermissions(session, catalog, machineCatalogs, userId);
    return {
      id: session.id,
      title: session.title,
      lastMessageAt: session.lastMessageAt ?? null,
      activityAt: Math.max(
        session.lastMessageAt ?? createdMs(session) ?? 0,
        childActivity.get(session.id) ?? 0,
      ),
      lastReadAt: session.lastReadAt ?? null,
      isPinned: session.pinned,
      pinSectionId: session.pinSectionId ?? null,
      orderKey: session.orderKey ?? null,
      snoozedUntil: session.snoozedUntil ?? null,
      settledAt: session.settledAt ?? null,
      focusRestoredAt: session.focusRestoredAt ?? null,
      openedById: openerOf(session),
      isWorking: working,
      isWaitingPermission: !working && family.some(isWaiting),
      ...permissions,
    };
  };
  const all = [...listed.values()].map(toInput);
  const active = all.filter((s) => !listed.get(s.id)!.archived);
  let visible = active;
  const scopeHiddenCounts: Record<string, number> = {};
  if (scope === 'mine') {
    visible = active.filter(
      (s) => !!userId && listed.get(s.id)!.userId === userId,
    );
    // Desktop's rule: every row the unscoped Pinned area holds (pinned roots and
    // the rows they carry) that this scope does not, under its pinned root's section.
    const activeById = new Map(active.map((s) => [s.id, s]));
    const shownPinned = statusViewPinnedIds(visible);
    for (const id of statusViewPinnedIds(active)) {
      if (shownPinned.has(id)) continue;
      let root = activeById.get(id);
      const seen = new Set<string>();
      while (root && !root.isPinned) {
        const opener = root.openedById;
        if (!opener || seen.has(opener)) {
          root = undefined;
          break;
        }
        seen.add(opener);
        root = activeById.get(opener);
      }
      const key = root?.pinSectionId ?? '';
      scopeHiddenCounts[key] = (scopeHiddenCounts[key] ?? 0) + 1;
    }
  }
  const shown = new Set(visible.map((s) => s.id));
  return {
    sessions: visible,
    related: all.filter((s) => !shown.has(s.id)),
    sections: sources.sections,
    sectionsLoaded: sources.sectionsLoaded,
    // Section management waits for the rows it would order against.
    canManageSections: !readOnly && sources.sectionsLoaded,
    scopeHiddenCounts,
    nowMs,
  };
}

/** Catalog `statusView` for both scopes at one instant. */
export function catalogStatusView(
  sources: StatusViewSources,
): CatalogStatusView {
  const layout = (scope: StatusViewScope) => {
    const { related: _related, ...input } = statusViewState(sources, scope);
    return buildStatusViewLayout(input satisfies StatusViewLayoutInput);
  };
  return {
    mine: layout('mine'),
    team: layout('team'),
    nowMs: sources.nowMs,
    sectionsLoaded: sources.sectionsLoaded,
  };
}

/** Earliest future `nextChangeAt` of a catalog Status view. */
export const statusViewNextChangeAt = (view: CatalogStatusView) => {
  const times = [view.mine.nextChangeAt, view.team.nextChangeAt].filter(
    (at): at is number => at !== null,
  );
  return times.length ? Math.min(...times) : null;
};

export const randomByte = () => crypto.getRandomValues(new Uint8Array(1))[0]!;

/** Plans a host or runtime command against the current replica state. */
export function planCommand(
  sources: StatusViewSources,
  command: StatusViewCommand | HostStatusViewCommand,
  scope: StatusViewScope = 'team',
  byte: () => number = randomByte,
): StatusViewWrite[] {
  return planStatusViewCommand(statusViewState(sources, scope), command, {
    nowMs: sources.nowMs,
    randomByte: byte,
  });
}

export function snoozePresets(nowMs: number) {
  return {
    nowMs,
    presets: buildSnoozePresets(nowMs).map(({ id, timestamp, countdown }) => ({
      id,
      until: timestamp,
      countdown,
    })),
  };
}

type Replica = { flock: Flock; client: StreamsClient };

/** Stages one planned session patch on the meta Flock; `null` deletes a field. */
export function setSessionPatch(
  flock: Flock,
  write: Extract<StatusViewWrite, { type: 'session' }>,
) {
  for (const [field, value] of Object.entries(write.patch)) {
    if (value === undefined) continue;
    const key = ['m', `session-${write.sessionId}`, field];
    if (value === null) flock.delete(key);
    else flock.set(key, value);
  }
}

async function appendSince(replica: Replica, version: unknown) {
  const update = replica.flock.exportJson(
    version as Parameters<Flock['exportJson']>[0],
  );
  const result = await replica.client.append({
    part: {
      contentType: 'application/octet-stream',
      body: encodeFrame(new TextEncoder().encode(JSON.stringify(update))),
    },
  });
  if (!result.ok) throw new Error(result.result.code);
}

/** A replica that has a local commit the server never accepted. */
export type StatusViewDirtyReplica = 'meta' | 'workspace';

/**
 * Applies planned writes: session patches to the meta Flock (`null` deletes a
 * field, as loro-repo does), sections to the workspace Flock, each committed and
 * appended once. A workspace stream that does not exist yet (`missing`) is
 * created first, as Agent Role saves do. When an append fails after its local
 * commit, `dirty` names that replica so the caller rebuilds it from the server;
 * the commit is never replayed.
 */
export async function applyStatusViewWrites(
  writes: readonly StatusViewWrite[],
  meta: Replica,
  workspace: (Replica & { missing?: boolean }) | undefined,
  dirty: (replica: StatusViewDirtyReplica) => void = () => {},
) {
  const sessionWrites = writes.filter((w) => w.type === 'session');
  const sectionWrites = writes.filter((w) => w.type !== 'session');
  if (sectionWrites.length && !workspace)
    throw new Error('workspace_not_ready');
  if (workspace && sectionWrites.length) {
    if (workspace.missing) {
      const created = await workspace.client.create({
        contentType: 'application/octet-stream',
      });
      if (!created.ok) throw new Error(created.result.code);
      workspace.missing = false;
    }
    const version = workspace.flock.version();
    for (const write of sectionWrites) {
      if (write.type === 'deleteSection')
        workspace.flock.delete(['pinSection', write.sectionId]);
      else
        workspace.flock.set(
          ['pinSection', write.section.id],
          write.section as FlockValue,
        );
    }
    workspace.flock.commit();
    try {
      await appendSince(workspace, version);
    } catch (error) {
      dirty('workspace');
      throw error;
    }
  }
  if (sessionWrites.length) {
    const version = meta.flock.version();
    for (const write of sessionWrites) setSessionPatch(meta.flock, write);
    meta.flock.commit();
    try {
      await appendSince(meta, version);
    } catch (error) {
      dirty('meta');
      throw error;
    }
  }
  return writes.length;
}
