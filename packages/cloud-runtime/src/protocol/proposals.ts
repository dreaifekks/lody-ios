/**
 * Agent proposals carried as `system_notice` items (web `AgentRoleProposalNotice`,
 * `ScheduleProposalNotice` and `ScheduleEditProposalNotice`), read into a bounded presentation for the native
 * transcript cards. Stored history stays as written; anything malformed is not a
 * proposal and the notice keeps its generic row.
 */

type RecordValue = Record<string, unknown>;

const record = (value: unknown): value is RecordValue =>
  !!value && typeof value === 'object' && !Array.isArray(value);
const id = (value: unknown): value is string =>
  typeof value === 'string' && value.trim().length > 0 && value.length <= 128;
const bounded = (value: unknown, max: number): string | undefined =>
  typeof value === 'string' && value.length <= max ? value : undefined;
const integer = (value: unknown, min: number, max: number) =>
  typeof value === 'number' &&
  Number.isInteger(value) &&
  value >= min &&
  value <= max;

export type RoleProposalFields = {
  name?: string;
  description?: string;
  promptPrefix?: string;
};

export type RoleProposal = {
  kind: 'agent_role';
  action: 'create' | 'update';
  roleId: string;
  requesterUserId: string;
  /** What the Role becomes: the full create, or only the patched fields. */
  fields: RoleProposalFields;
  /** The Role's content when the update was proposed. */
  before?: RoleProposalFields;
  /** `create`: the Agent configuration the private Role targets. */
  machineId?: string;
  agentConfigId?: string;
  outcome?: 'saved' | 'dismissed';
};

/** The contract `ScheduleRule` shape (`once.at` in epoch milliseconds). */
export type ProposalRule = {
  kind:
    | 'manual'
    | 'once'
    | 'minutes'
    | 'hours'
    | 'daily'
    | 'weekdays'
    | 'weekly'
    | 'monthly';
  every?: number;
  hour?: number;
  minute?: number;
  weekdays?: number[];
  days?: number[];
  at?: number;
  timeZone?: string;
};

export type ScheduleProposal = {
  kind: 'schedule';
  proposalId: string;
  title: string;
  prompt: string;
  rule: ProposalRule;
  destination: 'new_session' | 'own_session' | 'existing_session';
  destinationSessionId?: string;
  target?: {
    agentConfigId?: string;
    agentRoleId?: string;
    machineId?: string;
  };
  outcome?: 'created' | 'dismissed';
  scheduleId?: string;
};

/** Web `ScheduleEditProposalMeta`: only `patch` fields change, against `baseActivityId`. */
export type ScheduleEditProposal = {
  kind: 'schedule_edit';
  proposalId: string;
  scheduleId: string;
  /** The schedule's name when proposed. */
  title: string;
  patch: { title?: string; prompt?: string; rule?: ProposalRule };
  baseActivityId: string;
  outcome?: 'applied' | 'dismissed';
};

export type ProposalPresentation =
  RoleProposal | ScheduleProposal | ScheduleEditProposal;

function roleFields(value: unknown): RoleProposalFields | undefined {
  if (!record(value)) return undefined;
  const name = bounded(value.name, 60);
  const description = bounded(value.description, 560);
  const promptPrefix = bounded(value.promptPrefix, 32768);
  if (
    (value.name !== undefined && name === undefined) ||
    (value.description !== undefined && description === undefined) ||
    (value.promptPrefix !== undefined && promptPrefix === undefined)
  )
    return undefined;
  return {
    ...(name !== undefined ? { name } : {}),
    ...(description !== undefined ? { description } : {}),
    ...(promptPrefix !== undefined ? { promptPrefix } : {}),
  };
}

export function roleProposal(meta: unknown): RoleProposal | undefined {
  if (!record(meta) || !record(meta.command)) return undefined;
  const command = meta.command;
  if (!id(meta.roleId) || !id(meta.requesterUserId) || !id(command.requestId))
    return undefined;
  const outcome =
    meta.outcome === 'saved' || meta.outcome === 'dismissed'
      ? meta.outcome
      : undefined;
  if (meta.outcome !== undefined && !outcome) return undefined;
  const before =
    meta.before === undefined ? undefined : roleFields(meta.before);
  if (meta.before !== undefined && !before?.name) return undefined;
  if (command.action === 'create') {
    const fields = roleFields(command);
    if (!fields?.name || !id(command.machineId) || !id(command.agentConfigId))
      return undefined;
    return {
      kind: 'agent_role',
      action: 'create',
      roleId: meta.roleId,
      requesterUserId: meta.requesterUserId,
      fields,
      machineId: command.machineId,
      agentConfigId: command.agentConfigId,
      ...(outcome ? { outcome } : {}),
    };
  }
  if (command.action === 'update') {
    const fields = roleFields(command.patch);
    if (
      !fields ||
      !Object.keys(fields).length ||
      command.roleId !== meta.roleId
    )
      return undefined;
    return {
      kind: 'agent_role',
      action: 'update',
      roleId: meta.roleId,
      requesterUserId: meta.requesterUserId,
      fields,
      ...(before ? { before } : {}),
      ...(outcome ? { outcome } : {}),
    };
  }
  return undefined;
}

const zone = (value: unknown) =>
  value === undefined ? undefined : bounded(value, 100);

/** Web `SCHEDULE_CUSTOM_STEP_MAX`: Android carries `every` as a 32-bit `Int`. */
const STEP_MAX = 2_147_483_647;

/** Web `ScheduleProposalRuleSchema`, as the editor's named rule. */
export function proposalRule(value: unknown): ProposalRule | undefined {
  if (!record(value)) return undefined;
  const timeZone = zone(value.timeZone);
  if (value.timeZone !== undefined && !timeZone) return undefined;
  const clock = () =>
    integer(value.hour, 0, 23) && integer(value.minute, 0, 59)
      ? {
          hour: value.hour as number,
          minute: value.minute as number,
          ...(timeZone ? { timeZone } : {}),
        }
      : undefined;
  switch (value.kind) {
    case 'manual':
      return { kind: 'manual' };
    case 'minutes':
      return integer(value.every, 1, STEP_MAX)
        ? { kind: 'minutes', every: value.every as number }
        : undefined;
    case 'hours':
      return integer(value.every, 1, STEP_MAX)
        ? { kind: 'hours', every: value.every as number }
        : undefined;
    case 'daily':
    case 'weekdays': {
      const time = clock();
      return time ? { kind: value.kind, ...time } : undefined;
    }
    case 'weekly': {
      const time = clock();
      const weekdays = value.weekdays;
      if (
        !time ||
        !Array.isArray(weekdays) ||
        !weekdays.length ||
        weekdays.length > 7 ||
        !weekdays.every((day) => integer(day, 0, 6))
      )
        return undefined;
      return {
        kind: 'weekly',
        weekdays: [...new Set(weekdays as number[])].sort((a, b) => a - b),
        ...time,
      };
    }
    case 'monthly': {
      const time = clock();
      const days = value.days;
      if (
        !time ||
        !Array.isArray(days) ||
        !days.length ||
        days.length > 31 ||
        !days.every((day) => integer(day, 1, 31))
      )
        return undefined;
      return {
        kind: 'monthly',
        days: [...new Set(days as number[])].sort((a, b) => a - b),
        ...time,
      };
    }
    case 'once': {
      const at = typeof value.at === 'string' ? Date.parse(value.at) : NaN;
      return Number.isFinite(at) ? { kind: 'once', at } : undefined;
    }
  }
  return undefined;
}

export function scheduleProposal(meta: unknown): ScheduleProposal | undefined {
  if (!record(meta) || !id(meta.proposalId)) return undefined;
  const title = bounded(meta.title, 200)?.trim();
  const prompt = bounded(meta.prompt, 32768);
  const rule = proposalRule(meta.rule);
  if (!title || !prompt || !rule) return undefined;
  const destination = record(meta.destination) ? meta.destination : undefined;
  let kind: ScheduleProposal['destination'] = 'new_session';
  let destinationSessionId: string | undefined;
  if (destination?.kind === 'own_session') kind = 'own_session';
  else if (destination?.kind === 'existing_session') {
    if (!id(destination.sessionId)) return undefined;
    kind = 'existing_session';
    destinationSessionId = destination.sessionId;
  } else if (destination && destination.kind !== 'new_session')
    return undefined;
  const named = record(meta.target) ? meta.target : undefined;
  const target = named
    ? {
        ...(id(named.agentConfigId)
          ? { agentConfigId: named.agentConfigId }
          : {}),
        ...(id(named.agentRoleId) ? { agentRoleId: named.agentRoleId } : {}),
        ...(id(named.machineId) ? { machineId: named.machineId } : {}),
      }
    : undefined;
  const outcome =
    meta.outcome === 'created' || meta.outcome === 'dismissed'
      ? meta.outcome
      : undefined;
  return {
    kind: 'schedule',
    proposalId: meta.proposalId,
    title,
    prompt,
    rule,
    destination: kind,
    ...(destinationSessionId ? { destinationSessionId } : {}),
    ...(target && Object.keys(target).length ? { target } : {}),
    ...(outcome ? { outcome } : {}),
    ...(outcome === 'created' && id(meta.scheduleId)
      ? { scheduleId: meta.scheduleId }
      : {}),
  };
}

/** Web `ScheduleEditProposalMetaSchema`; an empty or malformed patch is not a proposal. */
export function scheduleEditProposal(
  meta: unknown,
): ScheduleEditProposal | undefined {
  if (!record(meta) || !id(meta.proposalId) || !id(meta.scheduleId))
    return undefined;
  const title = bounded(meta.title, 200)?.trim();
  if (!title || typeof meta.baseActivityId !== 'string' || !record(meta.patch))
    return undefined;
  const raw = meta.patch;
  if (
    Object.keys(raw).some((key) => !['title', 'prompt', 'rule'].includes(key))
  )
    return undefined;
  const patch: ScheduleEditProposal['patch'] = {};
  if (raw.title !== undefined) {
    const next = bounded(raw.title, 200)?.trim();
    if (!next) return undefined;
    patch.title = next;
  }
  if (raw.prompt !== undefined) {
    const next = bounded(raw.prompt, 32768);
    if (!next) return undefined;
    patch.prompt = next;
  }
  if (raw.rule !== undefined) {
    const next = proposalRule(raw.rule);
    if (!next) return undefined;
    patch.rule = next;
  }
  if (!Object.keys(patch).length) return undefined;
  const outcome =
    meta.outcome === 'applied' || meta.outcome === 'dismissed'
      ? meta.outcome
      : undefined;
  if (meta.outcome !== undefined && !outcome) return undefined;
  return {
    kind: 'schedule_edit',
    proposalId: meta.proposalId,
    scheduleId: meta.scheduleId,
    title,
    patch,
    baseActivityId: meta.baseActivityId,
    ...(outcome ? { outcome } : {}),
  };
}

export type PromptDiffLine = {
  kind: 'same' | 'add' | 'del' | 'gap';
  text: string;
};

const PROMPT_DIFF_MAX_CELLS = 4_000_000;

/**
 * Web `diffPromptLines`: a line diff that keeps `context` unchanged lines beside each
 * change and folds the rest into one `gap`; `null` when equal or too long to compare.
 */
export function diffPromptLines(
  before: string,
  after: string,
  context = 2,
): PromptDiffLine[] | null {
  const a = before.split('\n');
  const b = after.split('\n');
  const width = b.length + 1;
  if (before === after || (a.length + 1) * width > PROMPT_DIFF_MAX_CELLS)
    return null;
  const lcs = new Uint16Array((a.length + 1) * width);
  const at = (i: number, j: number) => lcs[i * width + j] ?? 0;
  for (let i = a.length - 1; i >= 0; i--)
    for (let j = b.length - 1; j >= 0; j--)
      lcs[i * width + j] =
        a[i] === b[j]
          ? at(i + 1, j + 1) + 1
          : Math.max(at(i + 1, j), at(i, j + 1));
  const lines: PromptDiffLine[] = [];
  let i = 0;
  let j = 0;
  while (i < a.length || j < b.length) {
    if (i < a.length && j < b.length && a[i] === b[j]) {
      lines.push({ kind: 'same', text: a[i] ?? '' });
      i++;
      j++;
    } else if (j >= b.length || (i < a.length && at(i + 1, j) >= at(i, j + 1)))
      lines.push({ kind: 'del', text: a[i++] ?? '' });
    else lines.push({ kind: 'add', text: b[j++] ?? '' });
  }
  const keep = lines.map((_, index) =>
    lines
      .slice(Math.max(0, index - context), index + context + 1)
      .some((line) => line.kind !== 'same'),
  );
  return lines.flatMap((line, index) => {
    if (keep[index]) return [line];
    return keep[index - 1] === false
      ? []
      : [{ kind: 'gap' as const, text: '' }];
  });
}

/** The proposal a notice carries, or undefined for any other notice. */
export function proposalOf(
  name: string,
  meta: unknown,
): ProposalPresentation | undefined {
  if (name === 'agent_role_proposal') return roleProposal(meta);
  if (name === 'schedule_proposal') return scheduleProposal(meta);
  if (name === 'schedule_edit_proposal') return scheduleEditProposal(meta);
  return undefined;
}
