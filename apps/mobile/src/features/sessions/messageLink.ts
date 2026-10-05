import type { Session } from '../../models/catalog.ts';

/** What a link in a message opens; native code opens ordinary web links itself. */
export type MessageLinkAction =
  | { kind: 'session'; session: Session }
  | { kind: 'missingSession' }
  | { kind: 'file'; path: string; line?: number }
  | { kind: 'url'; url: string }
  | { kind: 'loopback' }
  | { kind: 'none' };

const SESSION_PREFIX = 'session://';
// Lody's `parseSessionLinkHref`: session mentions reach the agent, and come
// back from it, as `[@Title](session://<id>)`.
const SESSION_ID = /^[A-Za-z0-9_-]+$/;
const LOOPBACK =
  /^(https?):\/\/(localhost|127\.0\.0\.1|0\.0\.0\.0|\[::1\])(:\d{1,5})?([/?#].*)?$/i;
const FILE = /^file:\/\/(\/[^?#]*)(?:#L(\d+))?/i;

/**
 * Resolves a link the native transcript could not open itself. A loopback
 * address is the machine that runs the session, not this phone: on a LAN it
 * becomes the address that machine has toward the hub.
 */
export function messageLinkAction(
  href: string,
  context: { sessions: Session[]; machineHost?: string },
): MessageLinkAction {
  const value = href.trim();
  if (value.startsWith(SESSION_PREFIX)) {
    const id = value.slice(SESSION_PREFIX.length).replace(/\/+$/, '');
    if (!SESSION_ID.test(id)) return { kind: 'none' };
    const session = context.sessions.find((item) => item.id === id);
    return session ? { kind: 'session', session } : { kind: 'missingSession' };
  }
  const file = FILE.exec(value);
  if (file) {
    let path = file[1];
    try {
      path = decodeURIComponent(path);
    } catch {
      return { kind: 'none' };
    }
    return file[2]
      ? { kind: 'file', path, line: Number(file[2]) }
      : { kind: 'file', path };
  }
  const loopback = LOOPBACK.exec(value);
  if (loopback) {
    const host = context.machineHost?.trim();
    if (!host) return { kind: 'loopback' };
    const authority = host.includes(':') ? `[${host}]` : host;
    return {
      kind: 'url',
      url: `${loopback[1].toLowerCase()}://${authority}${loopback[3] ?? ''}${loopback[4] ?? ''}`,
    };
  }
  return { kind: 'none' };
}
