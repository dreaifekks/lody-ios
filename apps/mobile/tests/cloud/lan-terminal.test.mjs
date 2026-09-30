import assert from 'node:assert/strict';
import test from 'node:test';

test('machine metadata publishes a LAN terminal endpoint only in the version this app speaks', async () => {
  const { projectRows, lanTerminalEndpoint } =
    await import('../../src/cloud/catalog/model.ts');
  const rows = [
    { key: ['e', 'machine-m1'], value: true },
    {
      key: ['m', 'machine-m1'],
      value: {
        name: 'homenucserver',
        lanTerminal: { version: 1, host: '100.64.0.2', port: 8789 },
      },
    },
    { key: ['e', 'machine-m2'], value: true },
    {
      key: ['m', 'machine-m2'],
      value: {
        name: 'future',
        lanTerminal: { version: 2, host: 'h', port: 1 },
      },
    },
    { key: ['e', 'machine-m3'], value: true },
    { key: ['m', 'machine-m3'], value: { name: 'cloud' } },
  ];
  const catalog = projectRows(rows, 'meta');
  assert.deepEqual(catalog.machineTerminals, {
    m1: { host: '100.64.0.2', port: 8789 },
  });

  // A field update moves the endpoint; a withdrawn one leaves no entry.
  const moved = projectRows(
    [
      ...rows,
      {
        key: ['m', 'machine-m1', 'lanTerminal'],
        value: { version: 1, host: '192.168.1.13', port: 40001 },
      },
    ],
    'meta',
  );
  assert.deepEqual(moved.machineTerminals.m1, {
    host: '192.168.1.13',
    port: 40001,
  });
  const withdrawn = projectRows(
    [...rows, { key: ['m', 'machine-m1', 'lanTerminal'], value: undefined }],
    'meta',
  );
  assert.equal(withdrawn.machineTerminals, undefined);

  for (const invalid of [
    null,
    { version: 1, host: ' ', port: 8789 },
    { version: 1, host: 'h', port: 0 },
    { version: 1, host: 'h', port: 65_536 },
    { version: 1, host: 'h', port: 1.5 },
    { version: 1, host: 'x'.repeat(256), port: 1 },
  ])
    assert.equal(lanTerminalEndpoint(invalid), undefined);
});
