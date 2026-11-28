// Lody agent-role.ts: v1 inline / fork instances and v2 targets wire shapes.
// Keep the stored row intact: mobile edits shared metadata, not run configuration.
import {
  migrateLegacyAntigravityModeId,
  migrateLegacyAntigravityModeOption,
  resolveConfigOptionsForModel,
} from './capability.ts';
import type { ConfigOption } from '../models/send.ts';

type RecordValue = Record<string, unknown>;
export const record = (value: unknown): value is RecordValue =>
  !!value && typeof value === 'object' && !Array.isArray(value);
const label = (value: unknown): value is string =>
  typeof value === 'string' &&
  !!value.trim() &&
  value.length <= 4096 &&
  !/[\x00-\x1f\x7f]/.test(value);
const identifier = (value: unknown): value is string =>
  label(value) && !/[\s@]/.test(value);
const runConfig = (value: unknown) => {
  if (value === undefined) return true;
  if (!record(value)) return false;
  const memory = value.memory;
  return (
    memory === undefined ||
    (record(memory) &&
      Object.keys(memory).every((key) =>
        ['providerId', 'memoryId'].includes(key),
      ) &&
      typeof memory.providerId === 'string' &&
      !!memory.providerId.trim() &&
      memory.providerId.length <= 100 &&
      typeof memory.memoryId === 'string' &&
      !!memory.memoryId.trim() &&
      memory.memoryId.length <= 200)
  );
};
export const roleSlug = (value: string) =>
  Array.from(
    value
      .trim()
      .replace(/^@+/u, '')
      .replace(/\p{Cc}/gu, '')
      .replace(/\s+/gu, '-')
      .replace(/-{2,}/gu, '-')
      .replace(/^-+|-+$/gu, ''),
  )
    .slice(0, 40)
    .join('');
export type StoredTarget = {
  id?: string;
  machineId: string;
  agentConfigId: string;
  alias?: string;
  runConfig?: RecordValue;
};
export type StoredRole = {
  id: string;
  ownerUserId: string;
  visibility: 'private' | 'workspace';
  name: string;
  description?: string;
  promptPrefix?: string;
  emoji?: string;
  revision: number;
  updatedAt: number;
  targets: StoredTarget[];
};
export function readRole(value: unknown, id: unknown): StoredRole | undefined {
  if (
    !record(value) ||
    !identifier(id) ||
    value.id !== id ||
    !identifier(value.ownerUserId) ||
    !label(value.name) ||
    !roleSlug(value.name) ||
    !['private', 'workspace'].includes(String(value.visibility)) ||
    typeof value.revision !== 'number' ||
    !Number.isFinite(value.revision) ||
    typeof value.createdAt !== 'number' ||
    !Number.isFinite(value.createdAt) ||
    typeof value.updatedAt !== 'number' ||
    !Number.isFinite(value.updatedAt) ||
    (value.emoji !== undefined && typeof value.emoji !== 'string') ||
    (value.description !== undefined &&
      typeof value.description !== 'string') ||
    (value.promptPrefix !== undefined && typeof value.promptPrefix !== 'string')
  )
    return;
  let targets: unknown[];
  if (value.v === 2 && Array.isArray(value.targets)) targets = value.targets;
  else if (
    value.v === 1 &&
    Array.isArray(value.instances) &&
    value.instances.length
  )
    targets = value.instances;
  else if (
    value.v === 1 &&
    (value.additionalTargets === undefined ||
      Array.isArray(value.additionalTargets))
  )
    targets = [
      { ...value, id: value.targetId },
      ...((value.additionalTargets as unknown[]) ?? []),
    ];
  else return;
  if (
    !targets.length ||
    targets.length > 64 ||
    targets.some(
      (target) =>
        !record(target) ||
        !identifier(target.machineId) ||
        !identifier(target.agentConfigId) ||
        (target.id !== undefined && !identifier(target.id)) ||
        (target.alias !== undefined && typeof target.alias !== 'string') ||
        !runConfig(target.runConfig),
    )
  )
    return;
  const unique = new Map<string, StoredTarget>();
  for (const target of targets as StoredTarget[]) {
    const key = target.id ? `id:${target.id}` : `machine:${target.machineId}`;
    if (!unique.has(key)) {
      const alias = Array.from(target.alias?.trim() ?? '')
        .slice(0, 60)
        .join('');
      unique.set(key, {
        ...target,
        alias: roleSlug(alias) ? alias : undefined,
      });
    }
  }
  return {
    id,
    ownerUserId: value.ownerUserId,
    visibility: value.visibility as StoredRole['visibility'],
    name: value.name.trim(),
    description: value.description as string | undefined,
    promptPrefix: (value.promptPrefix as string | undefined)?.trim(),
    emoji: roleEmoji(value.emoji),
    revision: Math.max(1, Math.trunc(value.revision)),
    updatedAt: value.updatedAt,
    targets: [...unique.values()],
  };
}
export const readableRole = (role: StoredRole, userId: string) =>
  !!userId && (role.ownerUserId === userId || role.visibility === 'workspace');

// Web `DEFAULT_AGENT_ROLE_EMOJI` / `normalizeAgentRoleEmoji`: one short glyph, no
// whitespace or control characters; a Role without one reads as the default.
export const DEFAULT_ROLE_EMOJI = '🪼';
export function roleEmoji(value: unknown): string | undefined {
  if (typeof value !== 'string') return undefined;
  const glyph = Array.from(value.replace(/\p{Cc}/gu, '').replace(/\s+/gu, ''))
    .slice(0, 8)
    .join('');
  return glyph || undefined;
}

// Web `isSensitiveAgentRoleConfigOptionKey`, applied on read as well as on write:
// a Role is a replicated row, so secret-shaped option keys never reach a turn.
const SENSITIVE_OPTION =
  /(?:api[_-]?key|auth|bearer|credential|password|passwd|secret|token)/i;
const SENSITIVE_ROLE_OPTION = /(?:\bkey\b|cookie|session[_-]?id|private)/i;
export const sensitiveRoleOption = (key: string) =>
  SENSITIVE_OPTION.test(key) || SENSITIVE_ROLE_OPTION.test(key);

export type RoleRunConfig = {
  modelId?: string;
  modeId?: string;
  configOptionValues?: Record<string, string | boolean>;
  memory?: { providerId: string; memoryId: string };
};

/** Web `normalizeAgentRoleRunConfig`: what one target pins, trimmed and filtered. */
export function roleRunConfig(value: unknown): RoleRunConfig {
  if (!record(value)) return {};
  const modelId = typeof value.modelId === 'string' ? value.modelId.trim() : '';
  const rawModeId = typeof value.modeId === 'string' ? value.modeId.trim() : '';
  const modeId = rawModeId ? migrateLegacyAntigravityModeId(rawModeId) : '';
  const options: Record<string, string | boolean> = {};
  if (record(value.configOptionValues))
    for (const [raw, entry] of Object.entries(value.configOptionValues)) {
      const key = raw.trim();
      if (!key || sensitiveRoleOption(key)) continue;
      if (typeof entry === 'string' || typeof entry === 'boolean')
        options[key] = entry;
    }
  const normalizedOptions = migrateLegacyAntigravityModeOption(options);
  const memory = record(value.memory) ? value.memory : undefined;
  return {
    ...(modelId ? { modelId } : {}),
    ...(modeId ? { modeId } : {}),
    ...(Object.keys(normalizedOptions).length
      ? { configOptionValues: normalizedOptions }
      : {}),
    ...(memory &&
    typeof memory.providerId === 'string' &&
    typeof memory.memoryId === 'string'
      ? {
          memory: { providerId: memory.providerId, memoryId: memory.memoryId },
        }
      : {}),
  };
}

export type RoleRunConfigOption = Pick<
  ConfigOption,
  'id' | 'category' | 'type'
> & {
  currentValue?: string | boolean;
};

export type RoleRunConfigCapability = {
  configOptions?: readonly RoleRunConfigOption[];
  modes?: readonly unknown[];
  models?: readonly unknown[];
  observedModelConfigOptions?: Readonly<
    Record<string, readonly RoleRunConfigOption[]>
  >;
};

export type RoleRunConfigTarget = {
  cliType?: string | null;
  capability?: RoleRunConfigCapability;
  configOptions?: readonly RoleRunConfigOption[];
};

export type CanonicalRoleRunConfig = {
  /** Projected top-level modeId for dispatch/preferences (omitted when configOption-driven). */
  modeId: string | undefined;
  /** Projected top-level modelId for dispatch/preferences (omitted when configOption-driven). */
  modelId: string | undefined;
  /** Projected configOptionValues with canonical mode/model bridged or aligned. */
  configOptionValues: Record<string, string | boolean> | undefined;
  /** Canonical pinned mode regardless of representation. */
  canonicalModeId: string | undefined;
  /** Canonical pinned model regardless of representation. */
  canonicalModelId: string | undefined;
  /** Active mode configOption id (resolved for the target model), when any. */
  modeOptionId: string | undefined;
  /** Active model configOption id, when any. */
  modelOptionId: string | undefined;
};

export function resolveModelOptionId(
  target?: RoleRunConfigTarget,
  configOptionValues?: Record<string, unknown>,
): string | undefined {
  const isConfigOptionDriven =
    target?.cliType === 'registry' || target?.cliType === 'custom';
  const rawConfigOptions =
    target?.capability?.configOptions ?? target?.configOptions;
  if ((rawConfigOptions?.length ?? 0) > 0) {
    return rawConfigOptions?.find(
      (option) => option.category === 'model' && option.type === 'select',
    )?.id;
  }
  if ((target?.capability?.models?.length ?? 0) > 0) {
    return 'model';
  }
  if (isConfigOptionDriven && typeof configOptionValues?.model === 'string') {
    return 'model';
  }
  return undefined;
}

export function resolveModeOptionId(
  target?: RoleRunConfigTarget,
  canonicalModelId?: string,
  configOptionValues?: Record<string, unknown>,
): string | undefined {
  const isConfigOptionDriven =
    target?.cliType === 'registry' || target?.cliType === 'custom';
  const modeConfigOptions = target?.capability
    ? resolveConfigOptionsForModel(
        target.capability.configOptions,
        target.capability.observedModelConfigOptions,
        canonicalModelId,
      )
    : target?.configOptions;
  if ((modeConfigOptions?.length ?? 0) > 0) {
    return modeConfigOptions?.find(
      (option) =>
        option.category === 'mode' &&
        option.type === 'select' &&
        option.id !== 'interaction_mode',
    )?.id;
  }
  if ((target?.capability?.modes?.length ?? 0) > 0) {
    return 'mode';
  }
  if (isConfigOptionDriven && typeof configOptionValues?.mode === 'string') {
    return 'mode';
  }
  return undefined;
}

/**
 * Aligns with Lody `resolveCanonicalAgentRoleRunConfig`:
 * - `registry`/`custom` (config-option driven): `configOptionValues[id] ?? top-level`
 * - `builtin` (dedicated fields): `top-level ?? configOptionValues['mode'/'model']`
 * Model resolves first so `observedModelConfigOptions` for the target model
 * determines the active mode option id (excluding `interaction_mode`).
 */
export function resolveCanonicalAgentRoleRunConfig(
  runConfig: Pick<RoleRunConfig, 'modeId' | 'modelId' | 'configOptionValues'>,
  target?: RoleRunConfigTarget,
): CanonicalRoleRunConfig {
  const normalized = roleRunConfig(runConfig);
  const isConfigOptionDriven =
    target?.cliType === 'registry' || target?.cliType === 'custom';
  const modelOptionId = resolveModelOptionId(
    target,
    normalized.configOptionValues,
  );

  const modelLookupKey = modelOptionId ?? 'model';
  const rawModelFromConfig = normalized.configOptionValues?.[modelLookupKey];
  const modelFromConfig =
    typeof rawModelFromConfig === 'string' && rawModelFromConfig.trim()
      ? rawModelFromConfig.trim()
      : undefined;
  const canonicalModelId = isConfigOptionDriven
    ? (modelFromConfig ?? normalized.modelId)
    : (normalized.modelId ?? modelFromConfig);

  const modeOptionId = resolveModeOptionId(
    target,
    canonicalModelId,
    normalized.configOptionValues,
  );

  const modeLookupKey = modeOptionId ?? 'mode';
  const rawModeFromConfig = normalized.configOptionValues?.[modeLookupKey];
  const modeFromConfig =
    typeof rawModeFromConfig === 'string' && rawModeFromConfig.trim()
      ? migrateLegacyAntigravityModeId(rawModeFromConfig.trim())
      : undefined;
  const canonicalModeId = isConfigOptionDriven
    ? (modeFromConfig ?? normalized.modeId)
    : (normalized.modeId ?? modeFromConfig);

  if (isConfigOptionDriven) {
    const bridged: Record<string, string | boolean> =
      normalized.configOptionValues ? { ...normalized.configOptionValues } : {};
    if (
      modelOptionId &&
      canonicalModelId !== undefined &&
      bridged[modelOptionId] === undefined
    ) {
      bridged[modelOptionId] = canonicalModelId;
    }
    if (
      modeOptionId &&
      canonicalModeId !== undefined &&
      bridged[modeOptionId] === undefined
    ) {
      bridged[modeOptionId] = canonicalModeId;
    }
    return {
      modeId: modeOptionId ? undefined : canonicalModeId,
      modelId: modelOptionId ? undefined : canonicalModelId,
      configOptionValues: Object.keys(bridged).length > 0 ? bridged : undefined,
      canonicalModeId,
      canonicalModelId,
      modeOptionId,
      modelOptionId,
    };
  }

  const nextConfig = normalized.configOptionValues
    ? { ...normalized.configOptionValues }
    : undefined;
  if (nextConfig && target?.cliType === 'builtin') {
    if (
      typeof nextConfig[modeLookupKey] === 'string' &&
      canonicalModeId !== undefined
    ) {
      delete nextConfig[modeLookupKey];
    }
    if (
      typeof nextConfig[modelLookupKey] === 'string' &&
      canonicalModelId !== undefined
    ) {
      delete nextConfig[modelLookupKey];
    }
  }
  return {
    modeId: canonicalModeId,
    modelId: canonicalModelId,
    configOptionValues:
      nextConfig && Object.keys(nextConfig).length > 0 ? nextConfig : undefined,
    canonicalModeId,
    canonicalModelId,
    modeOptionId,
    modelOptionId,
  };
}

/**
 * Web `isAgentRoleRunConfigApplied`: every value the Role PINS is what will run.
 * Unpinned values are the agent's own; independent Plan toggles (`plan_mode`, a
 * plan/default `collaboration_mode`) are per-turn overrides that keep the Role.
 */
export function roleRunConfigApplied(
  pinned: RoleRunConfig,
  selection: {
    modelId?: string | null;
    modeId?: string | null;
    configOptionValues?: Record<string, unknown>;
  },
  target?: RoleRunConfigTarget,
): boolean {
  const plan = (value: unknown) => value === 'plan' || value === 'default';
  if (target) {
    const canonicalPinned = resolveCanonicalAgentRoleRunConfig(pinned, target);
    const selectedConfig: Record<string, string | boolean> = {};
    if (record(selection.configOptionValues)) {
      for (const [key, value] of Object.entries(selection.configOptionValues)) {
        if (typeof value === 'string' || typeof value === 'boolean')
          selectedConfig[key] = value;
      }
    }
    const canonicalSelected = resolveCanonicalAgentRoleRunConfig(
      {
        modelId:
          typeof selection.modelId === 'string' ? selection.modelId : undefined,
        modeId:
          typeof selection.modeId === 'string' ? selection.modeId : undefined,
        configOptionValues: Object.keys(selectedConfig).length
          ? selectedConfig
          : undefined,
      },
      target,
    );
    if (
      canonicalPinned.canonicalModeId &&
      canonicalSelected.canonicalModeId !== canonicalPinned.canonicalModeId
    )
      return false;
    if (
      canonicalPinned.canonicalModelId &&
      canonicalSelected.canonicalModelId !== canonicalPinned.canonicalModelId
    )
      return false;
    const checkedModeKey =
      canonicalPinned.modeOptionId ??
      (target.cliType === 'builtin' ? 'mode' : undefined);
    const checkedModelKey =
      canonicalPinned.modelOptionId ??
      (target.cliType === 'builtin' ? 'model' : undefined);
    for (const [key, value] of Object.entries(
      canonicalPinned.configOptionValues ?? {},
    )) {
      if (
        key === checkedModeKey &&
        (typeof value === 'string' ||
          canonicalPinned.canonicalModeId !== undefined)
      )
        continue;
      if (
        key === checkedModelKey &&
        (typeof value === 'string' ||
          canonicalPinned.canonicalModelId !== undefined)
      )
        continue;
      const selected = canonicalSelected.configOptionValues?.[key];
      if (
        key === 'plan_mode' &&
        typeof value === 'boolean' &&
        typeof selected === 'boolean'
      )
        continue;
      if (key === 'collaboration_mode' && plan(value) && plan(selected))
        continue;
      if (selected !== value) return false;
    }
    return true;
  }
  const pinnedMode = pinned.modeId
    ? migrateLegacyAntigravityModeId(pinned.modeId)
    : undefined;
  const selectedMode =
    typeof selection.modeId === 'string'
      ? migrateLegacyAntigravityModeId(selection.modeId)
      : selection.modeId;
  if (pinnedMode && selectedMode !== pinnedMode) return false;
  if (pinned.modelId && selection.modelId !== pinned.modelId) return false;
  const pinnedOptions = pinned.configOptionValues
    ? migrateLegacyAntigravityModeOption(pinned.configOptionValues)
    : {};
  const selectedOptions = selection.configOptionValues
    ? migrateLegacyAntigravityModeOption(selection.configOptionValues)
    : undefined;
  for (const [key, value] of Object.entries(pinnedOptions)) {
    const selected = selectedOptions?.[key];
    if (
      key === 'plan_mode' &&
      typeof value === 'boolean' &&
      typeof selected === 'boolean'
    )
      continue;
    if (key === 'collaboration_mode' && plan(value) && plan(selected)) continue;
    if (selected !== value) return false;
  }
  return true;
}
