import { useEffect, useState } from 'react';
import {
  readVoicePreferences,
  saveVoicePreferences,
  voiceAgentsRaw,
  type VoicePreferences,
} from '@lody-ios/kit';
import {
  chooseVoiceAgent,
  parseVoiceAgents,
  voiceSection,
  type VoiceAgents,
} from './voice';

export function useVoiceSettings(workspaceId: string | undefined) {
  const [preferences, setPreferences] = useState(readVoicePreferences);
  const [agents, setAgents] = useState<VoiceAgents>();
  const [error, setError] = useState('');
  const enabled = preferences.enabled;
  useEffect(() => {
    if (!enabled || !workspaceId) return;
    let active = true;
    setError('');
    voiceAgentsRaw(JSON.stringify({ workspaceId })).then(
      (json) => {
        if (active) setAgents(parseVoiceAgents(json));
      },
      (reason: unknown) => {
        if (active) setError(String(reason));
      },
    );
    return () => {
      active = false;
    };
  }, [enabled, workspaceId]);
  const save = (next: VoicePreferences) => {
    saveVoicePreferences(next);
    setPreferences(next);
  };
  return {
    section: (signedIn: boolean) =>
      voiceSection({ preferences, agents, error, signedIn }),
    setEnabled: (value: boolean) => save({ ...preferences, enabled: value }),
    choose: (actionId: string) => {
      const next = chooseVoiceAgent(preferences, agents, actionId);
      if (next) save(next);
    },
  };
}
