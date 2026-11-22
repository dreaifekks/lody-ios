declare const LODY_MOBILE_WORKER_URL: string;
const workerOrigin =
  typeof LODY_MOBILE_WORKER_URL === 'undefined'
    ? 'https://api.lody.ai'
    : LODY_MOBILE_WORKER_URL;

/**
 * Server clock for the Status view: the round-trip midpoint of Lody
 * `packages/shared/src/time-sync.ts`. Until one sample succeeds, the device
 * clock is used; a failed or discontinuous sample keeps the last calibration.
 */
export type ServerClock = {
  now(): number;
  /** The calibrated `server - device` offset in ms; 0 until a sample succeeds. */
  offset(): number;
  synced(): boolean;
  /** One calibration sample; resolves whether it was accepted. */
  sync(signal?: AbortSignal): Promise<boolean>;
};

export type ClockSources = {
  fetchServerTime: (signal?: AbortSignal) => Promise<number>;
  wallNow: () => number;
  monotonicNow: () => number;
};

const CLOCK_DISCONTINUITY_MS = 1_000;

export function createServerClock(sources: ClockSources): ServerClock {
  let offset = 0;
  let calibrated = false;
  return {
    now: () => sources.wallNow() + offset,
    offset: () => offset,
    synced: () => calibrated,
    async sync(signal) {
      try {
        signal?.throwIfAborted();
        const before = sources.wallNow();
        const elapsedBefore = sources.monotonicNow();
        const serverTime = await sources.fetchServerTime(signal);
        const after = sources.wallNow();
        const elapsed = sources.monotonicNow() - elapsedBefore;
        signal?.throwIfAborted();
        if (!Number.isFinite(serverTime)) return false;
        if (Math.abs(after - before - elapsed) > CLOCK_DISCONTINUITY_MS)
          return false;
        offset = Math.round(serverTime - (before + after) / 2);
        calibrated = true;
        return true;
      } catch {
        return false;
      }
    },
  };
}

/**
 * One `/api/time` read bounded by 5 s and the caller's signal. Combined by hand:
 * `AbortSignal.any` needs iOS 17.4 and the deployment target is 16.4.
 */
export async function fetchLodyServerTime(signal?: AbortSignal) {
  const controller = new AbortController();
  const abort = () => controller.abort(signal?.reason);
  const timer = setTimeout(
    () => controller.abort(new DOMException('timeout', 'TimeoutError')),
    5_000,
  );
  signal?.addEventListener('abort', abort, { once: true });
  try {
    if (signal?.aborted) abort();
    const response = await fetch(`${workerOrigin}/api/time`, {
      signal: controller.signal,
      credentials: 'omit',
    });
    if (!response.ok) throw new Error(`time_${response.status}`);
    const body = (await response.json()) as { serverTime?: unknown };
    if (typeof body?.serverTime !== 'number') throw new Error('time_invalid');
    return body.serverTime;
  } finally {
    clearTimeout(timer);
    signal?.removeEventListener('abort', abort);
  }
}

export const serverClock = createServerClock({
  fetchServerTime: fetchLodyServerTime,
  wallNow: () => Date.now(),
  monotonicNow: () => performance.now(),
});
