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

type TokenResolution =
  | { status: 'found'; item: MentionItem }
  | { status: 'ambiguous' }
  | { status: 'missing' };

function createMentionResolver(items: readonly MentionItem[]) {
  const byToken = new Map<string, MentionItem>();
  const ambiguous = new Set<string>();
  for (const item of items) {
    if (!item.insertText) continue;
    if (byToken.has(item.insertText)) ambiguous.add(item.insertText);
    byToken.set(item.insertText, item);
  }
  return (token: string): TokenResolution => {
    if (ambiguous.has(token)) return { status: 'ambiguous' };
    const exact = byToken.get(token);
    if (exact) return { status: 'found', item: exact };
    // Compatibility for saved drafts / shortcuts using legacy `@role:<id>` or
    // `@role:<id>@<machineId>` tokens after targets gained stable `@<targetId>`.
    if (token.startsWith('@role:')) {
      const parts = token.slice('@role:'.length).split('@');
      if (parts.length === 1 || parts.length === 2) {
        const matches = items.filter((item) => {
          if (item.kind !== 'role') return false;
          const segments = item.path.split('@');
          if (segments[0] !== parts[0]) return false;
          if (parts.length === 2 && segments[1] !== parts[1]) return false;
          return true;
        });
        if (matches.length === 1) return { status: 'found', item: matches[0]! };
        if (matches.length > 1) return { status: 'ambiguous' };
      }
    }
    return { status: 'missing' };
  };
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
    const resolve = createMentionResolver(items);
    for (const match of text.matchAll(referencePattern))
      if (
        match[4]?.startsWith('@role:') &&
        resolve(match[4]).status !== 'found'
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
  const resolve = createMentionResolver(items);
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
      const resolved = resolve(token);
      if (resolved.status === 'ambiguous') throw new Error('ambiguous_mention');
      if (resolved.status === 'missing') return whole;
      const item = resolved.item;
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
