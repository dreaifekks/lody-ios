import { z } from 'zod/v4';

export const MachineStatusParams = z
  .object({
    workspaceId: z.string().min(1),
    action: z.enum(['list', 'ping']),
    machineId: z.string().optional(),
  })
  .meta({ id: 'MachineStatusParams' });
export const MachineStatusResult = z
  .object({
    machines: z
      .array(
        z.object({
          id: z.string(),
          name: z.string().optional(),
          alias: z.string().optional(),
          os: z.string().optional(),
          version: z.string().optional(),
          online: z.boolean().optional(),
        }),
      )
      .optional(),
    ms: z.number().optional(),
  })
  .meta({ id: 'MachineStatusResult' });
export const LanFileTargetParams = z
  .object({
    sessionId: z.string().optional(),
    machineId: z.string().optional(),
  })
  .meta({ id: 'LanFileTargetParams' });
export const LanTerminalEndpoint = z
  .object({
    version: z.number().int().min(1).max(1),
    host: z.string(),
    port: z.number().int(),
  })
  .meta({ id: 'LanTerminalEndpoint' });
export const LanFileTargetResult = z
  .object({
    machineId: z.string().optional(),
    name: z.string().optional(),
    lanTerminal: LanTerminalEndpoint.optional(),
    protocolCapabilities: z.record(z.string(), z.number()).optional(),
  })
  .meta({ id: 'LanFileTargetResult' });
export const VoiceAgent = z
  .object({ configId: z.string(), machineId: z.string() })
  .meta({ id: 'VoiceAgent' });
export const VoiceAgentsParams = z
  .object({ workspaceId: z.string().min(1) })
  .meta({ id: 'VoiceAgentsParams' });
export const VoiceAgentsResult = z
  .object({
    shared: VoiceAgent.nullable(),
    agents: z.array(
      VoiceAgent.extend({
        name: z.string(),
        machineName: z.string(),
        supported: z.boolean(),
      }),
    ),
  })
  .meta({ id: 'VoiceAgentsResult' });
export const MachineVoiceParams = z
  .object({
    workspaceId: z.string().min(1),
    request: z.record(z.string(), z.unknown()),
    agent: VoiceAgent.optional(),
    machineId: z.string().optional(),
  })
  .meta({ id: 'MachineVoiceParams' });
export const MachineVoiceResult = z
  .record(z.string(), z.unknown())
  .meta({ id: 'MachineVoiceResult' });
