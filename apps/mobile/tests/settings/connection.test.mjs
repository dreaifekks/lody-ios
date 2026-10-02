import assert from 'node:assert/strict';
import test from 'node:test';
import {
  accountSubtitle,
  connectionSections,
} from '../../src/features/settings/connection.ts';

const machines = [
  {
    id: 'home',
    name: 'homenucserver',
    alias: 'NUC',
    os: 'linux',
    version: '0.103.0',
  },
  { id: 'mac', name: 'MacBook Air', os: 'darwin' },
  { id: 'new' },
];
const live = { state: 'live', machines: 3, syncedAt: 1 };
const sections = (overrides = {}) =>
  connectionSections({
    connection: live,
    syncedAt: 'now',
    machines,
    reach: {},
    error: '',
    accent: '#0A84FF',
    ...overrides,
  });
const rowsOf = (list, id) => list.find((section) => section.id === id).rows;

test('the account row adds the hub latency once it has been measured', () => {
  assert.equal(accountSubtitle('10.0.0.2:8788', undefined), '10.0.0.2:8788');
  assert.match(
    accountSubtitle('10.0.0.2:8788', 12.4),
    /^10\.0\.0\.2:8788 · 12\b/,
  );
  assert.notEqual(accountSubtitle('10.0.0.2:8788', null), '10.0.0.2:8788');
});

test('each computer shows its short name first and how it answered', () => {
  const [home, mac, unnamed] = rowsOf(
    sections({
      reach: { home: { state: 'online', ms: 23 }, mac: { state: 'offline' } },
    }),
    'machines',
  );
  assert.equal(home.id, 'machine:home');
  assert.equal(home.title, 'NUC');
  assert.equal(home.subtitle, 'homenucserver · linux · v0.103.0');
  assert.match(home.value, /\b23\b/);
  assert.equal(home.imageTint, '#0A84FF');

  assert.equal(mac.title, 'MacBook Air');
  assert.equal(mac.subtitle, 'darwin');
  assert.equal(mac.value, undefined);
  assert.equal(mac.valueSegments[0].tint, 'danger');
  assert.equal(mac.accessibilityValue, mac.valueSegments[0].text);

  assert.ok(unnamed.title, 'a computer without a name still gets a title');
  assert.equal(unnamed.subtitle, undefined);
  assert.equal(unnamed.imageTint, 'secondary', 'not yet answered');
});

test('the hub comes first on a LAN and says when it does not answer', () => {
  const lan = sections({
    hub: { name: 'Home', address: '10.0.0.2:8788', latency: null },
  });
  assert.deepEqual(
    lan.map((section) => section.id),
    ['hub', 'sync', 'machines'],
  );
  const [hub] = rowsOf(lan, 'hub');
  assert.equal(hub.imageTint, 'danger');
  assert.equal(hub.valueSegments[0].tint, 'danger');
  assert.deepEqual(
    sections().map((section) => section.id),
    ['sync', 'machines'],
    'Lody Cloud has no hub row',
  );
});

test('a sync that went offline offers a resync, and a failed list a retry', () => {
  const [sync] = rowsOf(
    sections({ connection: { state: 'offline', machines: 0 } }),
    'sync',
  );
  assert.equal(sync.action, true);
  assert.equal(rowsOf(sections(), 'sync')[0].action, false);

  const failed = rowsOf(
    sections({ machines: [], error: 'failed' }),
    'machines',
  );
  assert.deepEqual(
    failed.map((row) => [row.id, row.action]),
    [['retry', true]],
  );
  assert.ok(
    !rowsOf(sections({ error: 'failed' }), 'machines').some(
      (row) => row.id === 'retry',
    ),
    'computers already shown stay without a retry row',
  );
});
