import type { Flock } from '@loro-dev/flock-wasm/base64';
import type { MentionCatalog, MentionItem } from '../../../src/models/mentions';
import { openSettings } from './settings';

// Shared workspace catalog owner for Role consumers. Authorization is checked
// from the fresh row on every read; the UI never supplies Role instructions.
export async function workspaceRoleMentions(
  workspaceId: string,
  userId: string,
  machines: Map<string, Flock>,
  machineId: string | undefined,
  getGrant: Parameters<typeof openSettings>[1],
): Promise<MentionCatalog> {
  const { flock } = await openSettings(
    `${workspaceId}:wf:workspace`,
    getGrant,
    AbortSignal.timeout(30000),
  );
  return roleMentions(flock.scan(), userId, machines, machineId);
}

type Row = Record<string, unknown>;
type Instance = {
  id: string;
  alias?: string;
  machineId: string;
  agentConfigId: string;
};

const validText = (value: unknown): value is string =>
  typeof value === 'string' &&
  value.length > 0 &&
  value.length <= 4096 &&
  !/[\x00-\x1f\x7f]/.test(value);

/**
 * A Role is a template and its instances are what run. A row written before
 * instances names one machine, which Lody reads as a single instance under a
 * derived id (`legacyAgentRoleInstanceId`).
 */
function roleInstances(role: Row): Instance[] {
  const instances: Instance[] = [];
  for (const entry of Array.isArray(role.instances) ? role.instances : []) {
    const value = (entry ?? {}) as Row;
    if (
      !validText(value.id) ||
      !validText(value.machineId) ||
      !validText(value.agentConfigId) ||
      instances.some((instance) => instance.id === value.id)
    )
      continue;
    const alias = typeof value.alias === 'string' ? value.alias.trim() : '';
    instances.push({
      id: value.id,
      ...(alias ? { alias } : {}),
      machineId: value.machineId,
      agentConfigId: value.agentConfigId,
    });
  }
  if (instances.length) return instances;
  return [
    {
      id: `${role.id}:${role.machineId}`,
      machineId: role.machineId as string,
      agentConfigId: role.agentConfigId as string,
    },
  ];
}

// Lody's BUILTIN_AGENTS and agent brands, which name an instance nobody aliased.
const builtinAgentNames: Record<string, string> = {
  kimi: 'Kimi Code',
  devin: 'Devin',
  grok: 'Grok',
  claude: 'Claude Code',
  codex: 'Codex',
  pi: 'Pi',
  deepseek: 'DeepSeek Harness',
  bub: 'Bub',
  dimcode: 'Dimcode',
};
const brandHosts: Record<string, string[]> = {
  deepseek: ['deepseek.com'],
  mimo: ['xiaomimimo.com'],
  minimax: ['minimaxi.com', 'minimax.io'],
  glm: ['bigmodel.cn', 'z.ai'],
};

function agentBrand(agent: Row) {
  if (
    typeof agent.brandId === 'string' &&
    Object.hasOwn(brandHosts, agent.brandId)
  )
    return agent.brandId;
  let host: string;
  try {
    host = new URL(
      String((agent.env as Row | undefined)?.ANTHROPIC_BASE_URL),
    ).hostname.toLowerCase();
  } catch {
    return undefined;
  }
  return Object.keys(brandHosts).find((brand) =>
    brandHosts[brand].some(
      (suffix) => host === suffix || host.endsWith(`.${suffix}`),
    ),
  );
}

/**
 * Lody's instance groups: instances sharing an alias, or without one sharing
 * an agent family, stand in for each other across machines. The group's name
 * is the alias, else the family's.
 */
function instanceGroup(instance: Instance, agent: Row | undefined) {
  if (instance.alias)
    return {
      key: `alias:${instance.alias.toLowerCase()}`,
      name: instance.alias,
    };
  if (!agent) return { key: `config:${instance.agentConfigId}`, name: '' };
  const brand = agentBrand(agent);
  // A provider brand is a family of its own, named like a custom or registry
  // agent by its config; Lody's registry names are not carried here.
  const family =
    !brand && agent.cliType === 'builtin'
      ? builtinAgentNames[String(agent.agentType)]
      : undefined;
  return {
    key: `agent:${[agent.cliType, agent.agentType, brand].filter(Boolean).join(':')}`,
    name: family ?? String(agent.name ?? ''),
  };
}

export function roleMentions(
  rows: { key: unknown[]; value?: unknown }[],
  userId: string,
  machines: Map<string, Pick<Flock, 'get'>>,
  machineId?: string,
): MentionCatalog {
  const entries: {
    id: string;
    name: string;
    group: number;
    item: MentionItem;
  }[] = [];
  for (const row of rows) {
    if (
      row.key.length !== 2 ||
      row.key[0] !== 'agentRole' ||
      !row.value ||
      typeof row.value !== 'object'
    )
      continue;
    const role = row.value as Row;
    const { id, name } = role;
    if (
      role.v !== 1 ||
      id !== row.key[1] ||
      !validText(id) ||
      /\s/.test(id) ||
      !validText(name) ||
      !validText(role.ownerUserId) ||
      !validText(role.machineId) ||
      !validText(role.agentConfigId) ||
      !['private', 'workspace'].includes(String(role.visibility)) ||
      (role.visibility !== 'workspace' && role.ownerUserId !== userId) ||
      typeof role.revision !== 'number' ||
      !Number.isFinite(role.revision)
    )
      continue;
    const summary =
      typeof role.promptPrefix === 'string'
        ? role.promptPrefix.slice(0, 512)
        : '';
    const groups = new Map<
      string,
      { name: string; usable: { instance: Instance; agent: Row }[] }
    >();
    for (const instance of roleInstances(role)) {
      const stored = machines
        .get(instance.machineId)
        ?.get(['agentConfig', instance.agentConfigId]) as Row | undefined;
      const agent =
        stored?.id === instance.agentConfigId &&
        stored.machineId === instance.machineId
          ? stored
          : undefined;
      const identity = instanceGroup(instance, agent);
      const group = groups.get(identity.key) ?? {
        name: identity.name,
        usable: [],
      };
      groups.set(identity.key, group);
      // The token carries the instance id, and ends at whitespace or `@`.
      if (
        agent &&
        !/[\s@]/.test(instance.id) &&
        (machineId === undefined || instance.machineId === machineId)
      )
        group.usable.push({ instance, agent });
    }
    // One entry per group: its instance on this machine, or without a machine
    // its first one. Sibling groups are told apart by their names.
    [...groups.values()].forEach((group, index) => {
      const [first] = group.usable;
      if (!first) return;
      entries.push({
        id,
        name,
        group: index,
        item: {
          path: first.instance.id,
          name: groups.size > 1 ? `${name} · ${group.name}` : name,
          kind: 'role',
          subtitle: summary || String(first.agent.name ?? ''),
          insertText: `@role:${first.instance.id}`,
          role: { id, name, instance: group.name },
        },
      });
    });
  }
  entries.sort(
    (a, b) =>
      a.name.localeCompare(b.name) ||
      a.id.localeCompare(b.id) ||
      a.group - b.group,
  );
  return {
    items: entries.map((entry) => entry.item),
    truncated: false,
    incomplete: false,
  };
}
