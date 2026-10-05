import { EphemeralStore } from 'loro-crdt/base64';

/**
 * Lody's `LODY_PRESENCE_TTL_MS`. Every machine heartbeats into the workspace's
 * ephemeral `presence` channel every 30 s, and Lody judges a machine online
 * from that heartbeat alone; a ping only measures latency.
 */
export const PRESENCE_TTL_MS = 90_000;
/** Lody's live inactivity timeout; the hub's keepalive comments count as activity. */
const INACTIVITY_MS = 45_000;
/** The connection page asks every 15 s; a channel nobody asked about for this long closes. */
const IDLE_MS = 60_000;
/** How long the first question waits for the channel's bootstrap. */
const FIRST_ANSWER_MS = 3_000;

/** Machine ids whose last heartbeat is fresh. */
export function onlineMachineIds(states: Record<string, unknown>, now: number) {
  const online = new Set<string>();
  for (const state of Object.values(states)) {
    const value = state as {
      kind?: unknown;
      machineId?: unknown;
      updatedAt?: unknown;
    } | null;
    if (
      value?.kind === 'machine' &&
      typeof value.machineId === 'string' &&
      typeof value.updatedAt === 'number' &&
      now - value.updatedAt < PRESENCE_TTL_MS
    )
      online.add(value.machineId);
  }
  return online;
}

/** Splits a Server-Sent Events body into events; every chunk, comments included, is activity. */
export async function* sseEvents(
  body: ReadableStream<Uint8Array>,
  onActivity: () => void,
  signal: AbortSignal,
) {
  const reader = body.getReader();
  const decoder = new TextDecoder();
  const cancel = () => void reader.cancel().catch(() => {});
  signal.addEventListener('abort', cancel, { once: true });
  let buffer = '';
  try {
    for (;;) {
      const { value, done } = await reader.read();
      if (done) return;
      onActivity();
      buffer += decoder.decode(value, { stream: true }).replace(/\r/g, '');
      let end = buffer.indexOf('\n\n');
      while (end >= 0) {
        const block = buffer.slice(0, end);
        buffer = buffer.slice(end + 2);
        let event = 'message';
        const data: string[] = [];
        for (const line of block.split('\n')) {
          if (line.startsWith('event:')) event = line.slice(6).trim();
          else if (line.startsWith('data:'))
            data.push(line.slice(5).replace(/^ /, ''));
        }
        if (data.length) yield { event, data: data.join('\n') };
        end = buffer.indexOf('\n\n');
      }
    }
  } finally {
    signal.removeEventListener('abort', cancel);
    reader.releaseLock();
  }
}

const decodeBase64 = (text: string) =>
  Uint8Array.from(atob(text), (char) => char.charCodeAt(0));

const pause = (ms: number, signal: AbortSignal) =>
  new Promise<void>((resolve) => {
    const timer = setTimeout(resolve, ms);
    signal.addEventListener(
      'abort',
      () => {
        clearTimeout(timer);
        resolve();
      },
      { once: true },
    );
  });

/**
 * The workspace presence channel, opened while someone asks about it. `open`
 * starts the `?ephemeral=presence&live=sse` read of the workspace meta stream.
 */
export function createPresence(
  open: (signal: AbortSignal) => Promise<Response>,
) {
  let store: EphemeralStore | undefined;
  let controller: AbortController | undefined;
  let idle: ReturnType<typeof setTimeout> | undefined;
  let bootstrapped: () => void = () => {};
  let ready = Promise.resolve();

  async function run(signal: AbortSignal) {
    let failures = 0;
    while (!signal.aborted) {
      const live = new AbortController();
      const abort = () => live.abort();
      signal.addEventListener('abort', abort, { once: true });
      let timer: ReturnType<typeof setTimeout> | undefined;
      const touch = () => {
        clearTimeout(timer);
        timer = setTimeout(abort, INACTIVITY_MS);
      };
      const next = new EphemeralStore(PRESENCE_TTL_MS);
      try {
        touch();
        const response = await open(live.signal);
        if (
          !response.ok ||
          !response.body ||
          response.headers.get('Stream-SSE-Data-Encoding') !== 'base64'
        )
          throw new Error(`presence_${response.status}`);
        for await (const { event, data } of sseEvents(
          response.body,
          touch,
          live.signal,
        )) {
          if (event !== 'bootstrap' && event !== 'data') continue;
          const bytes = decodeBase64(data);
          if (bytes.length) next.apply(bytes);
          if (event === 'bootstrap') {
            store = next;
            failures = 0;
            bootstrapped();
          }
        }
      } catch {
        // A dropped or refused channel is retried below; until then nothing is known.
      } finally {
        clearTimeout(timer);
        signal.removeEventListener('abort', abort);
        if (store === next) store = undefined;
        next.destroy();
      }
      await pause(Math.min(30_000, 1_000 * 2 ** failures++), signal);
    }
  }

  function stop() {
    clearTimeout(idle);
    controller?.abort();
    controller = undefined;
  }

  return {
    /** Machine ids with a fresh heartbeat, or undefined while the channel is not synced. */
    async online(): Promise<Set<string> | undefined> {
      clearTimeout(idle);
      idle = setTimeout(stop, IDLE_MS);
      if (!controller) {
        controller = new AbortController();
        ready = new Promise((resolve) => {
          bootstrapped = resolve;
        });
        void run(controller.signal);
      }
      if (!store) {
        let timer: ReturnType<typeof setTimeout> | undefined;
        await Promise.race([
          ready,
          new Promise((resolve) => {
            timer = setTimeout(resolve, FIRST_ANSWER_MS);
          }),
        ]);
        clearTimeout(timer);
      }
      return store && onlineMachineIds(store.getAllStates(), Date.now());
    },
    stop,
  };
}
