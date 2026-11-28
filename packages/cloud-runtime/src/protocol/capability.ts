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
  dontAsk: 'ask',
  bypassPermissions: 'full',
  // Codex
  agent: 'edit',
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

const isModelSelectorOption = (
  option: Pick<ConfigOption, 'category' | 'type'>,
) => option.category === 'model' && option.type === 'select';

/**
 * Aligns with Lody `resolveAcpConfigOptionsForModel`: keeps the snapshot's
 * model selector and order while substituting the target model's observed
 * option list when recorded.
 */
export function resolveConfigOptionsForModel<
  T extends Pick<ConfigOption, 'id' | 'category' | 'type'> & {
    currentValue?: string | boolean;
  },
>(
  snapshot: readonly T[] | undefined,
  observedByModel: Readonly<Record<string, readonly T[]>> | undefined,
  modelId: string | null | undefined,
): readonly T[] | undefined {
  const currentModel = snapshot?.find(isModelSelectorOption)?.currentValue;
  const snapshotModelId =
    typeof currentModel === 'string' && currentModel.length > 0
      ? currentModel
      : undefined;
  if (!modelId || modelId === snapshotModelId) return snapshot;
  const observed = observedByModel?.[modelId];
  if (!observed) return snapshot;
  const observedById = new Map(observed.map((option) => [option.id, option]));
  const composed: T[] = [];
  const used = new Set<string>();
  for (const option of snapshot ?? []) {
    if (isModelSelectorOption(option)) {
      composed.push(option);
      continue;
    }
    const replacement = observedById.get(option.id);
    if (replacement) {
      composed.push(replacement);
      used.add(option.id);
    }
  }
  for (const option of observed) {
    if (!used.has(option.id) && !isModelSelectorOption(option))
      composed.push(option);
  }
  return composed;
}

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

const isFastToggleOption = (option: Pick<ConfigOption, 'id' | 'type'>) =>
  ['fast-mode', 'fast'].includes(option.id) && option.type === 'boolean';

const isPermissionOrModeSelectorOption = (option: ConfigOption) =>
  option.type === 'select' &&
  (option.id === 'permission_mode' ||
    option.category === '_permission' ||
    (option.category === 'mode' &&
      option.id !== 'interaction_mode' &&
      !isThoughtLevel(option)));

function selectedModelIdFor(
  capability: Capability | undefined,
  choice: ModelChoice,
): string | undefined {
  const modelOption = capability?.configOptions?.find(isModelSelectorOption);
  const rawOptionModel = modelOption
    ? choice.configOptionValues?.[modelOption.id]
    : undefined;
  const optionModel =
    typeof rawOptionModel === 'string' && rawOptionModel.trim()
      ? rawOptionModel.trim()
      : undefined;
  const topModel =
    typeof choice.modelId === 'string' && choice.modelId.trim()
      ? choice.modelId.trim()
      : undefined;
  const isConfigOptionDriven =
    capability?.cliType === 'registry' || capability?.cliType === 'custom';
  if (isConfigOptionDriven) return optionModel ?? topModel;
  return topModel ?? optionModel;
}

function permissionOptionIdsFor(
  capability: Capability | undefined,
): Set<string> {
  const ids = new Set<string>(['mode', 'permission_mode']);
  for (const option of capability?.configOptions ?? []) {
    if (isPermissionOrModeSelectorOption(option)) ids.add(option.id);
  }
  for (const options of Object.values(
    capability?.observedModelConfigOptions ?? {},
  )) {
    for (const option of options) {
      if (isPermissionOrModeSelectorOption(option)) ids.add(option.id);
    }
  }
  return ids;
}

export function fastModeFor(
  capability: Capability | undefined,
  choice: ModelChoice,
) {
  const snapshotModel = capability?.configOptions?.find(
    (o) => o.category === 'model',
  )?.currentValue;
  const model =
    selectedModelIdFor(capability, choice) ??
    (typeof snapshotModel === 'string' && snapshotModel.length > 0
      ? snapshotModel
      : undefined);
  if (typeof model === 'string' && capability?.fastModes?.[model] === false)
    return undefined;
  const resolvedOptions = resolveConfigOptionsForModel(
    capability?.configOptions,
    capability?.observedModelConfigOptions,
    model,
  );
  let option = resolvedOptions?.find(isFastToggleOption);
  if (
    !option &&
    typeof model === 'string' &&
    capability?.fastModes?.[model] === true
  ) {
    option = capability.configOptions?.find(isFastToggleOption) ?? {
      id: capability.agentType === 'claude' ? 'fast' : 'fast-mode',
      name: 'Fast',
      type: 'boolean',
      currentValue: false,
      options: [],
    };
  }
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

// Match OSS resolvePermissionModeFace: explicit permissions, config-option
// modes on registry/custom agents, legacy modes, then generic mode fallback.
// Interaction mode is a separate control.
export function permissionModeFor(
  capability: Capability | undefined,
  choice: ModelChoice,
) {
  const isConfigOptionDriven =
    capability?.cliType === 'registry' || capability?.cliType === 'custom';
  const targetModelId = selectedModelIdFor(capability, choice);
  const resolvedOptions = resolveConfigOptionsForModel(
    capability?.configOptions,
    capability?.observedModelConfigOptions,
    targetModelId,
  );
  const selectors =
    resolvedOptions?.filter((item) => item.type === 'select') ?? [];
  let option = selectors.find(
    (item) => item.id === 'permission_mode' || item.category === '_permission',
  );
  if (!option && isConfigOptionDriven) {
    option = selectors.find(
      (item) =>
        item.category === 'mode' &&
        item.id !== 'interaction_mode' &&
        !isThoughtLevel(item),
    );
  }
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
  const fallbackMode =
    isConfigOptionDriven &&
    rawSelected === undefined &&
    typeof choice.modeId === 'string'
      ? choice.modeId
      : undefined;
  const rawCandidate = rawSelected ?? fallbackMode;
  const selected =
    option.id === 'mode' && typeof rawCandidate === 'string'
      ? migrateLegacyAntigravityModeId(rawCandidate)
      : rawCandidate;
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
  const isConfigOptionDriven =
    capability?.cliType === 'registry' || capability?.cliType === 'custom';
  if (permission.configId) {
    const nextConfig: Record<string, string | boolean> = {
      ...choice.configOptionValues,
    };
    if (isConfigOptionDriven) {
      for (const stale of permissionOptionIdsFor(capability)) {
        if (stale !== permission.configId) delete nextConfig[stale];
      }
    }
    nextConfig[permission.configId] = value;
    if (isConfigOptionDriven) {
      const { modeId: _staleModeId, ...rest } = choice;
      return { ...rest, configOptionValues: nextConfig };
    }
    return { ...choice, configOptionValues: nextConfig };
  }
  if (isConfigOptionDriven && choice.configOptionValues) {
    const nextConfig = { ...choice.configOptionValues };
    for (const stale of permissionOptionIdsFor(capability)) {
      delete nextConfig[stale];
    }
    const { configOptionValues: _oldConfig, ...rest } = choice;
    return {
      ...rest,
      modeId: value,
      ...(Object.keys(nextConfig).length
        ? { configOptionValues: nextConfig }
        : {}),
    };
  }
  return { ...choice, modeId: value };
}
