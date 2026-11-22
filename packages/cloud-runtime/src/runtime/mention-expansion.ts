import { buildSessionLink } from '../protocol/sessionLink.ts';
import type {
  MentionCatalog,
  MentionCategory,
  MentionItem,
} from '../models/mentions';

// Explicit session and Role instance IDs survive native text-only draft
// restoration and renames. Quoted file references own their text, including
// any dollar signs. A session/Role chip may follow non-ASCII text with no space
// (`让@role:<id>`); a skill keeps its whitespace boundary so prose like `价格$5`
// stays prose.
const referencePattern =
  /@"(?:\\.|[^"\\])*"|(^|\s)(\$[^\s$@]+)(?=\s|$)|(^|\s|(?<![\w$@./:-]))(@session:[^\s@]+|@role:[^\s@]+(?:@[^\s@]+){0,2})(?=\s|$)/g;

function categoryOf(token: string): MentionCategory {
  if (token.startsWith('$')) return 'skill';
  if (token.startsWith('@session:')) return 'session';
  return 'role';
}

export async function expandMentions(
  text: string,
  load: (category: MentionCategory) => Promise<MentionCatalog>,
  workspaceId?: string,
): Promise<string> {
  const categories = new Set<MentionCategory>();
  for (const match of text.matchAll(referencePattern)) {
    const token = match[2] ?? match[4];
    if (token) categories.add(categoryOf(token));
  }
  try {
    const catalogs = await Promise.all([...categories].map(load));
    // A partial skill scan can hide the project override of a global token.
    if (catalogs.some((catalog) => catalog.incomplete || catalog.truncated))
      throw new Error('mention_catalog_incomplete');
    const items = catalogs.flatMap((catalog) => catalog.items);
    for (const match of text.matchAll(referencePattern))
      if (
        match[4]?.startsWith('@role:') &&
        !items.some((item) => item.insertText === match[4])
      )
        throw new Error('role_unavailable');
    return expandMentionText(text, items, workspaceId);
  } catch {
    throw new Error('mention_expansion_failed');
  }
}

export function expandMentionText(
  text: string,
  items: readonly MentionItem[],
  workspaceId?: string,
): string {
  const byToken = new Map<string, MentionItem>();
  const ambiguous = new Set<string>();
  for (const item of items) {
    if (!item.insertText) continue;
    if (byToken.has(item.insertText)) ambiguous.add(item.insertText);
    byToken.set(item.insertText, item);
  }
  // One pass over the original text: expansion text is never re-interpreted.
  return text.replace(
    referencePattern,
    (
      whole,
      skillSpace: string | undefined,
      skill: string | undefined,
      referenceSpace: string | undefined,
      reference: string | undefined,
      offset: number,
    ) => {
      const token = skill ?? reference;
      const space = skillSpace ?? referenceSpace ?? '';
      if (!token) return whole;
      const item = byToken.get(token);
      if (!item) return whole;
      if (ambiguous.has(token)) throw new Error('ambiguous_mention');
      if (
        item.kind === 'skill' &&
        /^\s*\[Skill Path\]\(/.test(text.slice(offset + whole.length))
      )
        return whole;
      return space + mentionPrompt(item, workspaceId);
    },
  );
}

// Web's mention references (`[@Title](lody://session/…)`, `[Agent Role: …]`):
// they name what the user mentioned, never an action for the agent to take.
export function mentionPrompt(item: MentionItem, workspaceId?: string): string {
  if (item.kind === 'session') {
    const title = item.name.trim() || item.path;
    const label = `@${title}`
      .replace(/\\/gu, '\\\\')
      .replace(/[[\]]/gu, '\\$&');
    return `[${label}](${buildSessionLink({ sessionId: item.path, workspaceId })})`;
  }
  if (item.kind === 'role') {
    const [id, machineId, targetId] = item.path.split('@');
    const name = item.roleName ?? item.name;
    if (targetId && machineId)
      return `[Agent Role: ${name} (agentRoleId: ${id}, agentRoleMachineId: ${machineId}, agentRoleInstanceId: ${targetId})]`;
    if (targetId)
      return `[Agent Role: ${name} (agentRoleId: ${id}, agentRoleInstanceId: ${targetId})]`;
    if (machineId)
      return `[Agent Role: ${name} (agentRoleId: ${id}, agentRoleMachineId: ${machineId})]`;
    return `[Agent Role: ${name} (agentRoleId: ${id})]`;
  }
  if (item.kind === 'skill') {
    const destination = item.path.replace(/\\/g, '\\\\').replace(/\)/g, '\\)');
    const token =
      item.insertText?.slice(1) ?? item.name.trim().replace(/\s+/g, '-');
    return `use /${token} [Skill Path](${destination})`;
  }
  return item.insertText ?? `@${item.path}`;
}
