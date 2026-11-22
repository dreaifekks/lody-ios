// Retry reads only. Durable writes and Machine RPC must never use this helper.
const retryWaiters = new Set<() => void>();

export function wakeSessionReads() {
  for (const wake of [...retryWaiters]) wake();
}

export async function retrySessionRead<T>(
  signal: AbortSignal,
  read: () => Promise<T>,
  onRetry: (error: unknown) => void,
  { fixedDelayMs }: { fixedDelayMs?: number } = {},
): Promise<T> {
  let delay = fixedDelayMs ?? 1000;
  for (;;) {
    signal.throwIfAborted();
    try {
      const result = await read();
      signal.throwIfAborted();
      return result;
    } catch (error) {
      signal.throwIfAborted();
      onRetry(error);
      signal.throwIfAborted();
      let woke = false;
      await new Promise<void>((resolve, reject) => {
        const cleanup = () => {
          clearTimeout(timer);
          retryWaiters.delete(wake);
          signal.removeEventListener('abort', abort);
        };
        const abort = () => {
          cleanup();
          reject(signal.reason);
        };
        const wake = () => {
          woke = true;
          cleanup();
          resolve();
        };
        const timer = setTimeout(() => {
          cleanup();
          resolve();
        }, delay);
        retryWaiters.add(wake);
        signal.addEventListener('abort', abort, { once: true });
      });
      delay = fixedDelayMs ?? (woke ? 1000 : Math.min(delay * 2, 30000));
    }
  }
}
