import type { Capability, ModelChoice, ConfigOption } from '../models/send.ts';

/**
 * LAN fork: Lody's former Antigravity Auto Review (`auto_review`) was removed;
 * sessions, Roles and schedules saved with it run in agy's own `auto`.
 */
export function migrateLegacyAntigravityModeId(modeId: string): string {
  return modeId === 'auto_review' ? 'auto' : modeId;
}

export function migrateLegacyAntigravityModeOption<
  T extends Record<string, unknown>,
>(values: T): T {
  return values.mode === 'auto_review' ? { ...values, mode: 'auto' } : values;
}

export type PermissionTier = 'ask' | 'edit' | 'auto' | 'full';

const MODE_TIERS: Readonly<Record<string, PermissionTier>> = {
  // Claude Code
  default: 'ask',
  plan: 'ask',
  acceptEdits: 'edit',
  auto: 'auto',
  dontAsk: 'full',
  bypassPermissions: 'full',
  // Codex
  agent: 'ask',
  'read-only': 'ask',
  'agent-auto-review': 'auto',
  'agent-full-access': 'full',
  'danger-full-access': 'full',
  // DeepSeek Harness
  'workspace-write': 'edit',
  // Google Antigravity / agy CLI / Gemini / Kimi
  auto_edit: 'edit',
  'accept-edits': 'edit',
  auto_review: 'auto',
  yolo: 'full',
  // Grok
  ask: 'ask',
  'always-approve': 'full',
};

export function permissionTierOf(
  modeId: string | null | undefined,
): PermissionTier | null {
  if (!modeId) return null;
  return MODE_TIERS[modeId.trim()] ?? null;
}

export const isThoughtLevel = (option: ConfigOption) =>
  option.type === 'select' &&
  (option.category === 'thought_level' || option.id === 'reasoning_effort');

export const validConfigValue = (option: ConfigOption, value: unknown) =>
  option.type === 'boolean'
    ? typeof value === 'boolean'
    : typeof value === 'string' &&
      option.options.some((item) => item.id === value);

export function effortsFor(capability?: Capability, modelId?: string) {
  const model =
    modelId ??
    capability?.configOptions?.find((option) => option.category === 'model')
      ?.currentValue;
  if (typeof model === 'string' && capability?.reasoningEfforts[model])
    return capability.reasoningEfforts[model];
  // Agents without a per-model catalog publish the current ladder in configOptions.
  return (
    capability?.configOptions
      ?.find(isThoughtLevel)
      ?.options.map((option) => option.id) ?? []
  );
}

export function fastModeFor(
  capability: Capability | undefined,
  choice: ModelChoice,
) {
  const model =
    choice.modelId ??
    capability?.configOptions?.find((o) => o.category === 'model')
      ?.currentValue;
  if (typeof model === 'string' && capability?.fastModes?.[model] === false)
    return undefined;
  const option = capability?.configOptions?.find(
    (item) =>
      ['fast-mode', 'fast'].includes(item.id) && item.type === 'boolean',
  );
  if (!option) return undefined;
  const value = choice.configOptionValues?.[option.id] ?? option.currentValue;
  return { id: option.id, enabled: value === true };
}

export function withFastMode(
  capability: Capability | undefined,
  choice: ModelChoice,
  enabled: boolean,
): ModelChoice {
  const mode = fastModeFor(capability, choice);
  if (!mode) return choice;
  return {
    ...choice,
    configOptionValues: { ...choice.configOptionValues, [mode.id]: enabled },
  };
}

// Match OSS resolvePermissionModeFace: explicit permissions, legacy modes,
// then a generic mode selector. Interaction mode is a separate control.
export function permissionModeFor(
  capability: Capability | undefined,
  choice: ModelChoice,
) {
  const selectors =
    capability?.configOptions?.filter((item) => item.type === 'select') ?? [];
  let option = selectors.find(
    (item) => item.id === 'permission_mode' || item.category === '_permission',
  );
  const modes = capability?.legacyModes ?? capability?.modes ?? [];
  if (!option && modes.length) {
    return {
      options: modes,
      value: choice.modeId
        ? migrateLegacyAntigravityModeId(choice.modeId)
        : undefined,
      configId: undefined,
    };
  }
  option ??= selectors.find(
    (item) =>
      item.category === 'mode' &&
      item.id !== 'interaction_mode' &&
      !isThoughtLevel(item),
  );
  if (!option?.options.length) return undefined;
  const rawSelected = choice.configOptionValues?.[option.id];
  const selected =
    option.id === 'mode' && typeof rawSelected === 'string'
      ? migrateLegacyAntigravityModeId(rawSelected)
      : rawSelected;
  const value = validConfigValue(option, selected)
    ? selected
    : option.currentValue;
  return {
    options: option.options,
    value: typeof value === 'string' ? value : undefined,
    configId: option.id,
  };
}

export function withPermissionMode(
  capability: Capability | undefined,
  choice: ModelChoice,
  value: string,
): ModelChoice {
  const permission = permissionModeFor(capability, choice);
  if (!permission?.options.some((item) => item.id === value)) return choice;
  if (permission.configId)
    return {
      ...choice,
      configOptionValues: {
        ...choice.configOptionValues,
        [permission.configId]: value,
      },
    };
  return { ...choice, modeId: value };
}
