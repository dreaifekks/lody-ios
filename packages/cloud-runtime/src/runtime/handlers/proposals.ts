import type { Flock } from '@loro-dev/flock-wasm/base64';
import type { AgentRoleItem } from '../../models/agent-roles.ts';
import {
  migrateLegacyAntigravityModeId,
  migrateLegacyAntigravityModeOption,
} from '../../protocol/capability.ts';
import {
  readRole,
  readableRole,
  record,
  resolveCanonicalAgentRoleRunConfig,
  roleRunConfig,
  sensitiveRoleOption,
  type StoredRole,
} from '../../protocol/agent-roles.ts';
import {
  diffPromptLines,
  proposalRule,
  roleProposal,
  scheduleEditProposal,
  scheduleProposal,
  type RoleProposal,
  type ScheduleEditProposal,
  type ScheduleProposal,
} from '../../protocol/proposals.ts';
import {
  canonicalScheduleJson,
  deviceTimeZone,
  type ScheduleDestination,
  type ScheduleDocument,
  type ScheduleProjectRef,
} from '../../protocol/schedules.ts';
import { creationOptions, readRoleTargetCapability } from '../create-session';
import { sessionActionMeta } from '../fork-session';
import { roleSettings } from '../role-settings';
import { scheduleRepository, scheduleStreams } from '../schedules';
import { openSettings } from '../settings';
import { noticeAt, readyHistory, writeNoticeMeta } from '../session';
import type { RuntimeContext } from './context.ts';
import { ruleOf, scheduleMachine, triggerOf } from './schedules.ts';

type Decision = 'accept' | 'dismiss';

/** Codes a proposal action reports; anything else on a write is unknown. */
const KNOWN = new Set([
  'session_not_ready',
  'metadata_not_ready',
  'workspace_changed',
  'proposal_unavailable',
  'proposal_not_requester',
  'role_duplicate',
  'role_read_only',
  'role_forbidden',
  'role_target_unavailable',
  'role_invalid',
  'schedule_target_unavailable',
  'schedule_not_owner',
  'schedule_machine_unsupported',
  'schedule_trigger_invalid',
  'schedule_title_invalid',
  'schedule_conflict',
  'schedule_edit_stale',
  'upload_failed',
]);

/** Web `PROMPT_DIFF` budget for one envelope: a longer diff falls back to the proposed text. */
const PROMPT_DIFF_LINES = 400;

/** Web `scheduleEditProposalActivityId`: RFC 9562 UUIDv8 over a domain-separated SHA-256. */
export async function scheduleEditProposalActivityId(
  sessionId: string,
  proposalId: string,
) {
  const bytes = await crypto.subtle.digest(
    'SHA-256',
    new TextEncoder().encode(
      canonicalScheduleJson([
        'lody.schedule.v1',
        'edit-proposal',
        sessionId,
        proposalId,
      ]),
    ),
  );
  const hex = [...new Uint8Array(bytes)]
    .map((byte) => byte.toString(16).padStart(2, '0'))
    .join('')
    .slice(0, 32)
    .split('');
  hex[12] = '8';
  hex[16] = ((parseInt(hex[16]!, 16) & 3) | 8).toString(16);
  const value = hex.join('');
  return `${value.slice(0, 8)}-${value.slice(8, 12)}-${value.slice(12, 16)}-${value.slice(16, 20)}-${value.slice(20)}`;
}

/** Web `scheduleContentRevision`: pause, resume and manual runs keep it. */
export function scheduleContentRevision(document: ScheduleDocument) {
  const writes = document.timeline.filter(
    (entry) => entry.kind === 'created' || entry.kind === 'edited',
  );
  return writes[writes.length - 1]?.id ?? '';
}

const text = (value: unknown) =>
  typeof value === 'string' ? value.trim() : '';

// Web `BUILTIN_DEFAULT_MODE_IDS`: a schedule never gets an elevated mode nobody chose.
const BUILTIN_DEFAULT_MODES: Record<string, string> = {
  kimi: 'auto',
  grok: 'default',
  claude: 'auto',
  codex: 'agent-auto-review',
  deepseek: 'workspace-write',
};

function projectOf(value: unknown): ScheduleProjectRef | undefined {
  if (!record(value)) return undefined;
  if (value.kind === 'github') {
    const repoFullName = text(value.repoFullName);
    const branch = text(value.branch);
    return /^[^/\s]+\/[^/\s]+$/.test(repoFullName) && branch
      ? { kind: 'github', repoFullName, branch }
      : undefined;
  }
  if (value.kind === 'local') {
    const localProjectId = text(value.localProjectId);
    if (!localProjectId) return undefined;
    const branch = text(value.branch);
    return {
      kind: 'local',
      localProjectId,
      ...(branch ? { branch } : {}),
      ...(typeof value.useWorktree === 'boolean'
        ? { useWorktree: value.useWorktree }
        : {}),
    };
  }
  return undefined;
}

export function registerProposals(ctx: RuntimeContext) {
  const { channel, state, getGrant } = ctx;

  const scope = (workspaceId: string) => {
    const replica = state.metaReplica;
    const userId = state.userId;
    const check = () => {
      if (
        workspaceId !== state.workspace ||
        state.userId !== userId ||
        !replica ||
        state.metaReplica !== replica
      )
        throw new Error('workspace_changed');
    };
    if (!replica || !userId || state.unhealthy.has('meta'))
      throw new Error('metadata_not_ready');
    check();
    const scopedGrant = async () => {
      check();
      const value = await getGrant();
      check();
      return value;
    };
    return { meta: replica.flock, userId, check, scopedGrant };
  };

  const healthyMachines = () =>
    new Map(
      [...state.machineReplicas].filter(([id]) => !state.unhealthy.has(id)),
    );

  async function saveRole(
    proposal: RoleProposal,
    workspaceId: string,
    userId: string,
    meta: Flock,
    scopedGrant: () => ReturnType<RuntimeContext['getGrant']>,
    check: () => void,
  ) {
    const signal = AbortSignal.timeout(35000);
    const machines = healthyMachines();
    const syncWorkspace = {
      onWritten: (written: Flock, created: boolean) => {
        const live = state.workspaceReplica;
        if (created || live?.missing) {
          ctx.refreshWorkspace();
          return;
        }
        if (live && live.synced && !live.missing)
          live.flock.importFile(written.exportFile());
      },
    };
    const list = await roleSettings(
      { workspaceId, action: 'list' },
      userId,
      meta,
      machines,
      scopedGrant,
      signal,
      check,
    );
    if (!('roles' in list)) throw new Error('role_write_unknown');
    const current = list.roles.find(
      (role: AgentRoleItem) => role.id === proposal.roleId,
    );
    if (proposal.action === 'create') {
      // A create retry never replaces a Role that has since been edited (web).
      if (current) return;
      await roleSettings(
        {
          workspaceId,
          action: 'save',
          id: proposal.roleId,
          base: null,
          fields: {
            name: proposal.fields.name ?? '',
            description: proposal.fields.description ?? '',
            promptPrefix: (proposal.fields.promptPrefix ?? '').trim(),
            visibility: 'private',
          },
          target: {
            machineId: proposal.machineId!,
            agentConfigId: proposal.agentConfigId!,
          },
        },
        userId,
        meta,
        machines,
        scopedGrant,
        signal,
        check,
        syncWorkspace,
      );
      return;
    }
    if (!current) throw new Error('proposal_unavailable');
    if (current.ownerUserId !== userId) throw new Error('role_read_only');
    await roleSettings(
      {
        workspaceId,
        action: 'save',
        id: current.id,
        base: current,
        fields: {
          name: proposal.fields.name ?? current.name,
          description: proposal.fields.description ?? current.description,
          promptPrefix: (
            proposal.fields.promptPrefix ?? current.promptPrefix
          ).trim(),
          visibility: current.visibility,
        },
      },
      userId,
      meta,
      machines,
      scopedGrant,
      signal,
      check,
      syncWorkspace,
    );
  }

  /** Web `resolveScheduleProposalTarget` + `ScheduleProposalNotice.create`. */
  async function createSchedule(
    proposal: ScheduleProposal,
    rawMeta: Record<string, unknown>,
    sessionId: string,
    workspaceId: string,
    userId: string,
    meta: Flock,
    scopedGrant: () => ReturnType<RuntimeContext['getGrant']>,
    check: () => void,
  ) {
    const room = `session-${sessionId}`;
    const session = sessionActionMeta(
      meta.get(['m', room]),
      meta.scan({ prefix: ['m', room] }),
      meta.get(['e', room]),
    );
    if (!session) throw new Error('proposal_unavailable');
    const named = proposal.target ?? {};
    const sessionMachine = text(session.machineId);
    let role: StoredRole | undefined;
    let roleTarget: StoredRole['targets'][number] | undefined;
    if (named.agentRoleId) {
      const { flock } = await openSettings(
        `${workspaceId}:wf:workspace`,
        scopedGrant,
        AbortSignal.timeout(30000),
      );
      check();
      role = readRole(
        flock.get(['agentRole', named.agentRoleId]),
        named.agentRoleId,
      );
      if (!role || !readableRole(role, userId))
        throw new Error('schedule_target_unavailable');
      // A Role on several machines runs on the named one, else the conversation's; never guessed.
      let machineId = named.machineId;
      if (!machineId && role.targets.length === 1)
        machineId = role.targets[0]!.machineId;
      else if (
        !machineId &&
        role.targets.some((entry) => entry.machineId === sessionMachine)
      )
        machineId = sessionMachine;
      roleTarget = role.targets.find((entry) => entry.machineId === machineId);
      if (!roleTarget) throw new Error('schedule_target_unavailable');
    }
    const agentConfigId =
      roleTarget?.agentConfigId ??
      named.agentConfigId ??
      text(session.agentConfigId);
    const agents = creationOptions(undefined, meta, healthyMachines()).agents;
    const machineId = named.machineId ?? roleTarget?.machineId;
    const agent =
      agents.find(
        (entry) =>
          entry.id === agentConfigId &&
          entry.machineId === (machineId ?? sessionMachine),
      ) ?? agents.find((entry) => entry.id === agentConfigId);
    if (!agentConfigId || !agent)
      throw new Error('schedule_target_unavailable');
    if (machineId && machineId !== agent.machineId)
      throw new Error('schedule_target_unavailable');
    const host = scheduleMachine(meta, agent.machineId);
    if (host.owner !== userId) throw new Error('schedule_not_owner');
    if (!host.supported) throw new Error('schedule_machine_unsupported');

    // The conversation's run config only carries over to the same Agent.
    const history = await readyHistory(sessionId);
    check();
    const input = history.findLast(
      (entry) => entry.role === 'user',
    )?.inputConfig;
    const latest = record(input) ? input : {};
    let run: {
      modeId?: string;
      modelId?: string;
      configOptionValues?: Record<string, unknown>;
      memory?: { providerId: string; memoryId: string };
    };
    if (roleTarget) {
      const normalized = roleRunConfig(roleTarget.runConfig);
      const canonical = resolveCanonicalAgentRoleRunConfig(normalized, {
        cliType: agent.cliType,
        capability: readRoleTargetCapability(
          state.machineReplicas?.get(agent.machineId),
          agent.id,
          agent,
        ),
      });
      run = {
        modeId: canonical.modeId,
        modelId: canonical.modelId,
        configOptionValues: canonical.configOptionValues,
        memory: normalized.memory,
      };
    } else if (text(session.agentConfigId) === agent.id) {
      const latestMode = text(latest.modeId);
      run = {
        modeId: latestMode
          ? migrateLegacyAntigravityModeId(latestMode)
          : undefined,
        modelId: text(latest.modelId) || undefined,
        configOptionValues: record(latest.configOptionValues)
          ? migrateLegacyAntigravityModeOption(latest.configOptionValues)
          : undefined,
      };
    } else
      run = {
        modeId:
          agent.cliType === 'builtin'
            ? BUILTIN_DEFAULT_MODES[String(agent.agentType)]
            : undefined,
      };
    const options = Object.fromEntries(
      Object.entries(run.configOptionValues ?? {}).filter(
        ([key, value]) =>
          value !== undefined && value !== null && !sensitiveRoleOption(key),
      ),
    );
    let destination: ScheduleDestination = { kind: 'new_session' };
    if (proposal.destination === 'own_session')
      destination = { kind: 'own_session', epoch: 0 };
    else if (proposal.destination === 'existing_session')
      destination = {
        kind: 'existing_session',
        sessionId: proposal.destinationSessionId!,
      };
    // A shared chat carries its own workspace; only a fresh chat takes a project.
    const repoFullName = text(session.repoFullName);
    let project: ScheduleProjectRef | undefined;
    if (destination.kind === 'new_session')
      project =
        projectOf(
          record(rawMeta.target) ? rawMeta.target.project : undefined,
        ) ??
        projectOf(session.project) ??
        projectOf({
          kind: 'github',
          repoFullName,
          branch: text(session.baseBranch) || 'main',
        });
    const now = Date.now();
    const rule = proposalRule(rawMeta.rule);
    if (!rule) throw new Error('proposal_unavailable');
    const trigger = triggerOf(rule, host.timeZone ?? deviceTimeZone(), now);
    const streams = scheduleStreams(
      workspaceId,
      scopedGrant,
      AbortSignal.timeout(65000),
    );
    // The proposal id is the schedule id, so a retried Create cannot make two.
    await scheduleRepository(streams).save({
      scheduleId: proposal.proposalId,
      actorId: userId,
      now,
      activationId: crypto.randomUUID(),
      activityId: `proposal-${proposal.proposalId}`,
      create: true,
      draft: {
        title: proposal.title,
        prompt: proposal.prompt,
        machineId: agent.machineId,
        agent: {
          ...(run.memory ? { memory: run.memory } : {}),
          agentConfigId: agent.id,
          ...(run.modeId ? { modeId: run.modeId } : {}),
          ...(run.modelId ? { modelId: run.modelId } : {}),
          ...(Object.keys(options).length
            ? { configOptionValues: options }
            : {}),
        } as Parameters<
          ReturnType<typeof scheduleRepository>['save']
        >[0]['draft']['agent'],
        ...(project ? { project } : {}),
        destination,
        trigger,
      },
    });
    check();
    return proposal.proposalId;
  }

  /**
   * Web `ScheduleEditProposalNotice`: the live schedule, whether the proposal still
   * applies to it, and the save rule. A landed save (`activityId` in the timeline)
   * still reads as ready, so a retried Apply completes the write.
   */
  async function editTarget(
    proposal: ScheduleEditProposal,
    sessionId: string,
    workspaceId: string,
    userId: string,
    meta: Flock,
    scopedGrant: () => ReturnType<RuntimeContext['getGrant']>,
    check: () => void,
  ) {
    const streams = scheduleStreams(
      workspaceId,
      scopedGrant,
      AbortSignal.timeout(40000),
    );
    const { rows } = await streams.list();
    check();
    const row = rows.find((entry) => entry.scheduleId === proposal.scheduleId);
    const activityId = await scheduleEditProposalActivityId(
      sessionId,
      proposal.proposalId,
    );
    // A deleted schedule keeps its document; only the registry row goes.
    const read = row ? await streams.read(proposal.scheduleId) : undefined;
    check();
    const document = read && !read.message ? read.document : null;
    if (!row || !document)
      return { state: 'unavailable' as const, activityId, streams };
    const definition = document.definition;
    const host = scheduleMachine(meta, definition.machineId);
    const isOwner = definition.ownerId === userId && row.ownerId === userId;
    const landed = document.timeline.some((entry) => entry.id === activityId);
    let state:
      | 'ready'
      | 'stale'
      | 'not_owner'
      | 'machine_unsupported'
      | 'target_unavailable' = 'ready';
    const agent = creationOptions(
      undefined,
      meta,
      healthyMachines(),
    ).agents.find(
      (entry) =>
        entry.id === definition.agent.agentConfigId &&
        entry.machineId === definition.machineId,
    );
    if (
      !landed &&
      scheduleContentRevision(document) !== proposal.baseActivityId
    )
      state = 'stale';
    else if (!isOwner || host.owner !== userId) state = 'not_owner';
    else if (!host.supported) state = 'machine_unsupported';
    else if (!agent) state = 'target_unavailable';
    return {
      state,
      activityId,
      streams,
      document,
      landed,
      isOwner,
      timeZone: host.timeZone ?? deviceTimeZone(),
    };
  }

  async function applyScheduleEdit(
    proposal: ScheduleEditProposal,
    sessionId: string,
    workspaceId: string,
    userId: string,
    meta: Flock,
    scopedGrant: () => ReturnType<RuntimeContext['getGrant']>,
    check: () => void,
  ) {
    const target = await editTarget(
      proposal,
      sessionId,
      workspaceId,
      userId,
      meta,
      scopedGrant,
      check,
    );
    if (target.state === 'unavailable') throw new Error('proposal_unavailable');
    if (target.state === 'stale') throw new Error('schedule_edit_stale');
    if (target.state === 'not_owner') throw new Error('schedule_not_owner');
    if (target.state === 'machine_unsupported')
      throw new Error('schedule_machine_unsupported');
    if (target.state === 'target_unavailable')
      throw new Error('schedule_target_unavailable');
    // Web `applyScheduleEditProposal`: the proposed fields over the live schedule.
    const { document } = target;
    const current = document.definition;
    const patch = target.landed ? {} : proposal.patch;
    const now = Date.now();
    await scheduleRepository(target.streams).save({
      scheduleId: proposal.scheduleId,
      actorId: userId,
      now,
      activationId: crypto.randomUUID(),
      activityId: target.activityId,
      create: false,
      draft: {
        title: patch.title ?? current.title,
        prompt: patch.prompt ?? document.prompt,
        machineId: current.machineId,
        agent: current.agent,
        ...(current.project ? { project: current.project } : {}),
        destination: current.destination,
        trigger: patch.rule
          ? triggerOf(patch.rule, target.timeZone, now, current.trigger)
          : current.trigger,
      },
    });
    check();
  }

  channel.handle('inspectProposal', async (args) => {
    try {
      const { meta, userId, check, scopedGrant } = scope(args.workspaceId);
      const notice = await noticeAt(args);
      check();
      const proposal =
        notice?.name === 'schedule_edit_proposal'
          ? scheduleEditProposal(notice.meta)
          : undefined;
      if (!proposal) throw new Error('proposal_unavailable');
      const target = await editTarget(
        proposal,
        args.sessionId,
        args.workspaceId,
        userId,
        meta,
        scopedGrant,
        check,
      );
      if (target.state === 'unavailable')
        return {
          state: 'unavailable',
          isOwner: false,
          timeZone: deviceTimeZone(),
        };
      const { document } = target;
      const diff =
        proposal.patch.prompt === undefined
          ? null
          : diffPromptLines(document.prompt, proposal.patch.prompt);
      return {
        state: target.state,
        isOwner: target.isOwner,
        currentTitle: document.definition.title,
        currentRule: ruleOf(document.definition.trigger),
        timeZone: target.timeZone,
        ...(diff && diff.length <= PROMPT_DIFF_LINES
          ? { promptDiff: diff }
          : {}),
      };
    } catch (error) {
      const code = error instanceof Error ? error.message : '';
      if (KNOWN.has(code)) throw error;
      throw new Error('proposal_unavailable');
    }
  });

  channel.handle('decideProposal', async (args) => {
    const decision: Decision = args.decision;
    try {
      const { meta, userId, check, scopedGrant } = scope(args.workspaceId);
      const notice = await noticeAt(args);
      check();
      if (!notice) throw new Error('proposal_unavailable');
      const target = {
        sessionId: args.sessionId,
        entryId: args.entryId,
        itemId: args.itemId,
        name: notice.name,
      };
      if (notice.name === 'agent_role_proposal') {
        const proposal = roleProposal(notice.meta);
        if (!proposal) throw new Error('proposal_unavailable');
        if (proposal.requesterUserId !== userId)
          throw new Error('proposal_not_requester');
        if (proposal.outcome) return { outcome: proposal.outcome };
        if (decision === 'accept')
          await saveRole(
            proposal,
            args.workspaceId,
            userId,
            meta,
            scopedGrant,
            check,
          );
        check();
        const outcome = decision === 'accept' ? 'saved' : 'dismissed';
        await writeNoticeMeta({ ...target, patch: { outcome } });
        return { outcome };
      }
      if (notice.name === 'schedule_proposal') {
        const proposal = scheduleProposal(notice.meta);
        if (!proposal || !record(notice.meta))
          throw new Error('proposal_unavailable');
        if (proposal.outcome)
          return {
            outcome: proposal.outcome,
            ...(proposal.scheduleId ? { scheduleId: proposal.scheduleId } : {}),
          };
        if (decision === 'dismiss') {
          await writeNoticeMeta({ ...target, patch: { outcome: 'dismissed' } });
          return { outcome: 'dismissed' };
        }
        const scheduleId = await createSchedule(
          proposal,
          notice.meta,
          args.sessionId,
          args.workspaceId,
          userId,
          meta,
          scopedGrant,
          check,
        );
        check();
        await writeNoticeMeta({
          ...target,
          patch: { outcome: 'created', scheduleId },
        });
        return { outcome: 'created', scheduleId };
      }
      if (notice.name === 'schedule_edit_proposal') {
        const proposal = scheduleEditProposal(notice.meta);
        if (!proposal) throw new Error('proposal_unavailable');
        if (proposal.outcome)
          return {
            outcome: proposal.outcome,
            ...(proposal.outcome === 'applied'
              ? { scheduleId: proposal.scheduleId }
              : {}),
          };
        if (decision === 'accept')
          await applyScheduleEdit(
            proposal,
            args.sessionId,
            args.workspaceId,
            userId,
            meta,
            scopedGrant,
            check,
          );
        else {
          // Web: only the schedule owner may ignore it; a deleted schedule may be ignored.
          const live = await editTarget(
            proposal,
            args.sessionId,
            args.workspaceId,
            userId,
            meta,
            scopedGrant,
            check,
          );
          if (live.state !== 'unavailable' && !live.isOwner)
            throw new Error('schedule_not_owner');
        }
        check();
        const outcome = decision === 'accept' ? 'applied' : 'dismissed';
        await writeNoticeMeta({ ...target, patch: { outcome } });
        return {
          outcome,
          ...(outcome === 'applied' ? { scheduleId: proposal.scheduleId } : {}),
        };
      }
      throw new Error('proposal_unavailable');
    } catch (error) {
      const code = error instanceof Error ? error.message : '';
      if (KNOWN.has(code)) throw error;
      // The write may have landed; the card offers an explicit retry, never a replay.
      if (code.startsWith('schedule_'))
        throw new Error('schedule_write_unknown');
      if (code.startsWith('role_')) throw new Error('role_write_unknown');
      throw new Error('proposal_write_unknown');
    }
  });
}
