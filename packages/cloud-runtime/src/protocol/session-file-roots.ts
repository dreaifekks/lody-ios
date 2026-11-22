import type { ProjectRun } from '../models/catalog.ts';

/**
 * Web `session-file-root-mounts.ts`: Project group members used in place
 * (`additional` / `link`) are separate file roots on the machine. Conversation
 * links name their files under the member's directory, exactly where a link
 * would have put it, so a request under that prefix is split back into
 * `rootId` + relative path. Nothing here grants access: the machine resolves
 * every root from its own registry and authorizes the real path.
 */
export type SessionFileRootMount = { rootId: string; mountPath: string };

// Synced member file keys (`\0lody-root:member:<id>/<path>`), never a filesystem path.
const MEMBER_FILE_KEY_PREFIX = '\0lody-root:';
const MEMBER_ID = /^[a-zA-Z0-9][a-zA-Z0-9_-]*$/;

export function sessionFileRootMounts(
  run: ProjectRun | undefined,
): SessionFileRootMount[] {
  if (!run) return [];
  return run.members.flatMap((member) =>
    (member.access === 'additional' || member.access === 'link') &&
    MEMBER_ID.test(member.id) &&
    member.path
      ? [{ rootId: `member:${member.id}`, mountPath: member.path }]
      : [],
  );
}

/** Web `toSessionFileRequestPath`: paths outside every mount stay main-root paths, unchanged. */
export function toSessionFileRequestPath(
  path: string,
  mounts: readonly SessionFileRootMount[],
): { path: string; rootId?: string } {
  if (mounts.length === 0) return { path };
  const normalized = path.replace(/\\/g, '/').replace(/^\.\//, '');
  for (const mount of mounts) {
    const prefix = `${mount.mountPath}/`;
    if (normalized.startsWith(prefix) && normalized.length > prefix.length)
      return { rootId: mount.rootId, path: normalized.slice(prefix.length) };
  }
  return { path };
}

/** Web `toSessionFileDisplayPath`: a member key the machine reports is shown under its mount. */
export function toSessionFileDisplayPath(
  key: string,
  mounts: readonly SessionFileRootMount[],
  rootId?: string,
): string {
  if (key.startsWith(MEMBER_FILE_KEY_PREFIX)) {
    const suffix = key.slice(MEMBER_FILE_KEY_PREFIX.length);
    const slash = suffix.indexOf('/');
    if (slash < 0) return key;
    return display(suffix.slice(0, slash), suffix.slice(slash + 1), mounts);
  }
  // A member-root request answers with a path relative to that root.
  if (rootId && !key.startsWith('/') && !/^[A-Za-z]:[\\/]/.test(key))
    return display(rootId, key, mounts);
  return key;
}

function display(
  rootId: string,
  relativePath: string,
  mounts: readonly SessionFileRootMount[],
): string {
  const mount = mounts.find((candidate) => candidate.rootId === rootId);
  const prefix = mount?.mountPath ?? rootId.replace(/^member:/, 'member-');
  return `${prefix}/${relativePath}`;
}
