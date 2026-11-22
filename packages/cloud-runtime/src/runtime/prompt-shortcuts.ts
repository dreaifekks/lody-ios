import { Flock } from '@loro-dev/flock-wasm/base64';
import { LoroDoc } from 'loro-crdt/base64';
import { decompress } from 'fzstd';
import { clientFor } from './session';
import { forgetSettings, openSettings } from './settings';
import { decodeFrames, encodeFrame } from '../frames';
import {
  getShortcutBodyStreamId,
  getShortcutIndexStreamId,
  getWorkspaceShortcutBodyStreamId,
  getWorkspaceShortcutIndexStreamId,
} from '../protocol/prompt-shortcuts/access.ts';
import {
  PromptShortcutCatalog,
  parseShortcutIndex,
  projectShortcutIndex,
  type PromptShortcutIndexEntry,
} from '../protocol/prompt-shortcuts/catalog.ts';
import { PromptShortcutDocument } from '../protocol/prompt-shortcuts/document.ts';
import { parsePromptShortcut } from '../protocol/prompt-shortcuts/compiler.ts';
import { PromptShortcutError } from '../protocol/prompt-shortcuts/model.ts';
import {
  simpleShortcut,
  type PromptShortcut,
  type ShortcutRequest,
} from '../models/prompt-shortcuts.ts';
import { z } from 'zod';

export type Cloud = (
  operation: string,
  args: Record<string, unknown>,
) => Promise<unknown>;
export type WorkspaceGrant = () => Promise<{
  token: string;
  gatewayBaseUrl: string;
}>;

const directorySchema = z
  .array(
    z.object({
      shortcutId: z.string().min(1).max(200),
      bodyDocId: z.string().min(1).max(200),
      ownerUserId: z.string().min(1).max(200),
      visibility: z.enum(['private', 'workspace']),
      revision: z.string().nullable(),
      deleted: z.boolean().optional(),
    }),
  )
  .max(10000);

type Row = z.infer<typeof directorySchema>[number];
type Grant = { token: string; gatewayBaseUrl: string; expiresIn: number };

function mapShortcutError(error: unknown, afterWrite = false): never {
  if (error instanceof PromptShortcutError) {
    if (error.code === 'size_limit') throw new Error('shortcut_limit');
    if (error.code === 'conflict') {
      if (!afterWrite && error.message.includes('slug'))
        throw new Error('invalid_shortcut');
      throw new Error('shortcut_changed');
    }
    throw new Error('invalid_shortcut');
  }
  throw error;
}

/**
 * Per-workspace/account shortcut cache.
 *
 * Primary reads and all writes use `{workspaceId}:shortcut-index` and
 * `{workspaceId}:shortcut:{bodyDocId}` under the ordinary workspace grant.
 * During Phase 1 rollout, unmigrated legacy shortcuts not yet present or tombstoned
 * in `{workspaceId}:shortcut-index` are dual-read from `shortcut-index:*` / `shortcut-body:*`.
 */
type ShortcutScope = {
  key: string;
  directory?: { rows: Row[]; at: number };
  directoryPending?: Promise<Row[]>;
  grants: Map<string, { value: Promise<Grant>; until: number }>;
  bodies: Map<string, { entry: string; value: PromptShortcut }>;
  reads: Map<string, Promise<PromptShortcut>>;
  prefetch: PromptShortcutIndexEntry[];
  prefetching: boolean;
};
const DIRECTORY_TTL = 30_000;
const BODY_LIMIT = 500;
const PREFETCH_LIMIT = 100;
let currentScope: ShortcutScope | undefined;

function scopeFor(workspaceId: string, userId: string) {
  const key = `${workspaceId}:${userId}`;
  if (currentScope?.key !== key)
    currentScope = {
      key,
      grants: new Map(),
      bodies: new Map(),
      reads: new Map(),
      prefetch: [],
      prefetching: false,
    };
  return currentScope;
}

/** Drops every remembered shortcut read (a new account or workspace). */
export function forgetShortcuts() {
  currentScope = undefined;
  listings.clear();
}

export function shortcutAccess(
  workspaceId: string,
  userId: string,
  workspaceGrant: WorkspaceGrant,
  cloud: Cloud | undefined,
  signal: AbortSignal,
) {
  const scope = scopeFor(workspaceId, userId);
  const live = () => currentScope === scope;

  const workspaceIndex = async (fresh = false) => {
    const stream = getWorkspaceShortcutIndexStreamId(workspaceId);
    try {
      const { flock, client } = await openSettings(
        stream,
        workspaceGrant,
        signal,
        { cached: !fresh },
      );
      const catalog = new PromptShortcutCatalog(flock);
      const entries = catalog
        .list()
        .filter((entry) => entry.workspaceId === workspaceId);
      const deletedIds = catalog.deletedIds();
      return {
        exists: true as const,
        flock,
        client,
        entries,
        deletedIds,
      };
    } catch (error) {
      if (error instanceof Error && error.message === 'not_found') {
        return {
          exists: false as const,
          flock: undefined,
          client: undefined,
          entries: [] as PromptShortcutIndexEntry[],
          deletedIds: new Set<string>(),
        };
      }
      throw error;
    }
  };

  const openWorkspaceIndexForWrite = async () => {
    const stream = getWorkspaceShortcutIndexStreamId(workspaceId);
    const client = await clientFor(stream, workspaceGrant);
    const created = await client.create({
      contentType: 'application/octet-stream',
    });
    if (!created.ok) throw new Error('shortcut_write_unknown');
    return openSettings(stream, workspaceGrant, signal, { cached: false });
  };

  /** Legacy Phase 1 directory rows this account may read; `fresh` skips the recent copy. */
  const directory = async (fresh = false): Promise<Row[]> => {
    if (!cloud) return [];
    const cached = scope.directory;
    if (!fresh && cached && Date.now() - cached.at < DIRECTORY_TTL)
      return cached.rows;
    if (!fresh && scope.directoryPending) return scope.directoryPending;
    const pending = cloud('listAccessibleDocuments', {})
      .then((value) => {
        const rows = directorySchema
          .parse(value)
          .filter(
            (row) =>
              !row.deleted &&
              (row.visibility === 'workspace' || row.ownerUserId === userId),
          );
        if (live()) scope.directory = { rows, at: Date.now() };
        return rows;
      })
      .finally(() => {
        if (scope.directoryPending === pending)
          scope.directoryPending = undefined;
      });
    scope.directoryPending = pending;
    const rows = await pending;
    signal.throwIfAborted();
    return rows;
  };

  const grant =
    (streamId: string, target: object, write: boolean) => async () => {
      const key = `${write}:${streamId}`;
      const cached = scope.grants.get(key);
      if (cached && cached.until > Date.now()) return cached.value;
      const value = fetchGrant(streamId, target, write);
      const slot = { value, until: Date.now() + 30000 };
      scope.grants.set(key, slot);
      try {
        const resolved = await value;
        slot.until =
          Date.now() + Math.max(0, resolved.expiresIn * 1000 - 30000);
        return resolved;
      } catch (error) {
        if (scope.grants.get(key) === slot) scope.grants.delete(key);
        throw error;
      }
    };

  const fetchGrant = async (
    streamId: string,
    target: object,
    write: boolean,
  ): Promise<Grant> => {
    if (!cloud) throw new Error('shortcut_unavailable');
    return z
      .object({
        token: z.string().min(1),
        expiresIn: z.number().positive(),
        gatewayBaseUrl: z
          .string()
          .url()
          .refine((url) => url.startsWith('https://')),
        streamId: z.literal(streamId),
      })
      .parse(await cloud('getStreamToken', { target, write }));
  };

  const legacyIndex = async (
    ownerUserId: string,
    visibility: 'private' | 'workspace',
  ) => {
    const stream = getShortcutIndexStreamId({
      workspaceId,
      ownerUserId,
      visibility,
    });
    const getGrant = grant(
      stream,
      { kind: 'index', ownerUserId, visibility },
      false,
    );
    return openSettings(stream, getGrant, signal, { cached: true });
  };

  const listed = (entry: PromptShortcutIndexEntry, rows: Row[]) =>
    rows.some(
      (row) =>
        row.shortcutId === entry.id &&
        row.bodyDocId === entry.bodyDocId &&
        row.revision === entry.revision &&
        row.ownerUserId === entry.ownerUserId,
    );

  const legacyDomain = async (row: Row, rows: Row[]) => {
    const domainRows = rows.filter(
      (item) =>
        item.ownerUserId === row.ownerUserId &&
        item.visibility === row.visibility,
    );
    const { flock } = await legacyIndex(row.ownerUserId, row.visibility);
    return new PromptShortcutCatalog(flock)
      .list()
      .filter(
        (entry) =>
          entry.workspaceId === workspaceId &&
          entry.ownerUserId === row.ownerUserId &&
          listed(entry, domainRows),
      );
  };

  const domains = (rows: Row[]) => [
    ...new Map(
      rows.map((row) => [`${row.ownerUserId}:${row.visibility}`, row]),
    ).values(),
  ];

  const byName = (a: PromptShortcutIndexEntry, b: PromptShortcutIndexEntry) =>
    a.name.localeCompare(b.name);

  const mergeEntries = (
    workspaceEntries: PromptShortcutIndexEntry[],
    legacyEntries: PromptShortcutIndexEntry[],
    deletedIds: ReadonlySet<string>,
  ) => {
    const seenIds = new Set<string>([
      ...workspaceEntries.map((entry) => entry.id),
      ...deletedIds,
    ]);
    const seenSlugs = new Set<string>(
      workspaceEntries.map((entry) => entry.slug),
    );
    const merged = [...workspaceEntries];
    const sortedLegacy = [...legacyEntries].sort(
      (a, b) => b.updatedAt - a.updatedAt || a.id.localeCompare(b.id),
    );
    for (const entry of sortedLegacy) {
      if (seenIds.has(entry.id) || seenSlugs.has(entry.slug)) continue;
      seenIds.add(entry.id);
      seenSlugs.add(entry.slug);
      merged.push(entry);
    }
    return merged.sort(byName);
  };

  const resolveSource = async (
    entry: PromptShortcutIndexEntry,
    fresh = false,
  ): Promise<'workspace' | 'legacy'> => {
    if (entry.workspaceId !== workspaceId) throw new Error('shortcut_changed');
    const ws = await workspaceIndex(fresh);
    if (ws.deletedIds.has(entry.id)) throw new Error('shortcut_changed');
    const wsEntry = ws.entries.find((item) => item.id === entry.id);
    if (wsEntry) {
      if (
        wsEntry.bodyDocId !== entry.bodyDocId ||
        wsEntry.revision !== entry.revision ||
        wsEntry.ownerUserId !== entry.ownerUserId
      ) {
        throw new Error('shortcut_changed');
      }
      return 'workspace';
    }
    const rows = await directory(fresh);
    if (!listed(entry, rows)) throw new Error('shortcut_changed');
    return 'legacy';
  };

  const authorized = async (entry: PromptShortcutIndexEntry, fresh = false) => {
    await resolveSource(entry, fresh);
  };

  /** Send-time expansion: workspace index plus any unmigrated legacy rows. */
  const list = async () => {
    const ws = await workspaceIndex();
    const knownIds = new Set<string>([
      ...ws.entries.map((entry) => entry.id),
      ...ws.deletedIds,
    ]);
    const unmigratedRows = (await directory()).filter(
      (row) => !knownIds.has(row.shortcutId),
    );
    const rawLegacy = unmigratedRows.length
      ? (
          await Promise.all(
            domains(unmigratedRows).map((row) =>
              legacyDomain(row, unmigratedRows),
            ),
          )
        ).flat()
      : [];
    if (
      unmigratedRows.some(
        (row) => !rawLegacy.some((entry) => listed(entry, [row])),
      )
    )
      throw new Error('shortcut_index_pending');
    return mergeEntries(ws.entries, rawLegacy, ws.deletedIds);
  };

  /** Mention discovery and Settings list: everything readable now. */
  const listAvailable = async (fresh = false) => {
    let incomplete = false;
    const ws = await workspaceIndex(fresh).catch(() => {
      signal.throwIfAborted();
      incomplete = true;
      return {
        exists: false as const,
        flock: undefined,
        client: undefined,
        entries: [] as PromptShortcutIndexEntry[],
        deletedIds: new Set<string>(),
      };
    });
    const knownIds = new Set<string>([
      ...ws.entries.map((entry) => entry.id),
      ...ws.deletedIds,
    ]);
    const rows = await directory(fresh).catch(() => {
      signal.throwIfAborted();
      incomplete = true;
      return [] as Row[];
    });
    const unmigratedRows = rows.filter((row) => !knownIds.has(row.shortcutId));
    const rawLegacy = unmigratedRows.length
      ? (
          await Promise.all(
            domains(unmigratedRows).map((row) =>
              legacyDomain(row, unmigratedRows).catch(() => {
                signal.throwIfAborted();
                incomplete = true;
                return [];
              }),
            ),
          )
        ).flat()
      : [];
    if (
      unmigratedRows.some(
        (row) => !rawLegacy.some((entry) => listed(entry, [row])),
      )
    )
      incomplete = true;
    const entries = mergeEntries(ws.entries, rawLegacy, ws.deletedIds);
    prefetch(entries);
    return { entries, incomplete };
  };

  const remember = (entry: PromptShortcutIndexEntry, value: PromptShortcut) => {
    if (!live()) return;
    scope.bodies.delete(entry.bodyDocId);
    scope.bodies.set(entry.bodyDocId, { entry: JSON.stringify(entry), value });
    while (scope.bodies.size > BODY_LIMIT)
      scope.bodies.delete(scope.bodies.keys().next().value!);
  };

  const cachedBody = (entry: PromptShortcutIndexEntry) => {
    const hit = scope.bodies.get(entry.bodyDocId);
    return hit?.entry === JSON.stringify(entry) ? hit.value : undefined;
  };

  const readBodyDoc = async (
    stream: string,
    getGrant: () => Promise<{ token: string; gatewayBaseUrl: string }>,
    readSignal: AbortSignal,
  ) => {
    const client = await clientFor(stream, getGrant);
    const first = await client.bootstrap({ signal: readSignal });
    if (!first.ok) {
      if (first.result.code === 'not_found') {
        return { exists: false as const, doc: new LoroDoc(), client };
      }
      throw new Error('shortcut_unavailable');
    }
    const doc = new LoroDoc();
    let bytesRead = 0;
    const bound = (bytes: Uint8Array) => {
      bytesRead += bytes.length;
      if (bytesRead > 8 * 1024 * 1024) throw new Error('shortcut_limit');
    };
    const apply = (bytes: Uint8Array) => {
      bound(bytes);
      for (const frame of decodeFrames(bytes)) doc.import(frame);
    };
    const data = first.result;
    if (data.snapshotOffset !== '-1' && data.snapshot) {
      const bytes = data.snapshot.body;
      bound(bytes);
      doc.import(
        bytes[0] === 0x28 &&
          bytes[1] === 0xb5 &&
          bytes[2] === 0x2f &&
          bytes[3] === 0xfd
          ? decompress(bytes)
          : bytes,
      );
    }
    for (const part of data.updates) apply(part.body);
    let { nextOffset: offset, cursor, upToDate } = data;
    for (let page = 0; !upToDate; page++) {
      if (page >= 100) throw new Error('shortcut_limit');
      const next = await client.readOnce({
        offset,
        cursor,
        signal: readSignal,
      });
      if (!next.ok) throw new Error('shortcut_unavailable');
      if (next.result.payload) apply(next.result.payload.body);
      if (offset === next.result.nextOffset && !next.result.upToDate)
        throw new Error('stalled_cursor');
      ({ nextOffset: offset, cursor, upToDate } = next.result);
    }
    return { exists: true as const, doc, client };
  };

  /** The body for an authorized entry: remembered, joined in flight, or downloaded once. */
  const body = (entry: PromptShortcutIndexEntry) => {
    const hit = cachedBody(entry);
    if (hit) return Promise.resolve(hit);
    const key = JSON.stringify(entry);
    let pending = scope.reads.get(key);
    if (!pending) {
      pending = download(entry, AbortSignal.timeout(30000))
        .then((value) => {
          remember(entry, value);
          return value;
        })
        .finally(() => {
          if (scope.reads.get(key) === pending) scope.reads.delete(key);
        });
      scope.reads.set(key, pending);
    }
    return pending;
  };

  const download = async (
    entry: PromptShortcutIndexEntry,
    readSignal: AbortSignal,
  ) => {
    const wsStream = getWorkspaceShortcutBodyStreamId(
      workspaceId,
      entry.bodyDocId,
    );
    let loaded = await readBodyDoc(wsStream, workspaceGrant, readSignal);
    if (!loaded.exists) {
      if (!cloud) throw new Error('shortcut_unavailable');
      const legacyStream = getShortcutBodyStreamId(entry.bodyDocId);
      loaded = await readBodyDoc(
        legacyStream,
        grant(
          legacyStream,
          { kind: 'body', bodyDocId: entry.bodyDocId },
          false,
        ),
        readSignal,
      );
      if (!loaded.exists) throw new Error('shortcut_unavailable');
    }
    const value = new PromptShortcutDocument(loaded.doc).read();
    if (
      !value ||
      JSON.stringify(projectShortcutIndex(value, entry.bodyDocId)) !==
        JSON.stringify(entry)
    )
      throw new Error('shortcut_changed');
    return value;
  };

  /** `fresh` re-reads the index/directory first; saves use it, opening and sending do not. */
  const read = async (entry: PromptShortcutIndexEntry, fresh = false) => {
    await authorized(entry, fresh);
    const value = await body(entry);
    signal.throwIfAborted();
    return value;
  };

  /**
   * Listed bodies download in the background, one at a time, so opening or choosing a
   * shortcut usually needs no network.
   */
  const prefetch = (entries: PromptShortcutIndexEntry[]) => {
    if (!live()) return;
    scope.prefetch = entries
      .filter((entry) => !cachedBody(entry))
      .slice(0, PREFETCH_LIMIT);
    if (scope.prefetching) return;
    scope.prefetching = true;
    void (async () => {
      try {
        for (let next; live() && (next = scope.prefetch.shift());)
          await body(next).catch(() => undefined);
      } finally {
        scope.prefetching = false;
      }
    })();
  };

  return {
    list,
    listAvailable,
    read,
    body,
    authorized,
    workspaceIndex,
    openWorkspaceIndexForWrite,
    readBodyDoc,
    remember,
    grant,
    directory,
  };
}

type ShortcutListing = {
  entries: PromptShortcutIndexEntry[];
  incomplete: boolean;
};
const listings = new Map<
  string,
  { value?: ShortcutListing; pending?: Promise<ShortcutListing> }
>();

/**
 * The shortcuts a composer lists, per workspace and account.
 */
export async function listedShortcuts(
  workspaceId: string,
  userId: string,
  workspaceGrant: WorkspaceGrant,
  cloud?: Cloud,
): Promise<ShortcutListing> {
  const key = `${workspaceId}:${userId}`;
  for (const other of listings.keys())
    if (other !== key) listings.delete(other);
  const slot = listings.get(key) ?? {};
  listings.set(key, slot);
  slot.pending ??= shortcutAccess(
    workspaceId,
    userId,
    workspaceGrant,
    cloud,
    AbortSignal.timeout(30000),
  )
    .listAvailable()
    .then((value) => {
      if (listings.get(key) === slot) slot.value = value;
      return value;
    })
    .finally(() => {
      slot.pending = undefined;
    });
  const pending = slot.pending;
  if (slot.value) {
    pending.catch(() => {});
    return slot.value;
  }
  return pending.catch(() => ({ entries: [], incomplete: true }));
}

export async function promptShortcuts(
  request: ShortcutRequest,
  userId: string,
  workspaceGrant: WorkspaceGrant,
  cloud: Cloud | undefined,
  signal: AbortSignal,
) {
  if (!userId) throw new Error('shortcut_unavailable');
  const access = shortcutAccess(
    request.workspaceId,
    userId,
    workspaceGrant,
    cloud,
    signal,
  );
  if (request.action === 'list')
    return (await access.listAvailable(request.fresh === true)).entries;
  if (request.action === 'read') {
    let entry: PromptShortcutIndexEntry;
    try {
      entry = parseShortcutIndex(request.entry);
    } catch (error) {
      mapShortcutError(error);
    }
    return access.read(entry);
  }
  if (request.action === 'select') {
    // As web checks its live snapshot: the listing the composer showed, not a fresh index read,
    // so a prefetched body inserts without waiting on the network.
    const listing =
      listings.get(`${request.workspaceId}:${userId}`)?.value ??
      (await listedShortcuts(
        request.workspaceId,
        userId,
        workspaceGrant,
        cloud,
      ));
    const entry = listing.entries.find((item) => item.id === request.id);
    if (!entry) throw new Error('shortcut_changed');
    const value = await access.body(entry);
    signal.throwIfAborted();
    return value;
  }
  if (request.action !== 'save') throw new Error('invalid_shortcut');

  let value: PromptShortcut;
  let base: PromptShortcutIndexEntry | null;
  let entry: PromptShortcutIndexEntry;
  try {
    value = parsePromptShortcut(request.value);
    base = request.entry ? parseShortcutIndex(request.entry) : null;
    entry = projectShortcutIndex(value, request.bodyDocId);
  } catch (error) {
    mapShortcutError(error);
  }
  if (
    value.workspaceId !== request.workspaceId ||
    value.ownerUserId !== userId ||
    !simpleShortcut(value) ||
    !value.prompt.trim()
  )
    throw new Error('invalid_shortcut');
  if (
    base &&
    (base.id !== value.id ||
      base.workspaceId !== request.workspaceId ||
      base.ownerUserId !== userId ||
      !simpleShortcut(base))
  )
    throw new Error('invalid_shortcut');
  if (
    base &&
    (request.bodyDocId !== base.bodyDocId ||
      value.createdAt !== base.createdAt ||
      value.revision === base.revision)
  )
    throw new Error('invalid_shortcut');

  const wsIndex = await access.workspaceIndex(true);
  if (wsIndex.deletedIds.has(value.id)) throw new Error('shortcut_changed');
  const wsExisting = wsIndex.entries.find((item) => item.id === value.id);
  if (
    wsExisting?.bodyDocId === entry.bodyDocId &&
    wsExisting.revision === entry.revision
  ) {
    const published = await access.read(entry, true);
    if (JSON.stringify(published) !== JSON.stringify(value))
      throw new Error('shortcut_changed');
    listings.clear();
    return entry;
  }

  const wsBodyStream = getWorkspaceShortcutBodyStreamId(
    request.workspaceId,
    entry.bodyDocId,
  );
  const wsBody = await access.readBodyDoc(wsBodyStream, workspaceGrant, signal);
  let remoteHeads: PromptShortcut[] = [];
  if (wsBody.exists) {
    try {
      remoteHeads = new PromptShortcutDocument(wsBody.doc).heads();
    } catch (error) {
      mapShortcutError(error);
    }
  }
  const bodyAlreadySaved =
    remoteHeads.length === 1 && remoteHeads[0]?.revision === entry.revision;
  if (bodyAlreadySaved) {
    if (JSON.stringify(remoteHeads[0]) !== JSON.stringify(value))
      throw new Error('shortcut_changed');
  } else {
    if (base) {
      await access.read(base, true);
      if (
        remoteHeads.length > 0 &&
        (remoteHeads.length !== 1 || remoteHeads[0]?.revision !== base.revision)
      )
        throw new Error('shortcut_changed');
    } else {
      if (
        wsExisting ||
        remoteHeads.length > 0 ||
        (cloud &&
          (await access.directory(true)).some(
            (row) => row.shortcutId === value.id,
          ))
      )
        throw new Error('shortcut_changed');
    }

    const available = await access.listAvailable(true);
    if (
      available.entries.some(
        (other) => other.id !== entry.id && other.slug === entry.slug,
      )
    )
      throw new Error('invalid_shortcut');
    try {
      const trial = new Flock(`lody-shortcut-validate-${crypto.randomUUID()}`);
      if (wsIndex.flock) trial.importFile(wsIndex.flock.exportFile());
      new PromptShortcutCatalog(trial).put(entry);
    } catch (error) {
      mapShortcutError(error, false);
    }

    signal.throwIfAborted();
    const created = await wsBody.client.create({
      contentType: 'application/octet-stream',
    });
    if (!created.ok) throw new Error('shortcut_write_unknown');
    const expectedParents = remoteHeads.length === 0 ? [] : [base!.revision];
    const from = wsBody.doc.oplogVersion();
    try {
      new PromptShortcutDocument(wsBody.doc).save(value, expectedParents);
    } catch (error) {
      mapShortcutError(error, false);
    }
    const bodyBytes =
      remoteHeads.length === 0
        ? wsBody.doc.export({ mode: 'snapshot' })
        : wsBody.doc.export({ mode: 'update', from });
    signal.throwIfAborted();
    const appended = await wsBody.client.append({
      part: {
        contentType: 'application/octet-stream',
        body: encodeFrame(bodyBytes),
      },
    });
    if (!appended.ok) throw new Error('shortcut_write_unknown');
  }

  signal.throwIfAborted();
  const wsIndexStream = getWorkspaceShortcutIndexStreamId(request.workspaceId);
  try {
    const { flock, client } = await access.openWorkspaceIndexForWrite();
    const catalog = new PromptShortcutCatalog(flock);
    const currentRecord = catalog.get(entry.id);
    if (currentRecord?.kind === 'deleted') throw new Error('shortcut_changed');
    if (
      base === null &&
      currentRecord?.kind === 'active' &&
      currentRecord.entry.revision !== entry.revision
    )
      throw new Error('shortcut_changed');
    if (
      base !== null &&
      currentRecord?.kind === 'active' &&
      currentRecord.entry.revision !== base.revision &&
      currentRecord.entry.revision !== entry.revision
    )
      throw new Error('shortcut_changed');

    if (
      currentRecord?.kind !== 'active' ||
      currentRecord.entry.revision !== entry.revision ||
      currentRecord.entry.bodyDocId !== entry.bodyDocId
    ) {
      const version = flock.version();
      try {
        catalog.put(entry);
      } catch (error) {
        mapShortcutError(error, true);
      }
      signal.throwIfAborted();
      const saved = await client.append({
        part: {
          contentType: 'application/octet-stream',
          body: encodeFrame(
            new TextEncoder().encode(JSON.stringify(flock.exportJson(version))),
          ),
        },
      });
      if (!saved.ok) throw new Error('shortcut_write_unknown');
    }
  } finally {
    forgetSettings(wsIndexStream);
  }

  const published = await access.read(entry, true);
  if (JSON.stringify(published) !== JSON.stringify(value))
    throw new Error('shortcut_changed');
  access.remember(entry, published);
  listings.clear();
  return entry;
}

export async function expandShortcuts(
  text: string,
  list: () => Promise<PromptShortcutIndexEntry[]>,
  read: (
    entry: PromptShortcutIndexEntry,
  ) => Promise<{ prompt: string; scope: object; mentions: unknown[] }>,
  expandRest: (text: string) => Promise<string> = async (text) => text,
) {
  const pattern = /(^|\s)\/shortcut:([a-z0-9][a-z0-9-]{0,39})(?=\s|$)/g;
  const matches = [...text.matchAll(pattern)];
  if (!matches.length) return expandRest(text);
  const entries = await list().catch(() => {
    throw new Error('shortcut_unavailable');
  });
  let result = '',
    offset = 0;
  for (const match of matches) {
    const candidates = entries.filter((entry) => entry.slug === match[2]);
    if (!candidates.length) throw new Error('shortcut_unavailable');
    if (candidates.length !== 1 || !simpleShortcut(candidates[0]))
      throw new Error('shortcut_unavailable');
    const value = await read(candidates[0]).catch(() => {
      throw new Error('shortcut_unavailable');
    });
    if (!simpleShortcut(value)) throw new Error('shortcut_unavailable');
    result +=
      (await expandRest(text.slice(offset, match.index))) +
      match[1] +
      value.prompt;
    offset = match.index! + match[0].length;
  }
  return result + (await expandRest(text.slice(offset)));
}
