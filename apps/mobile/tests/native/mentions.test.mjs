import assert from 'node:assert/strict';
import test from 'node:test';
import { build } from 'esbuild';
import { openTestSession } from '../helpers.mjs';

const bundle = await build({
  stdin: {
    contents:
      "export * from './mentions'; export * from './mention-expansion'; export * from './agent-roles';",
    resolveDir: new URL('../../modules/lody-kit/data-runtime/', import.meta.url)
      .pathname,
    loader: 'ts',
  },
  bundle: true,
  format: 'esm',
  platform: 'browser',
  write: false,
});
const mentions = await import(
  `data:text/javascript;base64,${Buffer.from(bundle.outputFiles[0].text).toString('base64')}`
);
const skill = {
  path: '/home/My Skills/auth)/SKILL.md',
  name: 'auth',
  kind: 'skill',
  subtitle: '',
  insertText: '$auth',
};
const session = {
  path: 's2',
  name: 'Other conversation',
  kind: 'session',
  subtitle: '',
  insertText: '@session:s2',
};
const role = {
  path: 'reviewer-claude',
  name: 'Reviewer',
  kind: 'role',
  subtitle: '',
  insertText: '@role:reviewer-claude',
  role: { id: 'reviewer', name: 'Reviewer', instance: 'Claude Code' },
};
const items = [skill, session, role];
const load = async (category) => ({
  items: items.filter((item) => item.kind === category),
  truncated: false,
  incomplete: false,
});
const text =
  '@src/file.ts $auth @session:s2 @role:reviewer-claude #11 #12 /compact';
// OSS mention-skill/session/agent-role-source prompt formats, not copied tables.
const expected =
  '@src/file.ts use /auth [Skill Path](/home/My Skills/auth\\)/SKILL.md) use lody mcp to query session[id: s2] history use lody mcp to create a session with agent role[id: reviewer, instance: reviewer-claude, name: Reviewer · Claude Code] #11 #12 /compact';

test('send expansion matches OSS prompts; paths, GitHub references and commands remain verbatim', async () => {
  assert.equal(await mentions.expandMentions(text, load), expected);
  assert.equal(
    mentions.expandMentionText(expected, items),
    expected,
    'Re-sending an expanded prompt must be idempotent',
  );
  assert.equal(
    mentions.expandMentionText('@"src/My $auth File.ts"', items),
    '@"src/My $auth File.ts"',
    'A quoted file path must not turn into a skill instruction',
  );
  assert.equal(
    mentions.expandMentionText(
      '$unknown @session:deleted @role:deleted',
      items,
    ),
    '$unknown @session:deleted @role:deleted',
  );
  assert.equal(
    mentions.expandMentionText('$auth [Skill Path](already)', items),
    '$auth [Skill Path](already)',
  );
  assert.equal(
    await mentions.expandMentions('/compact #12 @src/file.ts', () => {
      throw new Error('Verbatim references must not load a catalog');
    }),
    '/compact #12 @src/file.ts',
  );
  assert.throws(
    () =>
      mentions.expandMentionText('$auth', [
        skill,
        { ...skill, path: '/another/SKILL.md' },
      ]),
    /ambiguous_mention/,
  );
});

test('partial discovery cannot expand a global skill while its project override is unavailable', async () => {
  for (const flag of ['incomplete', 'truncated']) {
    await assert.rejects(
      mentions.expandMentions('$auth', async () => ({
        ...(await load('skill')),
        [flag]: true,
      })),
      /mention_expansion_failed/,
    );
  }
});

test('workspace sessions exclude self, prefer unarchived entries, and retain stable ids through renames', () => {
  const fixture = (id, archived, createdAt) => ({
    id,
    title: id,
    archived,
    createdAt,
    projectId: 'p',
    machineId: 'm',
  });
  const result = mentions.sessionMentions(
    [
      fixture('self', false, '2026-09-11'),
      fixture('old', true, '2026-09-12'),
      fixture('active', false, '2026-09-10'),
    ],
    [{ id: 'p', name: 'Project' }],
    'self',
  );
  assert.deepEqual(
    result.items.map((item) => item.path),
    ['active', 'old'],
  );
  assert.equal(result.items[0].subtitle, 'Project');
  assert.equal(
    mentions.expandMentionText('@session:active', [
      { ...result.items[0], name: 'Renamed' },
    ]),
    'use lody mcp to query session[id: active] history',
  );
  assert.equal(mentions.sessionMentions([], []).items.length, 0);
  assert.equal(
    mentions.sessionMentions([fixture('first', false, '')], []).items.length,
    1,
    'CreateSession has no current id to exclude',
  );
});

test('skill references keep project precedence and expand the correct scope path', () => {
  const result = mentions.skillMentions([
    {
      groups: [
        {
          scope: 'global',
          dir: '~/.agents/skills',
          skills: [
            {
              name: 'auth',
              absolutePath: '/home/.agents/skills/auth/SKILL.md',
              relativePath: '.agents/skills/auth/SKILL.md',
            },
          ],
        },
        {
          scope: 'project',
          dir: '.agents/skills',
          skills: [
            {
              name: 'Authentication review',
              absolutePath: '/repo/.agents/skills/auth/SKILL.md',
              relativePath: '.agents/skills/auth/SKILL.md',
            },
          ],
        },
      ],
    },
  ]);
  assert.equal(result.items.length, 1);
  assert.equal(result.items[0].insertText, '$auth');
  assert.equal(
    mentions.expandMentionText('$auth', result.items),
    'use /auth [Skill Path](.agents/skills/auth/SKILL.md)',
  );
});

test('Role references filter private rows and invalid machine bindings before expansion', () => {
  const agents = new Map(
    ['m', 'unnamed-machine'].map((machineId) => [
      machineId,
      {
        get: (key) =>
          key[1] === 'a' ? { id: 'a', machineId, name: 'Agent' } : undefined,
      },
    ]),
  );
  const row = (id, patch = {}) => ({
    key: ['agentRole', id],
    value: {
      v: 1,
      id,
      name: id,
      ownerUserId: 'me',
      visibility: 'private',
      machineId: 'm',
      agentConfigId: 'a',
      revision: 1,
      ...patch,
    },
  });
  const rows = [
    row('own'),
    row('shared', { ownerUserId: 'them', visibility: 'workspace' }),
    row('private', { ownerUserId: 'them' }),
    row('deleted-agent', { agentConfigId: 'missing' }),
    row('other-machine', { machineId: 'other' }),
    row('far', { machineId: 'unnamed-machine' }),
  ];
  const result = mentions.roleMentions(rows, 'me', agents, new Map(), 'm');
  assert.deepEqual(
    result.items.map((item) => [item.path, item.name]),
    [
      ['own:m', 'own'],
      ['shared:m', 'shared'],
      ['far:unnamed-machine', 'far · unnamed-'],
    ],
    'A row written before instances is one instance under the id Lody derives; a machine without a name is told by the start of its id',
  );
  assert.equal(
    mentions.expandMentionText('@role:private:m', result.items),
    '@role:private:m',
  );
  assert.equal(
    mentions.expandMentionText('@role:own:m', result.items),
    'use lody mcp to create a session with agent role[id: own, instance: own:m, name: own · Agent]',
  );
});

test('a Role lists every instance group, the composer’s machine first and an entry elsewhere by its machine', () => {
  const config = (machineId, id, patch = {}) => [
    `${machineId}/${id}`,
    { id, machineId, name: id, cliType: 'builtin', agentType: id, ...patch },
  ];
  const configs = new Map([
    config('mac', 'claude'),
    config('mac', 'codex'),
    config('mac', 'deepseek', {
      agentType: 'claude',
      name: 'DeepSeek',
      env: { ANTHROPIC_BASE_URL: 'https://api.deepseek.com/anthropic' },
    }),
    config('mac', 'gemini', {
      cliType: 'registry',
      agentType: 'antigravity-acp',
      name: 'Gemini',
    }),
    config('nuc', 'claude'),
  ]);
  const machines = new Map(
    ['mac', 'nuc'].map((machineId) => [
      machineId,
      { get: (key) => configs.get(`${machineId}/${key[1]}`) },
    ]),
  );
  const instance = (id, machineId, agentConfigId, alias) => ({
    id,
    machineId,
    agentConfigId,
    runConfig: {},
    ...(alias ? { alias } : {}),
  });
  const row = (id, instances) => ({
    key: ['agentRole', id],
    value: {
      v: 1,
      id,
      name: id,
      ownerUserId: 'me',
      visibility: 'private',
      // The mirror of the first instance, which is all an older client reads.
      machineId: instances[0].machineId,
      agentConfigId: instances[0].agentConfigId,
      revision: 1,
      instances,
    },
  });
  const rows = [
    row('moa', [
      instance('moa-nuc', 'nuc', 'claude'),
      instance('moa-mac', 'mac', 'claude'),
      instance('moa-codex', 'mac', 'codex'),
      instance('moa-deepseek', 'mac', 'deepseek'),
      instance('moa-fable', 'mac', 'claude', 'Fable'),
      instance('moa-gemini', 'mac', 'gemini'),
      instance('moa-gone', 'mac', 'deleted'),
      instance('moa-mac', 'mac', 'codex'),
    ]),
    row('solo', [instance('solo-nuc', 'nuc', 'claude')]),
    row('alpha', [instance('alpha-nuc', 'nuc', 'claude')]),
  ];
  const names = new Map([
    ['mac', 'MacBook'],
    ['nuc', 'Home NUC'],
  ]);
  const listed = (machineId) =>
    mentions
      .roleMentions(rows, 'me', machines, names, machineId)
      .items.map((item) => [item.path, item.name]);
  assert.deepEqual(
    listed('mac'),
    [
      ['moa-mac', 'moa · Claude Code'],
      ['moa-codex', 'moa · Codex'],
      ['moa-deepseek', 'moa · DeepSeek'],
      ['moa-fable', 'moa · Fable'],
      ['moa-gemini', 'moa · Gemini'],
      ['alpha-nuc', 'alpha · Home NUC'],
      ['solo-nuc', 'solo · Home NUC'],
    ],
    'A group runs here when it can; a Role that only runs elsewhere follows, by its machine',
  );
  assert.deepEqual(
    listed('nuc'),
    [
      ['alpha-nuc', 'alpha'],
      ['moa-nuc', 'moa · Claude Code'],
      ['solo-nuc', 'solo'],
      ['moa-codex', 'moa · Codex · MacBook'],
      ['moa-deepseek', 'moa · DeepSeek · MacBook'],
      ['moa-fable', 'moa · Fable · MacBook'],
      ['moa-gemini', 'moa · Gemini · MacBook'],
    ],
    'The groups this machine has no instance of are still offered',
  );
  assert.deepEqual(
    listed(undefined),
    [
      ['alpha-nuc', 'alpha · Home NUC'],
      ['moa-nuc', 'moa · Claude Code · Home NUC'],
      ['moa-codex', 'moa · Codex · MacBook'],
      ['moa-deepseek', 'moa · DeepSeek · MacBook'],
      ['moa-fable', 'moa · Fable · MacBook'],
      ['moa-gemini', 'moa · Gemini · MacBook'],
      ['solo-nuc', 'solo · Home NUC'],
    ],
    'Without a machine a group is listed once, by its first instance',
  );
  const { items } = mentions.roleMentions(rows, 'me', machines, names, 'nuc');
  assert.equal(
    mentions.expandMentionText('@role:moa-fable @role:moa-nuc', items),
    'use lody mcp to create a session with agent role[id: moa, instance: moa-fable, name: moa · Fable] use lody mcp to create a session with agent role[id: moa, instance: moa-nuc, name: moa · Claude Code]',
    'The prompt names the instance by its group, never by its machine',
  );
});

test('only advertised well-formed commands are selectable', () => {
  assert.deepEqual(mentions.commandMentions(undefined).items, []);
  assert.deepEqual(
    mentions
      .commandMentions([
        { name: 'compact' },
        { name: 'bad\ncommand' },
        { name: '/goal' },
        { name: 'compact' },
      ])
      .items.map((item) => item.insertText),
    ['/compact'],
  );
});

test('first turn, queue and Steer persist the same expansion before delivery; failure writes nothing', async () => {
  const requests = [];
  const fixture = await openTestSession({
    onRpc: (request) => {
      requests.push(request);
      return { result: { accepted: true, applied: true } };
    },
  });
  const args = {
    sessionId: 's1',
    machineId: 'm1',
    userId: 'u1',
    cliType: 'builtin',
    agentType: 'codex',
    text,
  };
  let expansions = 0;
  const expand = (value) => {
    expansions++;
    return mentions.expandMentions(value, load);
  };
  try {
    const failed = await fixture.runtime.sendTurn(args, async () => {
      throw new Error('skills_unavailable');
    });
    assert.equal(failed.state, 'not_sent');
    assert.equal(
      fixture.appends.length,
      0,
      'No history, queue or RPC may be written before expansion succeeds',
    );
    assert.equal(
      (await fixture.runtime.sendTurn(args, expand)).state,
      'accepted',
    );
    assert.equal(
      fixture.server.toJSON().history[0].inputConfig.prompt,
      expected,
    );
    assert.equal(fixture.server.toJSON().history[0].items[0].text, expected);
    assert.equal(requests[0].params.inputConfig.prompt, expected);
    assert.equal(
      requests[0].params.inputConfig.agentRoleId,
      undefined,
      "Mentioning a Role never changes this turn's Role",
    );
    fixture.server
      .getList('history')
      .push({ id: 'reply', role: 'assistant', finished: false, items: [] });
    fixture.server.commit();
    await fixture.pushUpdate();
    const queued = await fixture.runtime.sendTurn(
      { ...args, queue: true },
      expand,
    );
    assert.equal(queued.state, 'queued');
    assert.equal(fixture.server.toJSON().mq[0].task, expected);
    assert.equal(
      fixture.server.toJSON().mq[0].acpSessionConfig.prompt,
      expected,
    );
    await fixture.runtime.controlTurn({
      action: 'steer',
      sessionId: 's1',
      machineId: 'm1',
      turnId: 'reply',
      messageId: queued.id,
    });
    assert.equal(requests.at(-1).method, 'session/steer');
    assert.equal(requests.at(-1).params.inputConfig.prompt, expected);
    assert.equal(
      expansions,
      2,
      'Steer must not reinterpret an already expanded queued prompt',
    );
    assert.equal(args.text, text, 'Failure/retry state retains the raw draft');
  } finally {
    fixture.close();
  }
});
