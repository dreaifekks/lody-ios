import { native } from '../runtime/LodyKit';

export type VoiceAgent = { configId: string; machineId: string };
export type VoicePreferences = { enabled: boolean; agent?: VoiceAgent };

/** Experimental dictation; the native composer reads the same preference. */
export function readVoicePreferences(): VoicePreferences {
  try {
    const value = JSON.parse(native.readVoicePreferences()) as VoicePreferences;
    return { enabled: value.enabled === true, agent: value.agent };
  } catch {
    return { enabled: false };
  }
}

/** Without an agent the device follows the workspace's voice agent. */
export const saveVoicePreferences = (value: VoicePreferences) =>
  native.saveVoicePreferences(
    value.enabled,
    value.agent?.configId ?? '',
    value.agent?.machineId ?? '',
  );

export const voiceAgentsRaw = (payload: string): Promise<string> =>
  native.voiceAgents(payload);
