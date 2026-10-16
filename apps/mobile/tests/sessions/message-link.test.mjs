import assert from 'node:assert/strict';
import test from 'node:test';
import { messageLinkAction } from '../../src/features/sessions/messageLink.ts';

const sessions = [{ id: 'abc_123', title: 'Other session' }];

test('public session links accept every desktop scheme and fence the workspace', () => {
  const context = { sessions, workspaceId: 'w1' };
  for (const scheme of [
    'lody',
    'ai.lody.stable',
    'ai.lody.nightly',
    'lody-oss',
  ]) {
    for (const query of ['', '?workspace=w1', '?']) {
      assert.deepEqual(
        messageLinkAction(`${scheme}://session/abc_123${query}`, context),
        {
          kind: 'session',
          session: sessions[0],
        },
      );
    }
    assert.equal(
      messageLinkAction(`${scheme}://session/abc_123?workspace=w2`, context)
        .kind,
      'missingSession',
    );
    assert.equal(
      messageLinkAction(`${scheme}://session/missing`, context).kind,
      'missingSession',
    );
  }
  // A legacy tab names the actual child session; the phone opens it directly.
  assert.deepEqual(
    messageLinkAction('lody://session/root?tab=abc_123&workspace=w1', context),
    {
      kind: 'session',
      session: sessions[0],
    },
  );
  assert.equal(
    messageLinkAction('lody://session/abc_123?tab=missing', context).kind,
    'missingSession',
  );
  assert.equal(
    messageLinkAction('LODY://session/abc_123', context).kind,
    'session',
  );
});

test('session links reject normalization, escaping and ambiguous query parameters like Lody', () => {
  for (const href of [
    ' lody://session/abc_123',
    'lody://session/abc_123 ',
    'lody://session/abc_\n123',
    'lody://session/abc_123\\',
    'lody://session/%61bc_123',
    'lody://session/abc_123?workspace=%77',
    'lody://session/other/../abc_123',
    'lody://session/./abc_123',
    'lody://session/abc_123/',
    'lody://session/abc_123/child',
    'lody://session/',
    'lody://session/abc_123#fragment',
    'lody://session/abc_123?unknown=x',
    'lody://session/abc_123?workspace=',
    'lody://session/abc_123?workspace=w1&workspace=w1',
    'lody://session/abc_123?tab=abc_123&tab=abc_123',
    'lody://session/abc_123?tab=',
    'lody://session/abc_123?tab=a/b',
    'lody://session/abc_123?workspace=a+b',
    'lody://user@session/abc_123',
    'lody://session:123/abc_123',
    'lody://SESSION/abc_123',
    'unknown://session/abc_123',
    'session://abc_123//',
    'session://abc_123?workspace=w1',
    'session://abc_123#x',
    'session://abc_123 ',
    'session://%61bc_123',
    `lody://session/${'a'.repeat(8192)}`,
  ]) {
    assert.equal(
      messageLinkAction(href, { sessions, workspaceId: 'w1' }).kind,
      'none',
      href,
    );
  }
});

test('a session mention opens that session, and one outside the catalog says so', () => {
  assert.deepEqual(
    messageLinkAction('session://abc_123', { sessions, workspaceId: 'w1' }),
    {
      kind: 'session',
      session: sessions[0],
    },
  );
  assert.equal(
    messageLinkAction('session://abc_123/', { sessions, workspaceId: 'w1' })
      .kind,
    'session',
  );
  assert.equal(
    messageLinkAction('session://gone', { sessions, workspaceId: 'w1' }).kind,
    'missingSession',
  );
  assert.equal(
    messageLinkAction('session://../etc', { sessions, workspaceId: 'w1' }).kind,
    'none',
  );
});

test('a file URL opens the file, with its line', () => {
  assert.deepEqual(
    messageLinkAction('file:///Users/me/app%20dir/main.ts#L42', {
      sessions,
      workspaceId: 'w1',
    }),
    { kind: 'file', path: '/Users/me/app dir/main.ts', line: 42 },
  );
  assert.deepEqual(
    messageLinkAction('file:///tmp/a.log', { sessions, workspaceId: 'w1' }),
    {
      kind: 'file',
      path: '/tmp/a.log',
    },
  );
});

test('a loopback address is the session machine, reached at its LAN address', () => {
  assert.deepEqual(
    messageLinkAction('http://localhost:5173/app?x=1#top', {
      sessions,
      workspaceId: 'w1',
      machineHost: '100.64.0.7',
    }),
    { kind: 'url', url: 'http://100.64.0.7:5173/app?x=1#top' },
  );
  assert.deepEqual(
    messageLinkAction('HTTPS://127.0.0.1', {
      sessions,
      workspaceId: 'w1',
      machineHost: 'fd7a::7',
    }),
    { kind: 'url', url: 'https://[fd7a::7]' },
  );
  assert.equal(
    messageLinkAction('http://[::1]:3000/', { sessions, workspaceId: 'w1' })
      .kind,
    'loopback',
  );
  // Not loopback: another host whose name only starts like one.
  assert.equal(
    messageLinkAction('http://localhost.example.com/', {
      sessions,
      workspaceId: 'w1',
      machineHost: '100.64.0.7',
    }).kind,
    'none',
  );
  assert.equal(
    messageLinkAction('lody://unknown', { sessions, workspaceId: 'w1' }).kind,
    'none',
  );
});
