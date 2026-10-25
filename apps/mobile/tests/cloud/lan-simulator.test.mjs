import assert from 'node:assert/strict';
import test from 'node:test';
import { build } from 'esbuild';

const member = (id, value) => [
  { key: ['e', `machine-${id}`], value: true },
  { key: ['m', `machine-${id}`], value },
];
const endpoint = { version: 1, host: '100.64.0.2', port: 8789 };

test('a LAN Mac that publishes an endpoint offers its simulators by capability', async () => {
  const { projectRows } = await import('../../src/cloud/catalog/model.ts');
  const catalog = projectRows(
    [
      ...member('ready', {
        os: 'darwin',
        lanTerminal: endpoint,
        protocolCapabilities: { iosSimulator: 1, lanIosSimulator: 1 },
      }),
      ...member('old', {
        os: 'darwin',
        lanTerminal: endpoint,
        protocolCapabilities: { iosSimulator: 1 },
      }),
      ...member('linux', {
        os: 'linux',
        lanTerminal: endpoint,
        protocolCapabilities: { lanIosSimulator: 1 },
      }),
      ...member('cloud', {
        os: 'darwin',
        protocolCapabilities: { iosSimulator: 1, lanIosSimulator: 1 },
      }),
    ],
    'meta',
  );
  assert.deepEqual(catalog.machineLanSimulators, {
    ready: 'available',
    old: 'upgrade-required',
  });
  const cloud = projectRows(
    member('cloud', {
      os: 'darwin',
      protocolCapabilities: { iosSimulator: 1 },
    }),
    'meta',
  );
  assert.equal(cloud.machineLanSimulators, undefined);
});

test('on a LAN the member that runs the session serves its simulators', async () => {
  const { sessionSimulatorAvailability } =
    await import('../../src/features/simulator/availability.ts');
  const catalog = {
    machineSimulators: { m1: 'available' },
    machineLanSimulators: { m1: 'available', m2: 'upgrade-required' },
    machineTerminals: {
      m1: { host: '100.64.0.2', port: 8789 },
      m2: { host: 'h', port: 1 },
    },
  };
  const session = { machineId: 'm1', archived: false };
  assert.deepEqual(sessionSimulatorAvailability(catalog, session, undefined), {
    availability: 'available',
  });
  assert.deepEqual(sessionSimulatorAvailability(catalog, session, 'lw_x'), {
    availability: 'available',
    lan: {
      workspaceId: 'lw_x',
      machineId: 'm1',
      host: '100.64.0.2',
      port: 8789,
    },
  });
  assert.equal(
    sessionSimulatorAvailability(
      catalog,
      { machineId: 'm2', archived: false },
      'lw_x',
    ).availability,
    'upgrade-required',
  );
  // The member refuses an archived session, and one without an endpoint cannot be reached.
  assert.deepEqual(
    sessionSimulatorAvailability(
      catalog,
      { ...session, archived: true },
      'lw_x',
    ),
    {},
  );
  assert.deepEqual(
    sessionSimulatorAvailability(
      { ...catalog, machineTerminals: {} },
      session,
      'lw_x',
    ),
    {},
  );
});

test('a LAN session asks its member natively; leaving releases the port and forgets the operation', async () => {
  const calls = [];
  globalThis.__simulatorKit = {
    iosSimulatorControl: async (workspaceId, sessionId, command) => {
      calls.push(['cloud', sessionId, command.action]);
      return { success: true };
    },
    lanSimulatorControl: async (target, sessionId, command) => {
      calls.push(['lan', target.machineId, sessionId, command.action]);
      return {
        success: true,
        preview: {
          operationId: 'op-1',
          udid: 'u1',
          phase: 'ready',
          transport: 'local',
          viewerUrl:
            'http://127.0.0.1:53610/simulator/x/?__lody_preview_token=t',
        },
      };
    },
    lanSimulatorRelease: async (sessionId) =>
      calls.push(['release', sessionId]),
  };
  const bundle = await build({
    entryPoints: [
      new URL('../../src/features/simulator/operations.ts', import.meta.url)
        .pathname,
    ],
    bundle: true,
    format: 'esm',
    write: false,
    plugins: [
      {
        name: 'kit',
        setup(b) {
          b.onResolve({ filter: /^(react|@lody-ios\/kit)$/ }, ({ path }) => ({
            path,
            namespace: 'mock',
          }));
          b.onLoad({ filter: /.*/, namespace: 'mock' }, ({ path }) => ({
            contents: {
              react: 'export const useSyncExternalStore = () => undefined;',
              '@lody-ios/kit':
                'export const {iosSimulatorControl,lanSimulatorControl,lanSimulatorRelease}=globalThis.__simulatorKit;',
            }[path],
          }));
        },
      },
    ],
  });
  const operations = await import(
    `data:text/javascript;base64,${Buffer.from(bundle.outputFiles[0].text).toString('base64')}`
  );
  const target = {
    workspaceId: 'lw_x',
    machineId: 'm1',
    host: 'h',
    port: 8789,
  };
  const release = operations.attachLanSimulator('s1', target);
  const started = await operations.startSimulator('lw_x', 's1', {
    udid: 'u1',
    name: 'iPhone',
  });
  assert.equal(started.phase, 'ready');
  assert.equal(
    operations.simulatorSource(started)?.url,
    'http://127.0.0.1:53610/simulator/x/?__lody_preview_token=t',
  );
  await operations.simulatorControl('lw_x', 's2', { action: 'list' });
  assert.deepEqual(calls, [
    ['lan', 'm1', 's1', 'start'],
    ['cloud', 's2', 'list'],
  ]);

  // A stale release from a replaced target leaves the current one attached.
  const next = { ...target, port: 9000 };
  const releaseNext = operations.attachLanSimulator('s1', next);
  release();
  await operations.simulatorControl('lw_x', 's1', { action: 'status' });
  assert.deepEqual(calls.at(-1), ['lan', 'm1', 's1', 'status']);

  calls.length = 0;
  releaseNext();
  await new Promise((resolve) => setImmediate(resolve));
  assert.deepEqual(calls, [['release', 's1']]);
  // The member keeps the operation; this device forgot it with the port.
  await operations.stopSimulator('s1');
  assert.deepEqual(calls, [['release', 's1']]);
  await operations.simulatorControl('lw_x', 's1', { action: 'list' });
  assert.deepEqual(calls.at(-1), ['cloud', 's1', 'list']);
});
