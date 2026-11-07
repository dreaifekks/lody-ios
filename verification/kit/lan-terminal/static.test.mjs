import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import {
  projectRows,
  lanTerminalEndpoint,
} from '../../../packages/cloud-runtime/src/protocol/catalog.ts';

const read = (path) =>
  readFileSync(new URL(`../../../${path}`, import.meta.url), 'utf8');

test('published terminal metadata is required; bad or removed endpoints are excluded', () => {
  const rows = (endpoint, active = true) => [
    { key: ['e', 'machine-m'], value: active },
    {
      key: ['m', 'machine-m'],
      value: { name: 'Member', lanTerminal: endpoint },
    },
  ];
  const good = { version: 1, host: '127.0.0.1', port: 8789 };
  assert.deepEqual(projectRows(rows(good), 'meta').machineTerminals, {
    m: { host: good.host, port: good.port },
  });
  for (const endpoint of [
    undefined,
    {},
    { ...good, version: 2 },
    { ...good, host: '' },
    { ...good, port: 0 },
    { ...good, port: 65536 },
    { ...good, port: 1.5 },
  ]) {
    assert.equal(lanTerminalEndpoint(endpoint), undefined);
    assert.equal(
      projectRows(rows(endpoint), 'meta').machineTerminals,
      undefined,
    );
  }
  assert.equal(
    projectRows(rows(good, false), 'meta').machineTerminals,
    undefined,
  );
  assert.equal(
    projectRows(rows(good), 'other-machine').machineTerminals,
    undefined,
  );
});

test('scoped terminal PSK matches the desktop vector', () => {
  assert.equal(
    createHash('sha256')
      .update('lody-lan-hub:terminal:test-token')
      .digest('hex'),
    '8e4b7e3db4777d2f72d036c7b68a30f482c673f14507c4f71c790662391d1f59',
  );
});

test('native boundary and fixed assets are present (static evidence only)', () => {
  const link = read('packages/LodyData/Sources/LAN/LanTerminalLink.swift');
  assert.doesNotMatch(
    link,
    /(?:enum LanTerminalProtocol|struct LanTerminalEndpoint)/,
  );
  const tls = read('packages/LodyData/Sources/LAN/LanMemberProtocol.swift');
  assert.match(tls, /set_tls_resumption_enabled\(security, false\)/);
  assert.match(tls, /set_max_tls_protocol_version\(security, \.TLSv12\)/);
  assert.match(tls, /set_min_tls_protocol_version\(security, \.TLSv12\)/);
  assert.match(read('project.yml'), /SwiftTerm:[\s\S]*?exactVersion: 1\.19\.0/);
  for (const font of ['Regular', 'Bold']) {
    const path = `iOS/Resources/Fonts/MesloLGS-NF-${font}.ttf`;
    assert.ok(
      readFileSync(new URL(`../../../${path}`, import.meta.url)).length >
        1000000,
    );
    assert.ok(read('iOS/Info.plist').includes(`MesloLGS-NF-${font}.ttf`));
  }
  for (const license of ['MesloLGS-NF', 'SwiftTerm'])
    assert.ok(
      read(`iOS/Resources/Licenses/${license}-LICENSE.txt`).length > 500,
    );
});
