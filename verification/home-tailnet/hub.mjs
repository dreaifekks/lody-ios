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
import {
  decodeFrames,
  encodeFrame,
} from '../../packages/cloud-runtime/src/frames.ts';

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
      protocolCapabilities: { memoryProviders: 1 },
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
    flock.set(['agentConfig', 'home-agent-two'], {
      id: 'home-agent-two',
      machineId: machine.id,
      name: 'Synthetic Second Agent',
      cliType: 'builtin',
      agentType: 'claude',
    });
    flock.set(['acpCapability', 'builtin:claude'], {
      cliType: 'builtin',
      agentType: 'claude',
      fetchedAt: Date.now(),
      models: [{ modelId: 'synthetic-model', name: 'Synthetic Model' }],
      modes: [{ id: 'agent', name: 'Agent' }],
      configOptions: [],
    });
    flock.set(['memory', 'nowledge-mem', 'home-memory'], {
      machineId: machine.id,
      providerId: 'nowledge-mem',
      memoryId: 'home-memory',
      name: 'Synthetic Memory',
      description: 'Synthetic identity',
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
      {
        id: machine.session + '-delegated',
        role: 'user',
        status: 'handled',
        finished: true,
        author: {
          v: 1,
          kind: 'agent',
          name: 'Planner',
          role: { name: 'iosDev', emoji: '', instanceLabel: 'Mini' },
          model: { id: 'synthetic-model', name: 'GPT' },
        },
        items: [{ type: 'text', text: 'Synthetic author on tailnet.' }],
      },
      {
        id: machine.session + '-board',
        role: 'system',
        status: 'completed',
        finished: true,
        items: [
          {
            itemId: 'batch',
            type: 'operation_completion_batch',
            memberCount: 2,
            members: [
              {
                completion: {
                  type: 'result',
                  value: {
                    items: [{ label: 'Layout check', status: 'succeeded' }],
                  },
                },
              },
              {
                completion: {
                  type: 'result',
                  value: { items: [{ label: 'Wire check', status: 'failed' }] },
                },
              },
            ],
          },
        ],
      },
      {
        id: machine.session + '-link',
        role: 'assistant',
        status: 'completed',
        finished: true,
        items: [
          {
            itemId: 'link',
            type: 'text',
            text: `[Open synthetic session](lody://session/${machines[1].session}?workspace=${workspace})`,
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
  const settings = new Flock('home-synthetic-settings');
  settings.set(['mcpServer', 'home-mcp'], {
    id: 'home-mcp',
    name: 'Synthetic MCP',
    transport: 'http',
    enabledByDefault: false,
    connection: { transport: 'http', url: 'http://127.0.0.1:1/synthetic-mcp' },
  });
  settings.set(['agentRole', 'home-role'], {
    v: 1,
    id: 'home-role',
    ownerUserId: user,
    visibility: 'workspace',
    name: 'Synthetic Role',
    description: 'Synthetic targets',
    promptPrefix: 'Synthetic verification role',
    revision: 1,
    createdAt: Date.now(),
    updatedAt: Date.now(),
    machineId: 'home-mini',
    agentConfigId: 'home-agent',
    instances: [
      {
        id: 'home-instance-mini',
        machineId: 'home-mini',
        agentConfigId: 'home-agent',
        alias: 'Mini First',
      },
      {
        id: 'home-instance-nuc',
        machineId: 'home-nuc',
        agentConfigId: 'home-agent',
        alias: 'Offline NUC',
      },
      {
        id: 'home-instance-mini-two',
        machineId: 'home-mini',
        agentConfigId: 'home-agent-two',
        alias: 'Mini Other',
      },
    ],
  });
  await seedFlock(`${workspace}:wf:workspace`, settings);

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

  const logEvent = ({ event, ...values }) => log(event, values);
  async function finishTurn(params) {
    const client = direct(`${workspace}:s:${params.sessionId}`);
    const data = must(await client.bootstrap({ signal: shutdown.signal }));
    const current = new LoroDoc();
    if (data.snapshotOffset !== '-1' && data.snapshot)
      current.import(data.snapshot.body);
    for (const part of data.updates)
      for (const frame of decodeFrames(part.body)) current.import(frame);
    let tail = data;
    while (!tail.upToDate) {
      tail = must(
        await client.readOnce({
          offset: tail.nextOffset,
          signal: shutdown.signal,
        }),
      );
      if (tail.payload)
        for (const frame of decodeFrames(tail.payload.body))
          current.import(frame);
    }
    const original = current
      .toJSON()
      .history.find((entry) => entry.id === params.userTurnId);
    logEvent({
      event: 'durable_turn_before_dispatch',
      session: params.sessionId,
      userTurnId: params.userTurnId,
      turn: original,
    });
    assert.ok(original, 'dispatch must follow durable history');
    const before = current.version();
    const history = current.getList('history');
    for (let i = 0; i < history.length; i++) {
      const entry = history.get(i);
      if (entry.get('id') === params.userTurnId) {
        entry.set('status', 'handled');
        entry.set('read', true);
        entry.set('finished', true);
      }
    }
    const answer = history.pushContainer(new LoroMap());
    for (const [key, value] of Object.entries({
      id: 'home-answer-' + params.userTurnId,
      role: 'assistant',
      status: 'completed',
      finished: true,
      items: [
        {
          type: 'text',
          text: 'Synthetic machine completed this tailnet turn.',
        },
      ],
    }))
      answer.set(key, value);
    current.commit();
    must(
      await client.append({
        part: {
          contentType: octets.contentType,
          body: encodeFrame(current.export({ mode: 'update', from: before })),
        },
      }),
    );
    logEvent({
      event: 'synthetic_reply_persisted',
      session: params.sessionId,
      userTurnId: params.userTurnId,
    });
  }
  async function rpcResponder(id) {
    let offset = '-1';
    while (!shutdown.signal.aborted) {
      const read = await direct(`${workspace}:rpc:req:${id}`).readOnce({
        offset,
        live: 'long-poll',
        signal: shutdown.signal,
      });
      if (!read.ok) continue;
      offset = read.result.nextOffset;
      if (!read.result.payload) continue;
      const parsed = JSON.parse(
        new TextDecoder().decode(read.result.payload.body),
      );
      for (const request of Array.isArray(parsed) ? parsed : [parsed]) {
        logEvent({ event: 'rpc', machine: id, method: request.method });
        let result;
        if (request.method === 'machine/ping')
          result = { type: 'machine/ping_response', success: true };
        else if (request.method === 'machine/memory')
          result = {
            type: 'machine/memory',
            status: 'ready',
            memories: [
              {
                id: 'home-memory',
                name: 'Synthetic Memory',
                description: 'Synthetic identity',
              },
            ],
          };
        else if (request.method === 'session/dispatch-turn')
          result = { accepted: true };
        else if (request.method === 'local-project/control') {
          const control = request.params.request;
          let value;
          if (
            control.type.includes('list-global-skills') ||
            control.type.includes('list-skills')
          )
            value = {
              groups: [
                {
                  scope: 'project',
                  dir: '.agents/skills',
                  skills: [
                    {
                      name: 'home-skill',
                      relativePath: '.agents/skills/home-skill/SKILL.md',
                      absolutePath:
                        '/tmp/lody-home-fixture/.agents/skills/home-skill/SKILL.md',
                      description: 'Synthetic skill',
                    },
                  ],
                },
              ],
            };
          else if (control.type.includes('list-files'))
            value = { paths: ['README.md'], truncated: false };
          else value = {};
          result = { ok: true, type: control.type, result: value };
        } else result = {};
        must(
          await direct(request.replyTo).append({
            part: {
              contentType: 'application/json',
              body: JSON.stringify({ jsonrpc: '2.0', id: request.id, result }),
            },
          }),
        );
        if (request.method === 'machine/ping')
          log('ping_answered', { machine: id });
        if (request.method === 'session/dispatch-turn')
          await finishTurn(request.params);
      }
    }
  }
  for (const machine of machines.filter((machine) => machine.online)) {
    responders.push(
      rpcResponder(machine.id).catch((error) => {
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
