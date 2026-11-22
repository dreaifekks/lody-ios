/**
 * `URL.canParse` for WebKit before 17.0 (the app supports iOS 16.4) and Android
 * System WebView before 120. Installed by `platform-fallbacks.ts`.
 *
 * As the URL standard: true when `new URL(url, base)` succeeds, false when it
 * throws; `base` takes part only when it is given.
 */
export function urlCanParse(url: string | URL, ...rest: [base?: string | URL]) {
  try {
    if (rest.length && rest[0] !== undefined) new URL(url, rest[0]);
    else new URL(url);
    return true;
  } catch {
    return false;
  }
}

/** Installs the fallback only where the platform lacks `URL.canParse`. */
export function installUrlCanParse(
  target: { canParse?: unknown } = URL as { canParse?: unknown },
) {
  if (typeof target.canParse === 'function') return false;
  Object.defineProperty(target, 'canParse', {
    value: urlCanParse,
    writable: true,
    configurable: true,
  });
  return true;
}
