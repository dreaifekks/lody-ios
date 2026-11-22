import { z } from 'zod/v4';

/**
 * Status view (Focus / Later / Settled) and pin sections. The shared Lody
 * planner computes every list; native hosts render these shapes and never sort
 * or classify. Shapes: Lody `.agents/notes/proposed/architecture/2026-11-21-status-view-on-phones.md`.
 */

export const PinSection = z
  .object({
    id: z.string().min(1),
    name: z.string().min(1),
    /** Fractional index ordering the sections; hosts keep the given order. */
    orderKey: z.string().min(1),
  })
  .meta({ id: 'PinSection' });
export type PinSection = z.infer<typeof PinSection>;

export const StatusViewTier = z
  .enum(['pinned', 'focus', 'later', 'settled'])
  .meta({ id: 'StatusViewTier' });

export type StatusViewRow = {
  id: string;
  tier: z.infer<typeof StatusViewTier>;
  children: StatusViewRow[];
  activityAt: number;
  unread: boolean;
  snoozedUntil: number | null;
  woken: boolean;
  canManage: boolean;
  canPrefer: boolean;
};

export const StatusViewRow: z.ZodType<StatusViewRow> = z
  .object({
    id: z.string().min(1),
    tier: StatusViewTier,
    /** Opened-by children rendered under this row. */
    get children() {
      return z.array(StatusViewRow);
    },
    /** max(lastMessageAt, expired snoozedUntil), epoch ms on the server clock. */
    activityAt: z.number(),
    unread: z.boolean(),
    /** Set while the row is in Later. */
    snoozedUntil: z.number().nullable(),
    /** An expired snooze floating at the top of Focus. */
    woken: z.boolean(),
    /** Later / Settle / Move to Focus / reorder in Focus. */
    canManage: z.boolean(),
    /** Pin, unpin, pin placement. */
    canPrefer: z.boolean(),
  })
  .meta({ id: 'StatusViewRow' });

export const StatusViewPinnedSection = z
  .object({
    /** null is the default "Pinned" section. */
    sectionId: z.string().nullable(),
    name: z.string().nullable(),
    rows: z.array(StatusViewRow),
    /** Rows of this section the current scope hid. */
    hiddenCount: z.number().int().nonnegative(),
  })
  .meta({ id: 'StatusViewPinnedSection' });

export const StatusViewLayout = z
  .object({
    pinned: z.array(StatusViewPinnedSection),
    focus: z.array(StatusViewRow),
    later: z.array(StatusViewRow),
    settled: z.array(StatusViewRow),
    /** May create, rename, reorder and delete pin sections. */
    canManageSections: z.boolean(),
    /** Earliest future instant at which the layout can change by time alone. */
    nextChangeAt: z.number().nullable(),
  })
  .meta({ id: 'StatusViewLayout' });
export type StatusViewLayout = z.infer<typeof StatusViewLayout>;

/** Catalog `statusView`: the signed-in user's sessions and the whole team's. */
export const CatalogStatusView = z
  .object({
    mine: StatusViewLayout,
    team: StatusViewLayout,
    /** Server-clock instant the layouts were computed at. */
    nowMs: z.number(),
    /** False until the workspace `pinSection` rows have been read once. */
    sectionsLoaded: z.boolean(),
  })
  .meta({ id: 'CatalogStatusView' });
export type CatalogStatusView = z.infer<typeof CatalogStatusView>;

const sessionId = z.string().min(1).max(200);
const sectionId = z.string().min(1).max(200);
const sectionName = z.string().trim().min(1).max(100);

export const StatusViewMoveTarget = z
  .discriminatedUnion('area', [
    z.object({ area: z.literal('focus') }),
    z.object({ area: z.literal('pinned'), sectionId: sectionId.nullable() }),
  ])
  .meta({ id: 'StatusViewMoveTarget' });

export const StatusViewCommand = z
  .discriminatedUnion('type', [
    z.object({
      type: z.literal('snooze'),
      sessionId,
      until: z.number(),
      includeOpened: z.boolean(),
    }),
    z.object({
      type: z.literal('settle'),
      sessionId,
      includeOpened: z.boolean(),
    }),
    z.object({
      type: z.literal('moveToFocus'),
      sessionId,
      includeOpened: z.boolean(),
    }),
    z.object({
      type: z.literal('setPinned'),
      sessionId,
      pinned: z.boolean(),
    }),
    z.object({
      type: z.literal('move'),
      sessionId,
      to: StatusViewMoveTarget,
      /** The row it lands in front of; null is the end. */
      beforeId: sessionId.nullable(),
    }),
    z.object({
      type: z.literal('createSection'),
      sectionId,
      name: sectionName,
    }),
    z.object({
      type: z.literal('renameSection'),
      sectionId,
      name: sectionName,
    }),
    z.object({ type: z.literal('deleteSection'), sectionId }),
    z.object({
      type: z.literal('moveSection'),
      sectionId,
      beforeId: sectionId.nullable(),
    }),
  ])
  .meta({ id: 'StatusViewCommand' });
export type StatusViewCommand = z.infer<typeof StatusViewCommand>;

export const StatusViewCommandParams = z
  .object({
    workspaceId: z.string().min(1),
    command: StatusViewCommand,
    /** The list the gesture happened in; `move` resolves `beforeId` against it. Default `team`. */
    scope: z.enum(['mine', 'team']).optional(),
  })
  .meta({ id: 'StatusViewCommandParams' });

export const StatusViewCommandResult = z
  .object({
    /** Session metadata patches and pin-section rows written; 0 is a no-op. */
    writes: z.number().int().nonnegative(),
  })
  .meta({ id: 'StatusViewCommandResult' });

export const SnoozePresetId = z
  .enum(['oneHour', 'laterToday', 'tomorrowMorning', 'nextWeek'])
  .meta({ id: 'SnoozePresetId' });

export const SnoozePreset = z
  .object({
    id: SnoozePresetId,
    /** Resolved wake-up instant, epoch ms on the server clock. */
    until: z.number(),
    /** Compact countdown, e.g. `3h`, `1d`. */
    countdown: z.string(),
  })
  .meta({ id: 'SnoozePreset' });

export const SnoozePresetsResult = z
  .object({ nowMs: z.number(), presets: z.array(SnoozePreset) })
  .meta({ id: 'SnoozePresetsResult' });
