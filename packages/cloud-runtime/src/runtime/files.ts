import { projectControl } from './local-projects';
import { sealedRpc } from './machine-rpc';
import {
  toSessionFileDisplayPath,
  toSessionFileRequestPath,
  type SessionFileRootMount,
} from '../protocol/session-file-roots.ts';

type Grant = () => Promise<{ token: string; gatewayBaseUrl: string }>;
export type MachineContext = {
  workspaceId: string;
  machineId: string;
  getGrant: Grant;
  signal: AbortSignal;
};
export type FileContext = MachineContext & {
  ownerSessionId: string;
  /** Project group members used in place; empty for ordinary sessions. */
  mounts?: readonly SessionFileRootMount[];
};

/** Split a display path into what a file RPC takes (web `toSessionFileRequestPath`). */
function at(ctx: FileContext, path: string) {
  return toSessionFileRequestPath(path, ctx.mounts ?? []);
}
function shown(ctx: FileContext, path: string, rootId?: string) {
  return toSessionFileDisplayPath(path, ctx.mounts ?? [], rootId);
}

type EncodedText =
  | { encoding: 'plain' | 'utf8-plain'; text: string; rawBytes: number }
  | {
      encoding: 'gzip-base64' | 'utf8-gzip-base64';
      data: string;
      rawBytes: number;
    }
  | { encoding: 'base64'; data: string; rawBytes: number };

const bytesOf = (base64: string) =>
  Uint8Array.from(atob(base64), (c) => c.charCodeAt(0));

async function gunzip(base64: string) {
  const stream = new Blob([bytesOf(base64)])
    .stream()
    .pipeThrough(new DecompressionStream('gzip'));
  return new Response(stream).text();
}

export async function decodeText(payload: EncodedText): Promise<string> {
  switch (payload.encoding) {
    case 'plain':
    case 'utf8-plain':
      return payload.text;
    case 'gzip-base64':
    case 'utf8-gzip-base64':
      return gunzip(payload.data);
    case 'base64':
      return new TextDecoder().decode(bytesOf(payload.data));
  }
}

type Snapshot =
  | { kind: 'text'; text: EncodedText }
  | { kind: 'missing' | 'binary' | 'too_large' };
export type DiffSide = { kind: Snapshot['kind']; text?: string };

async function side(snapshot: Snapshot): Promise<DiffSide> {
  if (snapshot.kind === 'text')
    return { kind: 'text', text: await decodeText(snapshot.text) };
  if (snapshot.kind === 'missing') return { kind: 'missing', text: '' };
  return { kind: snapshot.kind };
}

type DiffResponse =
  | {
      status: 'ok';
      path: string;
      oldSnapshot: Snapshot;
      newSnapshot: Snapshot;
      add?: number;
      del?: number;
    }
  | { status: 'unavailable'; path: string; reason: string; message?: string };

export type DiffResult =
  | {
      status: 'ok';
      base: 'turn' | 'current';
      path: string;
      old: DiffSide;
      new: DiffSide;
      add?: number;
      del?: number;
    }
  | {
      status: 'unavailable';
      base: 'turn' | 'current';
      path: string;
      reason: string;
      message?: string;
    };

async function toDiffResult(
  response: DiffResponse,
  base: 'turn' | 'current',
  displayPath: (path: string) => string,
): Promise<DiffResult> {
  if (response.status !== 'ok')
    return {
      status: 'unavailable',
      base,
      path: displayPath(response.path),
      reason: response.reason,
      message: response.message,
    };
  return {
    status: 'ok',
    base,
    path: displayPath(response.path),
    old: await side(response.oldSnapshot),
    new: await side(response.newSnapshot),
    add: response.add,
    del: response.del,
  };
}

export type WorkspaceChanges =
  | {
      status: 'ok';
      base: string;
      files: {
        path: string;
        add?: number;
        del?: number;
        kind?: 'added' | 'deleted' | 'modified';
      }[];
    }
  | { status: 'unavailable'; reason: string; message?: string };

export async function workspaceChanges(
  ctx: FileContext,
  args: { sessionId: string },
): Promise<WorkspaceChanges> {
  const response = (await sealedRpc(
    ctx.workspaceId,
    ctx.machineId,
    'code-collab/open-all-changes-diff',
    ctx.ownerSessionId,
    { sessionId: args.sessionId },
    ctx.getGrant,
    ctx.signal,
  )) as
    | {
        status: 'ok';
        base: string;
        entries: (
          | DiffResponse
          | { status: 'deferred'; path: string; add?: number; del?: number }
        )[];
      }
    | { status: 'unavailable'; reason: string; message?: string };
  if (response.status !== 'ok') return response;
  return {
    status: 'ok',
    base: response.base,
    files: response.entries
      .filter((entry) => entry.status !== 'unavailable')
      .map((entry) => {
        let kind: 'added' | 'deleted' | 'modified' | undefined;
        if (entry.status === 'ok') {
          kind = 'modified';
          if (entry.oldSnapshot.kind === 'missing') kind = 'added';
          else if (entry.newSnapshot.kind === 'missing') kind = 'deleted';
        }
        return { path: entry.path, add: entry.add, del: entry.del, kind };
      })
      .sort((a, b) => a.path.localeCompare(b.path)),
  };
}

export async function fileDiff(
  ctx: FileContext,
  args: { sessionId: string; path: string },
): Promise<DiffResult> {
  const target = at(ctx, args.path);
  const response = (await sealedRpc(
    ctx.workspaceId,
    ctx.machineId,
    'code-collab/open-current-diff',
    ctx.ownerSessionId,
    { sessionId: args.sessionId, ...target },
    ctx.getGrant,
    ctx.signal,
  )) as DiffResponse;
  return toDiffResult(response, 'current', (path) =>
    shown(ctx, path, target.rootId),
  );
}

export async function turnDiff(
  ctx: FileContext,
  args: { sessionId: string; entryId: string; path: string },
): Promise<DiffResult> {
  const target = at(ctx, args.path);
  const response = (await sealedRpc(
    ctx.workspaceId,
    ctx.machineId,
    'code-collab/open-turn-diff',
    ctx.ownerSessionId,
    { sessionId: args.sessionId, turnId: args.entryId, ...target },
    ctx.getGrant,
    ctx.signal,
  )) as DiffResponse;
  return toDiffResult(response, 'turn', (path) =>
    shown(ctx, path, target.rootId),
  );
}

export type DirectoryEntry = { name: string; type: 'file' | 'directory' };

export async function listDir(
  ctx: MachineContext,
  args: { localProjectId: string; relativePath: string; userId: string },
): Promise<{ entries: DirectoryEntry[]; truncated: boolean }> {
  const result = await projectControl(
    ctx.workspaceId,
    ctx.machineId,
    {
      type: 'local-project/list-dir',
      localProjectId: args.localProjectId,
      relativePath: args.relativePath,
      requestedByUserId: args.userId,
      limit: 2000,
    },
    ctx.getGrant,
    ctx.signal,
  );
  if (!Array.isArray(result.entries)) throw new Error('invalid_directory');
  return {
    entries: sortEntries(result.entries as DirectoryEntry[]),
    truncated: !!result.truncated,
  };
}

type SessionListResponse =
  | {
      status: 'ok';
      path: string;
      entries: DirectoryEntry[];
      truncated: boolean;
    }
  | { status: 'error'; code: string; message?: string };

/**
 * One folder of the session's own workspace (its worktree when it has one) through
 * the machine's `file/list-dir` (capability `sessionDirectoryListing`): the same root
 * and owner envelope `readFile` uses, so a listed file always opens. Null when the
 * machine answers `unsupported_protocol` (an encrypted workspace's reader).
 */
export async function listSessionDir(
  ctx: FileContext,
  args: { sessionId: string; relativePath: string },
): Promise<{ entries: DirectoryEntry[]; truncated: boolean } | null> {
  const response = (await sealedRpc(
    ctx.workspaceId,
    ctx.machineId,
    'file/list-dir',
    ctx.ownerSessionId,
    { v: 3, sessionId: args.sessionId, path: args.relativePath, limit: 2000 },
    ctx.getGrant,
    ctx.signal,
  )) as SessionListResponse;
  if (response.status !== 'ok') {
    if (response.code === 'unsupported_protocol') return null;
    throw new Error(response.code || 'invalid_directory');
  }
  if (!Array.isArray(response.entries)) throw new Error('invalid_directory');
  return {
    entries: sortEntries(response.entries),
    truncated: !!response.truncated,
  };
}

function sortEntries(entries: DirectoryEntry[]): DirectoryEntry[] {
  return entries
    .filter(
      (entry) =>
        entry &&
        typeof entry.name === 'string' &&
        (entry.type === 'file' || entry.type === 'directory'),
    )
    .map(({ name, type }) => ({ name, type }))
    .sort((a, b) => {
      if (a.type !== b.type) return a.type === 'directory' ? -1 : 1;
      return a.name.localeCompare(b.name, undefined, { sensitivity: 'base' });
    });
}

export const READ_FILE_MAX_BYTES = 2 * 1024 * 1024;

type PreviewResponse =
  | {
      status: 'ok';
      path: string;
      kind: 'text' | 'binary';
      content: EncodedText;
      mimeType?: string;
      sizeBytes: number;
    }
  | { status: 'error'; path: string; code: string; message?: string };

export type FileContent =
  | { status: 'ok'; path: string; kind: 'text'; text: string; bytes: number }
  | {
      status: 'ok';
      path: string;
      kind: 'binary';
      base64: string;
      mimeType?: string;
      bytes: number;
    }
  | { status: 'error'; path: string; code: string; message?: string };

export async function readFile(
  ctx: FileContext,
  args: { sessionId: string; path: string },
): Promise<FileContent> {
  // A link under a Project group member's directory reads that member's root,
  // as on web; the main root alone would report it outside the workspace.
  const target = at(ctx, args.path);
  const response = (await sealedRpc(
    ctx.workspaceId,
    ctx.machineId,
    'file/preview',
    ctx.ownerSessionId,
    {
      v: 3,
      sessionId: args.sessionId,
      ...target,
      maxBytes: READ_FILE_MAX_BYTES,
    },
    ctx.getGrant,
    ctx.signal,
  )) as PreviewResponse;
  const path = (reported: string | undefined) =>
    reported === undefined ? args.path : shown(ctx, reported, target.rootId);
  if (response.status !== 'ok')
    return {
      status: 'error',
      path: path(response.path),
      code: response.code,
      message: response.message,
    };
  if (response.kind === 'binary' && response.content.encoding === 'base64')
    return {
      status: 'ok',
      path: path(response.path),
      kind: 'binary',
      base64: response.content.data,
      mimeType: response.mimeType,
      bytes: response.sizeBytes,
    };
  return {
    status: 'ok',
    path: path(response.path),
    kind: 'text',
    text: await decodeText(response.content),
    bytes: response.sizeBytes,
  };
}

export const FILE_DOWNLOAD_MAX_BYTES = 100 * 1024 * 1024;
export const FILE_DOWNLOAD_CHUNK_BYTES = 512 * 1024;
export const FILE_DOWNLOAD_CHUNK_MAX_BASE64 =
  4 * Math.ceil(FILE_DOWNLOAD_CHUNK_BYTES / 3);
const FILE_DOWNLOAD_REVISION_HEX = /^[0-9a-f]{64}$/u;

export type LocalAttachmentDownloadRef = {
  type: 'local_attachment';
  machineId: string;
  path: string;
  kind: 'file' | 'image';
  fileName: string;
  mimeType: string;
  sizeBytes: number;
};

export type DownloadFileChunkResult =
  | {
      status: 'ok';
      path: string;
      revision: string;
      sizeBytes: number;
      offset: number;
      data: string;
    }
  | { status: 'error'; code: string };

/**
 * Reads one bounded chunk (up to 512 KiB) of a file or local attachment through
 * Machine RPC `file/download-chunk`. Callers loop from `offset: 0` and pass the
 * returned `revision` on every subsequent chunk (`offset > 0`).
 */
export async function downloadFileChunk(
  ctx: FileContext,
  args: {
    sessionId: string;
    path: string;
    attachment?: LocalAttachmentDownloadRef;
    offset: number;
    revision?: string;
  },
): Promise<DownloadFileChunkResult> {
  if (
    !Number.isInteger(args.offset) ||
    args.offset < 0 ||
    args.offset > FILE_DOWNLOAD_MAX_BYTES ||
    (args.offset > 0 && !args.revision) ||
    (args.revision !== undefined &&
      !FILE_DOWNLOAD_REVISION_HEX.test(args.revision))
  ) {
    return { status: 'error', code: 'invalid_path' };
  }
  const attachment = args.attachment
    ? {
        type: 'local_attachment' as const,
        machineId: args.attachment.machineId,
        path: args.attachment.path,
        kind: args.attachment.kind,
        fileName: args.attachment.fileName,
        mimeType: args.attachment.mimeType,
        sizeBytes: args.attachment.sizeBytes,
      }
    : undefined;
  const payload = {
    sessionId: args.sessionId,
    path: args.path,
    ...(attachment ? { attachment } : {}),
    offset: args.offset,
    ...(args.revision !== undefined ? { revision: args.revision } : {}),
  };
  const response = (await sealedRpc(
    ctx.workspaceId,
    ctx.machineId,
    'file/download-chunk',
    ctx.ownerSessionId,
    payload,
    ctx.getGrant,
    ctx.signal,
  )) as DownloadFileChunkResult;
  if (!response || typeof response !== 'object') {
    return { status: 'error', code: 'transient_io' };
  }
  if (response.status !== 'ok') {
    const code =
      typeof response.code === 'string' && response.code
        ? response.code
        : 'transient_io';
    return { status: 'error', code };
  }
  if (
    typeof response.path !== 'string' ||
    typeof response.revision !== 'string' ||
    !FILE_DOWNLOAD_REVISION_HEX.test(response.revision) ||
    !Number.isInteger(response.sizeBytes) ||
    response.sizeBytes < 0 ||
    response.sizeBytes > FILE_DOWNLOAD_MAX_BYTES ||
    !Number.isInteger(response.offset) ||
    response.offset !== args.offset ||
    typeof response.data !== 'string' ||
    response.data.length > FILE_DOWNLOAD_CHUNK_MAX_BASE64
  ) {
    return { status: 'error', code: 'decode_error' };
  }
  return {
    status: 'ok',
    path: response.path,
    revision: response.revision,
    sizeBytes: response.sizeBytes,
    offset: response.offset,
    data: response.data,
  };
}
