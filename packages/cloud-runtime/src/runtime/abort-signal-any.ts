/**
 * `AbortSignal.any` for WebKit before 17.4 (the app supports iOS 16.4) and
 * Android System WebView before 116. Installed by `platform-fallbacks.ts`, so
 * every runtime and vendored module may call `AbortSignal.any` unchanged.
 *
 * As the DOM standard: the result aborts with the reason of the first input to
 * abort, is already aborted (with that input's reason) when an input is, and
 * drops its listeners on every input once it aborts. Inputs hold the result only
 * weakly, as the standard's dependent signals are: a long-lived input (a session
 * or watcher signal) does not keep every request signal combined with it alive,
 * and once a result is collected its listeners leave the inputs.
 */
const controllers = new WeakMap<AbortSignal, AbortController>();
const detachments = new FinalizationRegistry<() => void>((detach) => detach());

export function abortSignalAny(signals: Iterable<AbortSignal>): AbortSignal {
  const inputs = [...signals];
  const controller = new AbortController();
  const result = controller.signal;
  const aborted = inputs.find((signal) => signal.aborted);
  if (aborted) {
    controller.abort(aborted.reason);
    return result;
  }
  // Listeners reach the result only through this weak reference; the result
  // keeps its controller alive (`controllers`), never the inputs.
  controllers.set(result, controller);
  const target = new WeakRef(result);
  const token = {};
  const listeners = inputs.map((signal) => {
    const listener = () => {
      detach();
      detachments.unregister(token);
      const dependent = target.deref();
      if (dependent) controllers.get(dependent)?.abort(signal.reason);
    };
    return [signal, listener] as const;
  });
  const detach = () => {
    for (const [input, listener] of listeners)
      input.removeEventListener('abort', listener);
  };
  for (const [signal, listener] of listeners)
    signal.addEventListener('abort', listener);
  detachments.register(result, detach, token);
  return result;
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
