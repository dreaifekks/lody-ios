import assert from 'node:assert/strict';
import test from 'node:test';
import {
  chooseVoiceAgent,
  parseVoiceAgents,
  voiceAgentId,
  voiceSection,
} from '../../src/features/settings/voice.ts';

const codex = {
  configId: 'codex-1',
  machineId: 'nuc',
  name: 'Codex',
  machineName: 'homenucserver',
  supported: true,
};
const old = {
  configId: 'codex-2',
  machineId: 'mac',
  name: 'Codex',
  machineName: 'MacBook Air',
  supported: false,
};
const agents = {
  shared: { configId: 'codex-1', machineId: 'nuc' },
  agents: [codex, old],
};
const row = (section, id) => section.rows.find((item) => item.id === id);

test('dictation stays a single switch until it is turned on', () => {
  const section = voiceSection({
    preferences: { enabled: false },
    signedIn: true,
  });
  assert.deepEqual(
    section.rows.map((item) => item.id),
    ['voice-dictation'],
  );
  assert.equal(row(section, 'voice-dictation').toggle, false);
  assert.equal(row(section, 'voice-dictation').action, true);
});

test('signed out, the switch still works but there is no agent to choose', () => {
  const section = voiceSection({
    preferences: { enabled: true },
    signedIn: false,
  });
  assert.equal(row(section, 'voice-dictation').action, true);
  assert.equal(row(section, 'voice-agent'), undefined);
});

test('the agent row follows the workspace by default and lists every Codex agent', () => {
  const section = voiceSection({
    preferences: { enabled: true },
    agents,
    signedIn: true,
  });
  const agent = row(section, 'voice-agent');
  assert.match(agent.value, /homenucserver/);
  assert.deepEqual(
    agent.options.map((option) => [option.id, option.selected]),
    [
      ['workspace', true],
      [voiceAgentId(codex), false],
      [voiceAgentId(old), false],
    ],
  );
  assert.notEqual(agent.options[1].title, agent.options[2].title);
});

test('a device choice is selected and shown instead of the workspace default', () => {
  const preferences = {
    enabled: true,
    agent: { configId: 'codex-2', machineId: 'mac' },
  };
  const agent = row(
    voiceSection({ preferences, agents, signedIn: true }),
    'voice-agent',
  );
  assert.match(agent.value, /MacBook Air/);
  assert.equal(
    agent.options.find((option) => option.selected).id,
    voiceAgentId(old),
  );
});

test('the agent row waits for the list and explains an empty one', () => {
  const loading = row(
    voiceSection({ preferences: { enabled: true }, signedIn: true }),
    'voice-agent',
  );
  assert.equal(loading.action, false);
  assert.equal(loading.value, '');
  const empty = row(
    voiceSection({
      preferences: { enabled: true },
      agents: { shared: null, agents: [] },
      signedIn: true,
    }),
    'voice-agent',
  );
  assert.ok(empty.subtitle);
  assert.ok(empty.value);
});

test('choosing an option keeps the switch and replaces only the agent', () => {
  const on = {
    enabled: true,
    agent: { configId: 'codex-2', machineId: 'mac' },
  };
  assert.deepEqual(chooseVoiceAgent(on, agents, 'workspace'), {
    enabled: true,
  });
  assert.deepEqual(
    chooseVoiceAgent({ enabled: true }, agents, voiceAgentId(codex)),
    {
      enabled: true,
      agent: { configId: 'codex-1', machineId: 'nuc' },
    },
  );
  assert.equal(chooseVoiceAgent(on, agents, 'agent:missing:nuc'), null);
});

test('a runtime reply without agents parses as an empty list', () => {
  assert.deepEqual(parseVoiceAgents('{}'), { shared: null, agents: [] });
});
