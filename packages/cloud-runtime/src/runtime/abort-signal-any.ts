/**
 * `AbortSignal.any` for WebKit before 17.4 (the app supports iOS 16.4) and older
 * Android System WebViews. The runtime entry imports this module first, so every
 * runtime and vendored module may call `AbortSignal.any` unchanged.
 *
 * As the DOM standard: the result aborts with the reason of the first input to
 * abort, is already aborted (with that input's reason) when an input is, and
 * drops its listeners on every input once it aborts.
 */
export function abortSignalAny(signals: Iterable<AbortSignal>): AbortSignal {
  const inputs = [...signals];
  const controller = new AbortController();
  const aborted = inputs.find((signal) => signal.aborted);
  if (aborted) {
    controller.abort(aborted.reason);
    return controller.signal;
  }
  const listeners = inputs.map((signal) => {
    const listener = () => {
      for (const [input, remove] of listeners)
        input.removeEventListener('abort', remove);
      controller.abort(signal.reason);
    };
    return [signal, listener] as const;
  });
  for (const [signal, listener] of listeners)
    signal.addEventListener('abort', listener);
  return controller.signal;
}

/** Installs the fallback only where the platform lacks `AbortSignal.any`. */
export function installAbortSignalAny(
  target: { any?: unknown } = AbortSignal as { any?: unknown },
) {
  if (typeof target.any === 'function') return false;
  Object.defineProperty(target, 'any', {
    value: abortSignalAny,
    writable: true,
    configurable: true,
  });
  return true;
}

installAbortSignalAny();
