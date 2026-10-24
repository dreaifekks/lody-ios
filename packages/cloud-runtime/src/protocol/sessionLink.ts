// Lody public session-link grammar, shared by message navigation and mentions.
/** Public resource links are independent of the installed desktop channel. */
export type SessionLink = {
  sessionId: string;
  workspaceId?: string;
  /** Legacy read compatibility only; new links address this ID directly. */
  tabSessionId?: string;
};

const ID = /^[A-Za-z0-9_-]+$/u;
const SCHEMES = new Set([
  'lody:',
  'ai.lody.stable:',
  'ai.lody.nightly:',
  'lody-oss:',
]);

export function buildSessionLink(target: SessionLink): string {
  for (const value of [
    target.sessionId,
    target.workspaceId,
    target.tabSessionId,
  ]) {
    if (value !== undefined && !ID.test(value))
      throw new Error('Invalid session link identifier');
  }
  const query = new URLSearchParams();
  if (target.workspaceId) query.set('workspace', target.workspaceId);
  const sessionId = target.tabSessionId ?? target.sessionId;
  const url = `lody://session/${sessionId}${query.size ? `?${query}` : ''}`;
  if (url.length > 8192) throw new Error('Session link is too long');
  return url;
}

/** Read old transcripts without ever registering the generic session scheme. */
export function parseSessionLink(raw: string): SessionLink | null {
  if (raw.length > 8192 || /[\s\\%]/u.test(raw)) return null;
  const legacy = /^session:\/\/([A-Za-z0-9_-]+)\/?$/u.exec(raw);
  if (legacy) return { sessionId: legacy[1]! };
  // Reject path normalization (e.g. /other/../id) before URL can erase it.
  if (!/^[a-zA-Z.-]+:\/\/session\/[A-Za-z0-9_-]+(?:\?[^#]*)?$/u.test(raw))
    return null;
  let url: URL;
  try {
    url = new URL(raw);
  } catch {
    return null;
  }
  if (
    !SCHEMES.has(url.protocol) ||
    url.hostname !== 'session' ||
    url.port ||
    url.username ||
    url.password
  )
    return null;
  const sessionId = url.pathname.slice(1);
  if (!ID.test(sessionId)) return null;
  for (const key of url.searchParams.keys()) {
    if (key !== 'workspace' && key !== 'tab') return null;
    if (
      url.searchParams.getAll(key).length !== 1 ||
      !ID.test(url.searchParams.get(key) ?? '')
    )
      return null;
  }
  return {
    sessionId,
    ...(url.searchParams.has('workspace')
      ? { workspaceId: url.searchParams.get('workspace')! }
      : {}),
    ...(url.searchParams.has('tab')
      ? { tabSessionId: url.searchParams.get('tab')! }
      : {}),
  };
}
