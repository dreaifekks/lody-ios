import type { RpcReply } from './machine-rpc';

// Experimental realtime voice hosted by a machine's built-in Codex agent
// (Lody `machine/voice`, capability `realtimeVoice`). Native code owns the
// microphone and the WebRTC peer; this side only resolves which agent hosts
// the call and forwards the request to that machine.

export type VoiceAgent = { configId: string; machineId: string };
export type VoiceAgentOption = VoiceAgent & {
  name: string;
  machineName: string;
  /** The machine's agent service hosts `machine/voice`. */
  supported: boolean;
};

type Rows = Iterable<{ key: unknown[]; value?: unknown }>;
type Getter = { get(key: unknown[]): unknown };

const text = (value: unknown) =>
  typeof value === 'string' && value.length > 0 ? value : undefined;

/** The workspace-wide choice in the `['setting', 'voice']` Workspace Flock row. */
export function sharedVoiceAgent(rows: Rows): VoiceAgent | null {
  for (const row of rows) {
    if (
      row.key.length !== 2 ||
      row.key[0] !== 'setting' ||
      row.key[1] !== 'voice'
    )
      continue;
    const value = row.value as Record<string, unknown> | undefined;
    const configId = text(value?.configId);
    const machineId = text(value?.machineId);
    if (value?.version !== 1 || !configId || !machineId) return null;
    return { configId, machineId };
  }
  return null;
}

/** Whether a machine published `realtimeVoice` in its protocol capabilities. */
export function machineHostsVoice(meta: Getter, machineId: string): boolean {
  const room = `machine-${machineId}`;
  const capabilities = (meta.get(['m', room, 'protocolCapabilities']) ??
    (meta.get(['m', room]) as Record<string, unknown> | undefined)
      ?.protocolCapabilities) as Record<string, unknown> | undefined;
  const version = capabilities?.realtimeVoice;
  return typeof version === 'number' && version >= 1;
}

/** Built-in Codex agents, the only kind that can host voice. */
export function voiceAgentOptions(
  meta: Getter,
  machines: Map<string, { scan(): Rows }>,
): VoiceAgentOption[] {
  const options: VoiceAgentOption[] = [];
  for (const [machineId, flock] of machines) {
    const room = `machine-${machineId}`;
    const machineName =
      text(meta.get(['m', room, 'name'])) ??
      text(
        (meta.get(['m', room]) as Record<string, unknown> | undefined)?.name,
      ) ??
      machineId;
    const supported = machineHostsVoice(meta, machineId);
    for (const row of flock.scan()) {
      if (row.key[0] !== 'agentConfig') continue;
      const value = row.value as Record<string, unknown> | undefined;
      const configId = text(value?.id);
      if (
        !configId ||
        configId !== row.key[1] ||
        value?.machineId !== machineId ||
        value?.cliType !== 'builtin' ||
        value?.agentType !== 'codex'
      )
        continue;
      options.push({
        configId,
        machineId,
        name: text(value?.name) ?? configId,
        machineName,
        supported,
      });
    }
  }
  return options;
}

/** Older agent services drop unknown methods; their RPC errors read as messages. */
export function voiceReply(reply: RpcReply): Record<string, unknown> {
  if (reply.error)
    return {
      success: false,
      error: reply.error.message ?? reply.error.code ?? 'voice_failed',
    };
  const result = reply.result as Record<string, unknown> | undefined;
  if (!result || typeof result.success !== 'boolean')
    return { success: false, error: 'invalid_voice_response' };
  return result;
}
