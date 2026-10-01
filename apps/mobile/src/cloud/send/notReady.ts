/** A send refused before anything was written waits this long, then goes again by itself. */
export const RETRY_PAUSE_MS = 1500;
/** A session may fail to open this many times in a row before its send is handed back. */
export const MAX_OPEN_FAILURES = 3;

/** The runtime was still connecting: nothing reached the hub, so no retry can duplicate. */
export function notReady(result: { reason?: string; retryable?: boolean }) {
  return (
    result.retryable === true ||
    result.reason === 'session_not_ready' ||
    result.reason === 'metadata_not_ready'
  );
}

export const pause = () =>
  new Promise<void>((resolve) => setTimeout(resolve, RETRY_PAUSE_MS));

const openFailures = new Map<string, number>();
export function sessionOpened(sendId: string) {
  openFailures.delete(sendId);
}
/** Counts a failed open; true while the send should still wait for the session. */
export function sessionOpenFailed(sendId: string) {
  const failures = (openFailures.get(sendId) ?? 0) + 1;
  if (failures < MAX_OPEN_FAILURES) {
    openFailures.set(sendId, failures);
    return true;
  }
  openFailures.delete(sendId);
  return false;
}
