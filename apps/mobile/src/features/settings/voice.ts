import type {
  NativeListSection,
  VoiceAgent,
  VoicePreferences,
} from '@lody-ios/kit';
import { t } from '../../lib/i18n/index.ts';

export type VoiceAgentOption = VoiceAgent & {
  name: string;
  machineName: string;
  /** The machine's agent service hosts `machine/voice`. */
  supported: boolean;
};
export type VoiceAgents = {
  shared: VoiceAgent | null;
  agents: VoiceAgentOption[];
};

export const WORKSPACE_VOICE_AGENT = 'workspace';
export const voiceAgentId = (agent: VoiceAgent) =>
  `agent:${agent.configId}:${agent.machineId}`;
const sameAgent = (a: VoiceAgent, b: VoiceAgent) =>
  a.configId === b.configId && a.machineId === b.machineId;

const optionTitle = (option: VoiceAgentOption) =>
  t(
    option.supported
      ? 'settings.voice.agentOption'
      : 'settings.voice.needsUpdate',
    {
      name: option.name,
      machine: option.machineName,
    },
  );

function agentValue(
  preferences: VoicePreferences,
  agents: VoiceAgents | undefined,
): string {
  if (!agents) return '';
  const own = preferences.agent;
  if (own) {
    const option = agents.agents.find((item) => sameAgent(item, own));
    return option ? optionTitle(option) : own.configId;
  }
  const shared = agents.shared;
  if (!shared) return t('settings.voice.notSet');
  const option = agents.agents.find((item) => sameAgent(item, shared));
  return t('settings.voice.workspaceValue', {
    name: option ? optionTitle(option) : shared.configId,
  });
}

/**
 * Settings › Experimental. Dictation stays hidden in the composer until it is
 * on; the agent is this device's own choice or the workspace's default.
 */
export function voiceSection({
  preferences,
  agents,
  error,
  signedIn,
}: {
  preferences: VoicePreferences;
  agents?: VoiceAgents;
  error?: string;
  signedIn: boolean;
}): NativeListSection {
  const rows: NativeListSection['rows'] = [
    {
      id: 'voice-dictation',
      title: t('settings.voice.title'),
      image: 'mic',
      toggle: preferences.enabled,
      action: true,
    },
  ];
  if (preferences.enabled && signedIn) {
    let subtitle: string | undefined;
    if (error) subtitle = t('settings.voice.loadFailed');
    else if (agents && agents.agents.length === 0)
      subtitle = t('settings.voice.noCodex');
    rows.push({
      id: 'voice-agent',
      title: t('settings.voice.agent'),
      subtitle,
      value: agentValue(preferences, agents),
      image: 'waveform',
      action: !!agents,
      options: [
        {
          id: WORKSPACE_VOICE_AGENT,
          title: t('settings.voice.workspace'),
          selected: !preferences.agent,
        },
        ...(agents?.agents ?? []).map((option) => ({
          id: voiceAgentId(option),
          title: optionTitle(option),
          selected: !!preferences.agent && sameAgent(option, preferences.agent),
        })),
      ],
    });
  }
  return {
    id: 'experimental',
    header: t('settings.section.experimental'),
    footer: t('settings.voice.footer'),
    rows,
  };
}

/** The preference after choosing a `voice-agent` option, or null for an unknown id. */
export function chooseVoiceAgent(
  preferences: VoicePreferences,
  agents: VoiceAgents | undefined,
  actionId: string,
): VoicePreferences | null {
  if (actionId === WORKSPACE_VOICE_AGENT)
    return { enabled: preferences.enabled };
  const option = agents?.agents.find((item) => voiceAgentId(item) === actionId);
  if (!option) return null;
  return {
    enabled: preferences.enabled,
    agent: { configId: option.configId, machineId: option.machineId },
  };
}

export function parseVoiceAgents(json: string): VoiceAgents {
  const value = JSON.parse(json) as Partial<VoiceAgents>;
  return {
    shared: value.shared ?? null,
    agents: Array.isArray(value.agents) ? value.agents : [],
  };
}
