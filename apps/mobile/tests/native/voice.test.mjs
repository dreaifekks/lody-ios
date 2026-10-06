import assert from 'node:assert/strict';
import test from 'node:test';
import {
  machineHostsVoice,
  sharedVoiceAgent,
  voiceAgentOptions,
  voiceReply,
} from '../../modules/lody-kit/data-runtime/voice.ts';

const meta = (values) => ({ get: (key) => values[JSON.stringify(key)] });
const flock = (rows) => ({ scan: () => rows });
const agentConfig = (id, machineId, extra = {}) => ({
  key: ['agentConfig', id],
  value: {
    id,
    machineId,
    name: id,
    cliType: 'builtin',
    agentType: 'codex',
    ...extra,
  },
});

test('the workspace voice row is read only in its published shape', () => {
  const row = (value) => [{ key: ['setting', 'voice'], value }];
  assert.deepEqual(
    sharedVoiceAgent(row({ version: 1, configId: 'c', machineId: 'm' })),
    { configId: 'c', machineId: 'm' },
  );
  assert.equal(
    sharedVoiceAgent(row({ version: 2, configId: 'c', machineId: 'm' })),
    null,
  );
  assert.equal(
    sharedVoiceAgent(row({ version: 1, configId: '', machineId: 'm' })),
    null,
  );
  assert.equal(
    sharedVoiceAgent([{ key: ['agentRole', 'voice'], value: {} }]),
    null,
  );
});

test('a machine hosts voice once it publishes realtimeVoice', () => {
  const nested = meta({
    '["m","machine-a"]': { protocolCapabilities: { realtimeVoice: 1 } },
  });
  const flat = meta({
    '["m","machine-b","protocolCapabilities"]': { realtimeVoice: 0 },
  });
  assert.equal(machineHostsVoice(nested, 'a'), true);
  assert.equal(machineHostsVoice(flat, 'b'), false);
  assert.equal(machineHostsVoice(meta({}), 'c'), false);
});

test('only built-in Codex agents of their own machine can host voice', () => {
  const options = voiceAgentOptions(
    meta({
      '["m","machine-a","name"]': 'homenucserver',
      '["m","machine-a","protocolCapabilities"]': { realtimeVoice: 1 },
    }),
    new Map([
      [
        'a',
        flock([
          agentConfig('codex', 'a', { name: 'Codex' }),
          agentConfig('claude', 'a', { agentType: 'claude' }),
          agentConfig('registry-codex', 'a', { cliType: 'registry' }),
          agentConfig('elsewhere', 'b'),
          {
            key: ['agentConfig', 'mismatch'],
            value: agentConfig('other', 'a').value,
          },
        ]),
      ],
      ['b', flock([agentConfig('codex-b', 'b')])],
    ]),
  );
  assert.deepEqual(options, [
    {
      configId: 'codex',
      machineId: 'a',
      name: 'Codex',
      machineName: 'homenucserver',
      supported: true,
    },
    {
      configId: 'codex-b',
      machineId: 'b',
      name: 'codex-b',
      machineName: 'b',
      supported: false,
    },
  ]);
});

test('an RPC error or malformed result reads as a failed voice reply', () => {
  assert.deepEqual(
    voiceReply({
      error: {
        code: 'method_unavailable',
        message: 'Voice is not available on this machine.',
      },
    }),
    {
      success: false,
      error: 'Voice is not available on this machine.',
    },
  );
  assert.deepEqual(voiceReply({ result: { ok: true } }), {
    success: false,
    error: 'invalid_voice_response',
  });
  const started = {
    success: true,
    action: 'start',
    voiceSessionId: 'v',
    sdp: 'answer',
  };
  assert.deepEqual(voiceReply({ result: started }), started);
});
