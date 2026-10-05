import assert from 'node:assert/strict';
import test from 'node:test';
import { messageLinkAction } from '../../src/features/sessions/messageLink.ts';

const sessions = [{ id: 'abc_123', title: 'Other session' }];

test('a session mention opens that session, and one outside the catalog says so', () => {
  assert.deepEqual(messageLinkAction('session://abc_123', { sessions }), {
    kind: 'session',
    session: sessions[0],
  });
  assert.equal(
    messageLinkAction('session://abc_123/', { sessions }).kind,
    'session',
  );
  assert.equal(
    messageLinkAction('session://gone', { sessions }).kind,
    'missingSession',
  );
  assert.equal(
    messageLinkAction('session://../etc', { sessions }).kind,
    'none',
  );
});

test('a file URL opens the file, with its line', () => {
  assert.deepEqual(
    messageLinkAction('file:///Users/me/app%20dir/main.ts#L42', { sessions }),
    { kind: 'file', path: '/Users/me/app dir/main.ts', line: 42 },
  );
  assert.deepEqual(messageLinkAction('file:///tmp/a.log', { sessions }), {
    kind: 'file',
    path: '/tmp/a.log',
  });
});

test('a loopback address is the session machine, reached at its LAN address', () => {
  assert.deepEqual(
    messageLinkAction('http://localhost:5173/app?x=1#top', {
      sessions,
      machineHost: '100.64.0.7',
    }),
    { kind: 'url', url: 'http://100.64.0.7:5173/app?x=1#top' },
  );
  assert.deepEqual(
    messageLinkAction('HTTPS://127.0.0.1', {
      sessions,
      machineHost: 'fd7a::7',
    }),
    { kind: 'url', url: 'https://[fd7a::7]' },
  );
  assert.equal(
    messageLinkAction('http://[::1]:3000/', { sessions }).kind,
    'loopback',
  );
  // Not loopback: another host whose name only starts like one.
  assert.equal(
    messageLinkAction('http://localhost.example.com/', {
      sessions,
      machineHost: '100.64.0.7',
    }).kind,
    'none',
  );
  assert.equal(messageLinkAction('lody://unknown', { sessions }).kind, 'none');
});
