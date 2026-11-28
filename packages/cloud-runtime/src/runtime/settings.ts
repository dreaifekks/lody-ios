import { Flock } from '@loro-dev/flock-wasm/base64';
import { decompress } from 'fzstd';
import { clientFor } from './session';
import { encodeFrame } from '../frames';
import {
  catalogImportCheckpoint,
  importCatalogUpdates,
  readCatalogRefresh,
} from './catalog-sync';
import type { RemoteSetting, SettingsRequest } from '../models/settings.ts';

type Grant = (() => Promise<{ token: string; gatewayBaseUrl: string }>) & {
  invalidate?: (failedToken?: string) => void;
};
const object = (value: unknown): Record<string, unknown> =>
  value && typeof value === 'object' && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : {};
const text = (value: unknown) => (typeof value === 'string' ? value : '');

// Settings are read on demand inside the native-owned runtime. List reads may opt
// into a per-runtime cache of each stream's last read, so the next list only catches
// up from its offset instead of bootstrapping the whole history. Callers always
// receive a private copy, so a write that fails to append never leaks into the
// cache; writes and turn-time reads still bootstrap fresh.
type Cached = {
  flock: Flock;
  offset: string;
  cursor: string | undefined;
  snapshotBytes: number;
};
const replicas = new Map<string, Cached>();
const SETTINGS_LIMIT = 16 * 1024 * 1024;
const READ_RETRY_DELAYS_MS = [250, 750];

function waitRetry(ms: number, signal: AbortSignal) {
  signal.throwIfAborted();
  return new Promise<void>((resolve, reject) => {
    const abort = () => {
      clearTimeout(timer);
      reject(signal.reason);
    };
    const timer = setTimeout(() => {
      signal.removeEventListener('abort', abort);
      resolve();
    }, ms);
    signal.addEventListener('abort', abort, { once: true });
  });
}

function retryableGrantError(error: unknown, signal: AbortSignal) {
  if (signal.aborted) return false;
  return (
    typeof error === 'object' &&
    error !== null &&
    (error as { retryable?: unknown }).retryable === true
  );
}

function retryableStreamResult(
  error: { code: string; status?: number; cause?: unknown },
  signal: AbortSignal,
  grant: Grant,
  lastToken: string | undefined,
) {
  if (signal.aborted) return false;
  if (error.code === 'unauthorized') {
    grant.invalidate?.(lastToken);
    return true;
  }
  if (['network_error', 'timeout', 'rate_limited'].includes(error.code))
    return true;
  if (error.code !== 'unknown') return false;
  if ((error.status ?? 0) >= 500) return true;
  return (
    (error.cause instanceof Error || error.cause instanceof DOMException) &&
    error.cause.name === 'AbortError'
  );
}

async function readPageWithRetry(
  client: Awaited<ReturnType<typeof clientFor>>,
  offset: string,
  cursor: string | undefined,
  signal: AbortSignal,
  grant: Grant,
  getLastToken: () => string | undefined,
) {
  for (let attempt = 0; ; attempt++) {
    signal.throwIfAborted();
    const next = await client.readOnce({ offset, cursor, signal });
    if (next.ok) return next.result;
    if (
      attempt >= READ_RETRY_DELAYS_MS.length ||
      !retryableStreamResult(next.result, signal, grant, getLastToken())
    )
      throw new Error(next.result.code);
    await waitRetry(READ_RETRY_DELAYS_MS[attempt], signal);
  }
}

/** Drops cached settings reads (all streams on account/workspace switch, or one stream after write). */
export function forgetSettings(stream?: string) {
  if (stream) replicas.delete(stream);
  else replicas.clear();
}

function copy(flock: Flock) {
  const result = new Flock(`lody-ios-settings-${crypto.randomUUID()}`);
  result.importFile(flock.exportFile());
  return result;
}

async function catchUp(
  client: Awaited<ReturnType<typeof clientFor>>,
  cached: Cached,
  signal: AbortSignal,
  grant: Grant,
  getLastToken: () => string | undefined,
) {
  let size = 0;
  const checkpoint = catalogImportCheckpoint(signal);
  const apply = async (bytes: Uint8Array) => {
    size += bytes.length;
    if (size > SETTINGS_LIMIT) throw new Error('catalog_limit');
    await importCatalogUpdates(cached.flock, bytes, checkpoint);
  };
  for (let page = 0; ; page++) {
    signal.throwIfAborted();
    if (page >= 100) throw new Error('catalog_limit');
    const next = await readPageWithRetry(
      client,
      cached.offset,
      cached.cursor,
      signal,
      grant,
      getLastToken,
    );
    if (next.payload) await apply(next.payload.body);
    if (next.upToDate) {
      cached.offset = next.nextOffset;
      cached.cursor = next.cursor;
      return;
    }
    if (cached.offset === next.nextOffset) throw new Error('stalled_cursor');
    cached.offset = next.nextOffset;
    cached.cursor = next.cursor;
  }
}

export async function openSettings(
  stream: string,
  grant: Grant,
  signal: AbortSignal,
  options: { cached?: boolean } = {},
) {
  let lastToken: string | undefined;
  const trackedGrant: Grant = Object.assign(
    async () => {
      const value = await grant();
      lastToken = value.token;
      return value;
    },
    { invalidate: grant.invalidate },
  );
  let client!: Awaited<ReturnType<typeof clientFor>>;
  for (let attempt = 0; ; attempt++) {
    signal.throwIfAborted();
    try {
      client = await clientFor(stream, trackedGrant);
      break;
    } catch (error) {
      if (
        attempt >= READ_RETRY_DELAYS_MS.length ||
        !retryableGrantError(error, signal)
      )
        throw error;
      await waitRetry(READ_RETRY_DELAYS_MS[attempt], signal);
    }
  }
  const cached = options.cached ? replicas.get(stream) : undefined;
  let preparedBootstrap: Awaited<ReturnType<typeof readCatalogRefresh>>;
  if (cached) {
    try {
      preparedBootstrap = await readCatalogRefresh(
        client,
        cached.offset,
        cached.snapshotBytes,
        SETTINGS_LIMIT,
        signal,
      );
      if (!preparedBootstrap) {
        await catchUp(client, cached, signal, trackedGrant, () => lastToken);
        return { flock: copy(cached.flock), client };
      }
      replicas.delete(stream);
    } catch (error) {
      replicas.delete(stream);
      if (signal.aborted) throw error;
    }
  }
  let data!: NonNullable<typeof preparedBootstrap>;
  if (preparedBootstrap) {
    data = preparedBootstrap;
  } else {
    for (let attempt = 0; ; attempt++) {
      signal.throwIfAborted();
      let initial;
      try {
        initial = await client.bootstrap({ signal });
      } catch (error) {
        if (
          attempt >= READ_RETRY_DELAYS_MS.length ||
          !retryableGrantError(error, signal)
        )
          throw error;
        await waitRetry(READ_RETRY_DELAYS_MS[attempt], signal);
        continue;
      }
      if (initial.ok) {
        data = initial.result;
        break;
      }
      if (
        attempt >= READ_RETRY_DELAYS_MS.length ||
        !retryableStreamResult(initial.result, signal, trackedGrant, lastToken)
      )
        throw new Error(initial.result.code);
      await waitRetry(READ_RETRY_DELAYS_MS[attempt], signal);
    }
  }
  const flock = new Flock(`lody-ios-settings-${crypto.randomUUID()}`);
  const snapshotBytes = data.snapshot?.body.length ?? 0;
  const checkpoint = catalogImportCheckpoint(signal);
  let size = 0;
  const bound = (bytes: Uint8Array) => {
    size += bytes.length;
    if (size > SETTINGS_LIMIT) throw new Error('catalog_limit');
  };
  const apply = async (bytes: Uint8Array) => {
    bound(bytes);
    await importCatalogUpdates(flock, bytes, checkpoint);
  };
  if (data.snapshotOffset !== '-1' && data.snapshot) {
    const bytes = data.snapshot.body;
    bound(bytes);
    await checkpoint(true);
    flock.importFile(
      bytes[0] === 0x28 &&
        bytes[1] === 0xb5 &&
        bytes[2] === 0x2f &&
        bytes[3] === 0xfd
        ? decompress(bytes)
        : bytes,
    );
  }
  await checkpoint();
  for (const part of data.updates) await apply(part.body);
  let offset = data.nextOffset,
    cursor = data.cursor,
    upToDate = data.upToDate;
  for (let page = 0; !upToDate; page++) {
    signal.throwIfAborted();
    if (page >= 100) throw new Error('catalog_limit');
    const next = await readPageWithRetry(
      client,
      offset,
      cursor,
      signal,
      trackedGrant,
      () => lastToken,
    );
    if (next.payload) await apply(next.payload.body);
    if (offset === next.nextOffset && !next.upToDate)
      throw new Error('stalled_cursor');
    ({ nextOffset: offset, cursor, upToDate } = next);
  }
  if (!options.cached) return { flock, client };
  if (replicas.size >= 64) replicas.delete(replicas.keys().next().value!);
  replicas.set(stream, { flock, offset, cursor, snapshotBytes });
  return { flock: copy(flock), client };
}

export function settingsRows(
  kind: RemoteSetting['kind'],
  flock: Flock,
  machineId?: string,
): RemoteSetting[] {
  const rows: RemoteSetting[] = [];
  for (const row of flock.scan()) {
    if (row.key.length !== 2) continue;
    const id = text(row.key[1]),
      value = object(row.value);
    if (kind === 'machine') {
      if (
        row.key[0] !== 'e' ||
        !id.startsWith('machine-') ||
        row.value !== true
      )
        continue;
      const metadata = object(flock.get(['m', id]));
      rows.push({
        kind,
        id: id.slice(8),
        name: text(flock.get(['m', id, 'name']) ?? metadata.name),
        detail: text(flock.get(['m', id, 'os']) ?? metadata.os),
      });
    } else if (kind === 'agent') {
      if (
        row.key[0] !== 'agentConfig' ||
        value.id !== id ||
        value.machineId !== machineId
      )
        continue;
      rows.push({
        kind,
        id,
        machineId,
        name: text(value.name),
        prompt: text(value.prompt),
        detail: text(value.agentType),
      });
    }
  }
  return rows.sort((a, b) => a.name.localeCompare(b.name));
}

export function editSetting(flock: Flock, request: SettingsRequest) {
  const edit = request.edit;
  if (
    !edit ||
    edit.item.kind !== request.kind ||
    !edit.item.id ||
    typeof edit.name !== 'string'
  )
    throw new Error('invalid_setting');
  const name = edit.name.trim();
  if (!name || name.length > 200 || name.includes('\0'))
    throw new Error('invalid_setting');
  const current = settingsRows(request.kind, flock, edit.item.machineId).find(
    (row) => row.id === edit.item.id,
  );
  if (!current) throw new Error('setting_not_found');
  const fields = ['name', 'prompt'] as const;
  for (const field of fields)
    if (edit[field] !== undefined && current[field] !== edit.item[field])
      throw new Error('setting_conflict');
  if (request.kind === 'machine') {
    flock.set(['m', `machine-${current.id}`, 'name'], name);
  } else {
    const key = ['agentConfig', current.id];
    const value = { ...object(flock.get(key)), name };
    if (
      typeof edit.prompt !== 'string' ||
      edit.prompt.length > 32000 ||
      edit.prompt.includes('\0')
    )
      throw new Error('invalid_setting');
    Object.assign(value, { prompt: edit.prompt });
    flock.set(key, value);
  }
  flock.commit();
}

export async function remoteSettings(
  request: SettingsRequest,
  userId: string,
  grant: Grant,
  signal: AbortSignal,
) {
  if (!['machine', 'agent'].includes(request.kind))
    throw new Error('invalid_setting');
  const { workspaceId, kind, edit } = request;
  const writing = !!edit;
  const meta = await openSettings(`${workspaceId}:meta`, grant, signal);
  const machines = settingsRows('machine', meta.flock);
  const owned = (id: string) => {
    const room = `machine-${id}`;
    const owner =
      meta?.flock.get(['m', room, 'ownerUserId']) ??
      object(meta?.flock.get(['m', room])).ownerUserId;
    return !!userId && owner === userId;
  };
  let ids = machines.map((machine) => machine.id);
  if (
    edit &&
    !owned(kind === 'machine' ? edit.item.id : (edit.item.machineId ?? ''))
  )
    throw new Error('setting_read_only');
  if (kind === 'agent' && edit) {
    if (!edit.item.machineId || !ids.includes(edit.item.machineId))
      throw new Error('machine_unavailable');
    ids = [edit.item.machineId];
  }
  let streams: { stream: string; machineId?: string }[];
  if (kind === 'agent')
    streams = ids.map((id) => ({
      stream: `${workspaceId}:mf:${id}`,
      machineId: id,
    }));
  else
    streams = [
      {
        stream: `${workspaceId}:meta`,
      },
    ];
  const result: RemoteSetting[] = [];
  for (const { stream, machineId } of streams) {
    let replica;
    try {
      replica =
        kind === 'machine' && meta
          ? meta
          : await openSettings(stream, grant, signal);
    } catch (error) {
      if (
        !writing &&
        kind !== 'machine' &&
        error instanceof Error &&
        error.message === 'not_found'
      )
        continue;
      throw error;
    }
    const { flock, client } = replica;
    if (writing) {
      const version = flock.version();
      editSetting(flock, request);
      signal.throwIfAborted();
      const saved = await client.append({
        part: {
          contentType: 'application/octet-stream',
          body: encodeFrame(
            new TextEncoder().encode(JSON.stringify(flock.exportJson(version))),
          ),
        },
      });
      if (!saved.ok) {
        if (saved.result.code === 'forbidden')
          throw new Error('setting_read_only');
        throw new Error('setting_write_unknown');
      }
    }
    result.push(
      ...settingsRows(kind, flock, machineId).map((item) => ({
        ...item,
        readOnly: !owned(machineId ?? item.id),
        ...(machineId
          ? {
              machineName: machines.find((machine) => machine.id === machineId)
                ?.name,
            }
          : {}),
      })),
    );
  }
  return result;
}
