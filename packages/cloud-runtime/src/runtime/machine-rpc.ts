import { clientFor } from './session';

type Grant = () => Promise<{ token: string; gatewayBaseUrl: string }>;

export type RpcReply = {
  result?: unknown;
  error?: { code?: string; message?: string; data?: unknown };
};

async function prepareReply(
  workspaceId: string,
  machineId: string,
  grant: Grant,
  signal: AbortSignal,
  timeoutMs: number,
) {
  const replyTo = `${workspaceId}:rpc:res:${machineId}:${crypto.randomUUID()}`;
  const response = await clientFor(replyTo, grant);
  signal.throwIfAborted();
  const created = await response.create({
    contentType: 'application/json',
    ttlSeconds: Math.max(300, Math.ceil(timeoutMs / 1000) + 60),
  });
  if (!created.ok) throw new Error(created.result.code);
  signal.throwIfAborted();
  return { replyTo, response };
}

function scopedGrant(getGrant: Grant, signal: AbortSignal): Grant {
  return async () => {
    signal.throwIfAborted();
    const value = await getGrant();
    signal.throwIfAborted();
    return value;
  };
}

async function appendRequest(args: {
  workspaceId: string;
  machineId: string;
  method: string;
  params: unknown;
  replyTo: string;
  id: string;
  timeoutMs: number;
  grant: Grant;
  signal: AbortSignal;
}) {
  const {
    workspaceId,
    machineId,
    method,
    params,
    replyTo,
    id,
    timeoutMs,
    grant,
    signal,
  } = args;
  const client = await clientFor(`${workspaceId}:rpc:req:${machineId}`, grant);
  signal.throwIfAborted();
  const now = Date.now();
  const sent = await client.append({
    part: {
      contentType: 'application/json',
      body: JSON.stringify({
        jsonrpc: '2.0',
        id,
        rpcVersion: '1',
        workspaceId,
        machineId,
        replyTo,
        sentAt: now,
        expiresAt: now + timeoutMs,
        method,
        params,
      }),
    },
  });
  if (!sent.ok) throw new Error(sent.result.code);
}

function decodeReplies(bytes: Uint8Array): (RpcReply & { id?: string })[] {
  const parsed = JSON.parse(new TextDecoder().decode(bytes));
  return Array.isArray(parsed) ? parsed : [parsed];
}

export async function machineRpc(
  workspaceId: string,
  machineId: string,
  method: string,
  params: unknown,
  getGrant: Grant,
  signal: AbortSignal,
  onProgress?: (progress: Record<string, unknown>) => void,
  timeoutMs = 30000,
  id: string = crypto.randomUUID(),
): Promise<RpcReply> {
  const grant = scopedGrant(getGrant, signal);
  const { replyTo, response } = await prepareReply(
    workspaceId,
    machineId,
    grant,
    signal,
    timeoutMs,
  );
  await appendRequest({
    workspaceId,
    machineId,
    method,
    params,
    replyTo,
    id,
    timeoutMs,
    grant,
    signal,
  });
  let offset = '-1';
  while (!signal.aborted) {
    const read = await response.readOnce({ offset, live: 'long-poll', signal });
    if (!read.ok) throw new Error(read.result.code);
    offset = read.result.nextOffset;
    if (!read.result.payload) continue;
    for (const reply of decodeReplies(read.result.payload.body)) {
      if (reply.id !== id) continue;
      const progress = reply.result as Record<string, unknown> | undefined;
      if (
        (progress?.type === 'machine/acp-binary-progress' &&
          [
            'machine/acp-capabilities-refresh',
            'machine/acp-binary-install',
            'machine/acp-binary-status',
          ].includes(method)) ||
        (method === 'machine/acp-authenticate' &&
          progress?.type === 'machine/acp-authentication-progress')
      ) {
        onProgress?.(progress);
        continue;
      }
      return reply;
    }
  }
  throw new Error('cancelled');
}

export async function subscribeMachineHistory(options: {
  workspaceId: string;
  machineId: string;
  params: ContentEnvelope;
  closeParams: () => Promise<ContentEnvelope>;
  getGrant: Grant;
  signal: AbortSignal;
  timeoutMs: number;
  onReply: (reply: RpcReply) => Promise<boolean>;
}): Promise<void> {
  const { workspaceId, machineId, getGrant, signal, timeoutMs, params } =
    options;
  const grant = scopedGrant(getGrant, signal);
  const { replyTo, response } = await prepareReply(
    workspaceId,
    machineId,
    grant,
    signal,
    timeoutMs,
  );
  const id = crypto.randomUUID();
  let closed = false;
  try {
    await appendRequest({
      workspaceId,
      machineId,
      method: 'session/history-subscribe',
      params,
      replyTo,
      id,
      timeoutMs,
      grant,
      signal,
    });
    for await (const event of response.live({
      offset: '-1',
      mode: 'sse',
      signal,
    })) {
      signal.throwIfAborted();
      if (event.type === 'error') throw new Error(event.error.code);
      if (event.type !== 'data') continue;
      for (const reply of decodeReplies(event.payload.body)) {
        if (reply.id === id && (await options.onReply(reply))) {
          closed = true;
          return;
        }
      }
    }
    signal.throwIfAborted();
    throw new Error('history_subscription_closed');
  } finally {
    if (!closed) {
      // The open append may have reached the computer even if the upload failed.
      // Close is separately bounded and retains the original reply stream and proof.
      const closeSignal = AbortSignal.timeout(10_000);
      void options
        .closeParams()
        .then((closeParams) =>
          appendRequest({
            workspaceId,
            machineId,
            method: 'session/history-unsubscribe',
            params: closeParams,
            replyTo,
            id: crypto.randomUUID(),
            timeoutMs: 10_000,
            grant: scopedGrant(getGrant, closeSignal),
            signal: closeSignal,
          }),
        )
        .catch(() => {});
    }
  }
}

// Code Collab and file/preview payloads travel inside an AES-GCM envelope whose
// key is derived from the owning session id, matching the machine's
// `deriveCodeCollabV2ContentKeyBytes`.
const KEY_LABEL = 'lody-code-collab-v2-bootstrap-content-key-v1';
const KEY_ID_LABEL = 'lody-code-collab-v2-bootstrap-content-key-id-v1';
const SALT = 'lody-code-collab-v2-bootstrap-salt-v1';
const AAD_LABEL = 'lody-code-collab-v2-machine-rpc-payload-v1';
export const ENVELOPE_TYPE = 'code-collab-v2-content-envelope';

export type ContentEnvelope = {
  type: typeof ENVELOPE_TYPE;
  keyVersion: 1;
  algorithm: 'AES-256-GCM';
  ownerSessionId: string;
  keyId: string;
  iv: string;
  ciphertext: string;
};

const sha256 = async (value: string) =>
  new Uint8Array(
    await crypto.subtle.digest('SHA-256', new TextEncoder().encode(value)),
  );
const hex = (bytes: Uint8Array) =>
  [...bytes].map((b) => b.toString(16).padStart(2, '0')).join('');
const toBase64Url = (bytes: Uint8Array) => {
  let binary = '';
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary)
    .replace(/\+/g, '-')
    .replace(/\//g, '_')
    .replace(/=+$/, '');
};
const fromBase64Url = (value: string) => {
  const base64 = value.replace(/-/g, '+').replace(/_/g, '/');
  const binary = atob(
    base64.padEnd(base64.length + ((4 - (base64.length % 4)) % 4), '='),
  );
  return Uint8Array.from(binary, (c) => c.charCodeAt(0));
};

export const contentKeyId = async (ownerSessionId: string) =>
  `ccv2:${hex(await sha256(`${KEY_ID_LABEL}\0${SALT}\0${ownerSessionId}`)).slice(0, 24)}`;

async function contentKey(ownerSessionId: string) {
  return crypto.subtle.importKey(
    'raw',
    await sha256(`${KEY_LABEL}\0${SALT}\0${ownerSessionId}`),
    { name: 'AES-GCM' },
    false,
    ['encrypt', 'decrypt'],
  );
}
const aad = (ownerSessionId: string, keyId: string, keyVersion: number) =>
  new TextEncoder().encode(
    `${AAD_LABEL}\0${ownerSessionId}\0${keyId}\0${keyVersion}`,
  );

export async function sealPayload(
  ownerSessionId: string,
  payload: unknown,
): Promise<ContentEnvelope> {
  const keyId = await contentKeyId(ownerSessionId);
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const ciphertext = new Uint8Array(
    await crypto.subtle.encrypt(
      { name: 'AES-GCM', iv, additionalData: aad(ownerSessionId, keyId, 1) },
      await contentKey(ownerSessionId),
      new TextEncoder().encode(JSON.stringify(payload)),
    ),
  );
  return {
    type: ENVELOPE_TYPE,
    keyVersion: 1,
    algorithm: 'AES-256-GCM',
    ownerSessionId,
    keyId,
    iv: toBase64Url(iv),
    ciphertext: toBase64Url(ciphertext),
  };
}

export const isEnvelope = (value: unknown): value is ContentEnvelope =>
  !!value &&
  typeof value === 'object' &&
  (value as ContentEnvelope).type === ENVELOPE_TYPE;

export async function openPayload(envelope: ContentEnvelope): Promise<unknown> {
  const { ownerSessionId, keyId, keyVersion } = envelope;
  if (keyId !== (await contentKeyId(ownerSessionId)))
    throw new Error('envelope_key_mismatch');
  const plaintext = await crypto.subtle.decrypt(
    {
      name: 'AES-GCM',
      iv: fromBase64Url(envelope.iv),
      additionalData: aad(ownerSessionId, keyId, keyVersion),
    },
    await contentKey(ownerSessionId),
    fromBase64Url(envelope.ciphertext),
  );
  return JSON.parse(new TextDecoder().decode(plaintext));
}

export async function sealedRpc(
  workspaceId: string,
  machineId: string,
  method: string,
  ownerSessionId: string,
  params: unknown,
  getGrant: Grant,
  signal: AbortSignal,
): Promise<unknown> {
  const reply = await machineRpc(
    workspaceId,
    machineId,
    method,
    await sealPayload(ownerSessionId, params),
    getGrant,
    signal,
  );
  if (reply.error) {
    const data = isEnvelope(reply.error.data)
      ? await openPayload(reply.error.data)
      : reply.error.data;
    const error = new Error(
      reply.error.message ?? reply.error.code ?? 'rpc_failed',
    );
    Object.assign(error, { code: reply.error.code, data });
    throw error;
  }
  if (!isEnvelope(reply.result)) throw new Error('invalid_rpc_response');
  return openPayload(reply.result);
}
