// Synthetic tailnet entry into an owned loopback loro dev. No real credentials.
import assert from 'node:assert/strict';
import { createHash, randomBytes } from 'node:crypto';
import { spawn } from 'node:child_process';
import { createServer, request as httpRequest } from 'node:http';
import {
  appendFileSync,
  createWriteStream,
  mkdirSync,
  mkdtempSync,
  rmSync,
  writeFileSync,
} from 'node:fs';
import { networkInterfaces } from 'node:os';
import { resolve } from 'node:path';
import { Flock } from '@loro-dev/flock-wasm/base64';
import { StreamsClient } from '@loro-dev/streams-client';
import { EphemeralStore, LoroDoc, LoroMap } from 'loro-crdt/base64';
import { encodeFrame } from '../../packages/cloud-runtime/src/frames.ts';

const host = '100.122.16.85';
assert.ok(
  Object.values(networkInterfaces())
    .flat()
    .some((entry) => entry?.address === host),
  'Run only on the mini with its own tailnet address',
);
const root = resolve('.artifacts/home-tailnet');
mkdirSync(root, { recursive: true });
const privateRoot = mkdtempSync(resolve(root, 'private-'));
const statePath = resolve(root, 'state.json');
const db = resolve(privateRoot, 'hub.sqlite');
const token = randomBytes(24).toString('hex');
const digest = (value) =>
  createHash('sha256').update(value).digest('hex').slice(0, 32);
const workspace = 'lw_' + digest('lody-lan-hub:workspace:' + token);
const user = 'local:' + digest('lody-lan-hub:user:' + token);
const machines = [
  {
    id: 'home-mini',
    name: 'Online Mini',
    alias: 'Mini Online',
    os: 'darwin',
    version: '0.109.0-lan.synthetic',
    online: true,
    project: 'Mini Project',
    session: 'home-mini-session',
    title: 'Mini Tailnet Session',
  },
  {
    id: 'home-nuc',
    name: 'Offline NUC',
    alias: 'NUC Offline',
    os: 'linux',
    version: '0.109.0-lan.synthetic',
    online: false,
    project: 'NUC Project',
    session: 'home-nuc-session',
    title: 'NUC Tailnet Session',
  },
];
const log = (event, fields = {}) =>
  appendFileSync(
    resolve(root, 'events.jsonl'),
    JSON.stringify({ at: new Date().toISOString(), event, ...fields }) + '\n',
  );
const shutdown = new AbortController();
const sockets = new Set();
let heartbeatTimer;
let server;
let presence;
const responders = [];
const stderr = createWriteStream(resolve(root, 'loro-stderr.log'));
const child = spawn(
  process.execPath,
  [
    resolve(root, 'hub-deps/node_modules/@loro-dev/loro-cli/bin/loro.mjs'),
    'dev',
    '--host',
    '127.0.0.1',
    '--port',
    '0',
    '--protocol',
    'http1',
    '--db-path',
    db,
    '--json',
  ],
  { stdio: ['ignore', 'pipe', 'pipe'] },
);
child.stderr.pipe(stderr);
const exited = new Promise((done) => child.once('exit', done));
let stop;
const stopped = new Promise((done) => {
  stop = done;
});
process.once('SIGTERM', stop);
process.once('SIGINT', stop);

try {
  let output = '';
  const backend = await new Promise((fulfill, reject) => {
    child.on('error', reject);
    child.once('exit', (code) =>
      reject(new Error('loro exited ' + code + ': ' + output)),
    );
    child.stdout.on('data', (data) => {
      output += data;
      let json;
      try {
        json = JSON.parse(output);
      } catch {
        return;
      }
      assert.ok(json.ok, output);
      fulfill(json.data.baseUrl);
    });
  });
  assert.equal(new URL(backend).hostname, '127.0.0.1');
  const direct = (stream) =>
    new StreamsClient({
      url: `${backend}/ds/lody/${encodeURIComponent(stream)}`,
      auth: async () => 'synthetic-loopback',
      retry: { maxAttempts: 1 },
      timeout: { connectTimeoutMs: 5000, pollTimeoutMs: 10000 },
    });
  const must = (value) => {
    assert.ok(value.ok, JSON.stringify(value));
    return value.result;
  };
  const octets = { contentType: 'application/octet-stream', ttlSeconds: 3600 };
  async function seedFlock(stream, flock) {
    flock.commit();
    must(await direct(stream).create(octets));
    must(
      await direct(stream).append({
        part: {
          contentType: octets.contentType,
          body: encodeFrame(
            new TextEncoder().encode(JSON.stringify(flock.exportJson())),
          ),
        },
      }),
    );
  }
  assert.equal((await fetch(backend + '/ds/lody', { method: 'PUT' })).ok, true);
  const meta = new Flock('home-synthetic-meta');
  for (const machine of machines) {
    meta.set(['e', 'machine-' + machine.id], true);
    meta.set(['m', 'machine-' + machine.id], {
      name: machine.name,
      lanAlias: machine.alias,
      os: machine.os,
      cliVersion: machine.version,
      ownerUserId: user,
      localProjects: {
        home: {
          name: machine.project,
          rootPath: '/tmp/lody-home-fixture/' + machine.id,
        },
      },
    });
    meta.set(['e', 'session-' + machine.session], true);
    meta.set(['m', 'session-' + machine.session], {
      id: machine.session,
      title: machine.title,
      machineId: machine.id,
      userId: user,
      createdAt: new Date().toISOString(),
      status: { type: 'idle' },
      isArchived: false,
      cliType: 'builtin',
      agentType: 'claude',
      agentConfigId: 'home-agent',
      project: { kind: 'local', localProjectId: 'home' },
    });
    const flock = new Flock('home-synthetic-' + machine.id);
    flock.set(['localProject', 'home'], {
      name: machine.project,
      rootPath: '/tmp/lody-home-fixture/' + machine.id,
    });
    flock.set(['agentConfig', 'home-agent'], {
      id: 'home-agent',
      machineId: machine.id,
      name: 'Synthetic Claude',
      cliType: 'builtin',
      agentType: 'claude',
    });
    await seedFlock(`${workspace}:mf:${machine.id}`, flock);
    must(
      await direct(`${workspace}:rpc:req:${machine.id}`).create({
        contentType: 'application/json',
        ttlSeconds: 3600,
      }),
    );
    const doc = new LoroDoc();
    for (const row of [
      {
        id: machine.session + '-user',
        role: 'user',
        userId: user,
        status: 'handled',
        finished: true,
        items: [{ type: 'text', text: 'Read this synthetic home history.' }],
      },
      {
        id: machine.session + '-assistant',
        role: 'assistant',
        status: 'completed',
        finished: true,
        items: [
          {
            type: 'text',
            text: machine.name + ' synthetic history is readable.',
          },
        ],
      },
    ]) {
      const entry = doc.getList('history').pushContainer(new LoroMap());
      for (const [key, value] of Object.entries(row)) entry.set(key, value);
    }
    doc.commit();
    must(await direct(`${workspace}:s:${machine.session}`).create(octets));
    must(
      await direct(`${workspace}:s:${machine.session}`).append({
        part: {
          contentType: octets.contentType,
          body: encodeFrame(doc.export({ mode: 'update' })),
        },
      }),
    );
  }
  await seedFlock(`${workspace}:meta`, meta);
  await seedFlock(
    `${workspace}:wf:workspace`,
    new Flock('home-synthetic-settings'),
  );

  presence = new EphemeralStore(90_000);
  async function heartbeat() {
    const online = machines.filter((machine) => machine.online);
    for (const machine of online)
      presence.set(machine.id, {
        kind: 'machine',
        machineId: machine.id,
        instanceId: 'synthetic-' + machine.id,
        updatedAt: Date.now(),
      });
    const response = await fetch(
      `${backend}/ds/lody/${encodeURIComponent(workspace + ':meta')}?ephemeral=presence`,
      {
        method: 'POST',
        headers: { 'Content-Type': 'application/octet-stream' },
        body: presence.encodeAll(),
        signal: shutdown.signal,
      },
    );
    assert.equal(response.status, 204);
    log('heartbeat', { online: online.map((machine) => machine.id) });
  }
  await heartbeat();
  heartbeatTimer = setInterval(() => {
    heartbeat().catch((error) => {
      if (!shutdown.signal.aborted)
        log('heartbeat_error', { message: String(error) });
    });
  }, 15_000);

  async function answerPing(machine) {
    let offset = '-1';
    while (!shutdown.signal.aborted) {
      const read = must(
        await direct(`${workspace}:rpc:req:${machine.id}`).readOnce({
          offset,
          live: 'long-poll',
          signal: shutdown.signal,
        }),
      );
      offset = read.nextOffset;
      if (!read.payload) continue;
      const parsed = JSON.parse(new TextDecoder().decode(read.payload.body));
      for (const request of Array.isArray(parsed) ? parsed : [parsed]) {
        log('rpc', { machine: machine.id, method: request.method });
        if (request.method !== 'machine/ping') continue;
        must(
          await direct(request.replyTo).append({
            part: {
              contentType: 'application/json',
              body: JSON.stringify({
                jsonrpc: '2.0',
                id: request.id,
                result: { success: true },
              }),
            },
          }),
        );
        log('ping_answered', { machine: machine.id });
      }
    }
  }
  for (const machine of machines.filter((machine) => machine.online)) {
    responders.push(
      answerPing(machine).catch((error) => {
        if (!shutdown.signal.aborted)
          log('rpc_error', { message: String(error) });
      }),
    );
  }

  server = createServer((req, res) => {
    if (req.headers.authorization !== 'Bearer ' + token) {
      res.writeHead(401).end();
      return;
    }
    if (!req.url.startsWith('/ds/')) {
      res.writeHead(404).end();
      return;
    }
    const started = Date.now();
    const headers = { ...req.headers, host: new URL(backend).host };
    delete headers.authorization;
    const proxy = httpRequest(
      backend + req.url,
      { method: req.method, headers },
      (upstream) => {
        log('http', {
          method: req.method,
          path: req.url,
          status: upstream.statusCode,
          elapsedMs: Date.now() - started,
          sseEncoding: upstream.headers['stream-sse-data-encoding'],
        });
        res.writeHead(upstream.statusCode, upstream.headers);
        upstream.pipe(res);
      },
    );
    proxy.on('error', (error) => {
      if (!shutdown.signal.aborted) log('proxy_error', { code: error.code });
      if (!res.headersSent) res.writeHead(502);
      res.end();
    });
    res.on('close', () => proxy.destroy());
    req.pipe(proxy);
  });
  server.on('connection', (socket) => {
    sockets.add(socket);
    socket.on('close', () => sockets.delete(socket));
  });
  await new Promise((done) => server.listen(0, host, done));
  const base = `http://${host}:${server.address().port}`;
  writeFileSync(
    statePath,
    JSON.stringify(
      {
        pid: process.pid,
        childPid: child.pid,
        backend,
        base,
        workspace,
        user,
        invite: `lody-lan://${token}@${host}:${server.address().port}/Home%20Synthetic`,
        machines,
        ready: true,
      },
      null,
      2,
    ),
    { mode: 0o600 },
  );
  writeFileSync(
    resolve(root, 'seed.json'),
    JSON.stringify({ base, workspace, machines }, null, 2),
  );
  log('ready', {
    base,
    workspace,
    machines: machines.map((machine) => ({
      id: machine.id,
      online: machine.online,
    })),
  });
  console.log(JSON.stringify({ ready: true, base, statePath }));
  await stopped;
} finally {
  clearInterval(heartbeatTimer);
  shutdown.abort();
  for (const socket of sockets) socket.destroy();
  server?.close();
  child.kill('SIGTERM');
  await exited;
  await Promise.allSettled(responders);
  presence?.destroy();
  rmSync(statePath, { force: true });
  rmSync(privateRoot, { recursive: true, force: true });
  log('stopped', { credentialsAndDatabaseRemoved: true });
}
