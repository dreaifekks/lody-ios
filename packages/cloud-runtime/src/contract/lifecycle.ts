import { z } from 'zod/v4';

export const StartParams = z
  .object({
    workspaceId: z.string().min(1),
    userId: z.string(),
    active: z.boolean(),
    knownRepos: z.record(z.string(), z.string()).optional(),
    /** The member lacks workspace write permission: no Status view writes are offered. */
    workspaceReadOnly: z.boolean().optional(),
  })
  .meta({ id: 'StartParams' });

export const RestoreSessionsParams = z
  .object({
    ids: z.array(z.string().min(1)),
    current: z.string().min(1).nullable(),
    reserved: z.array(z.string().min(1)),
    historyStart: z.number().int().nonnegative().optional(),
  })
  .meta({ id: 'RestoreSessionsParams' });

export const SetActiveParams = z
  .object({ active: z.boolean() })
  .meta({ id: 'SetActiveParams' });

export const OpenSessionParams = z
  .object({
    sessionId: z.string().min(1),
    historyStart: z.number().int().nonnegative().optional(),
  })
  .meta({ id: 'OpenSessionParams' });

export const ReleaseReserveParams = z
  .object({ sessionId: z.string().min(1) })
  .meta({ id: 'ReleaseReserveParams' });
