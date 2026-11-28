import {
  estimateStoredMessageTokens,
  resolveTurnModelName,
} from './conversation-markdown.ts';
import { presentMessageText } from './message-references.ts';

export interface ShareCardMessageReference {
  start: number;
  end: number;
  kind: string;
  label: string;
  target?: string;
  mark?: string;
  quote?: string;
}

export interface ShareCardMessage {
  id: string;
  role: 'user' | 'assistant';
  text: string;
  references?: ShareCardMessageReference[];
  estimatedTokens: number;
  modelName?: string;
  userTurnId?: string;
}

/** Keep envelope replies comfortably below Android's 8 MiB and iOS's 12 MiB host limits. */
export const MAX_SHARE_MESSAGES_WIRE_BYTES = 6 * 1024 * 1024;

const encoder = new TextEncoder();

export function buildConversationShareMessages(
  history: readonly Record<string, any>[],
  maxWireBytes = MAX_SHARE_MESSAGES_WIRE_BYTES,
): ShareCardMessage[] {
  const messages: ShareCardMessage[] = [];
  for (const entry of history) {
    if (!entry || typeof entry.id !== 'string' || !entry.id) continue;
    if (entry.role !== 'user' && entry.role !== 'assistant') continue;
    if (entry.status === 'queued') continue;
    const items = Array.isArray(entry.items) ? entry.items : [];
    if (entry.role === 'assistant') {
      const texts: string[] = [];
      for (const item of items) {
        if (
          item?.type === 'text' &&
          typeof item.text === 'string' &&
          item.text.trim()
        ) {
          texts.push(item.text);
        }
      }
      if (!texts.length) continue;
      const modelName = resolveTurnModelName(entry);
      const userTurnId =
        typeof entry.userTurnId === 'string' && entry.userTurnId.trim()
          ? entry.userTurnId.trim()
          : undefined;
      messages.push({
        id: entry.id,
        role: 'assistant',
        text: texts.join('\n\n'),
        estimatedTokens: estimateStoredMessageTokens(items),
        ...(modelName ? { modelName } : {}),
        ...(userTurnId ? { userTurnId } : {}),
      });
      continue;
    }

    let joined = '';
    const references: ShareCardMessageReference[] = [];
    for (const item of items) {
      if (
        item?.type !== 'text' ||
        typeof item.text !== 'string' ||
        !item.text.trim()
      ) {
        continue;
      }
      const presented = presentMessageText(item.text, item.spans);
      if (!presented.text.trim()) continue;
      if (joined) joined += '\n\n';
      const offset = joined.length;
      joined += presented.text;
      for (const ref of presented.references) {
        references.push({
          start: ref.start + offset,
          end: ref.end + offset,
          kind: ref.kind,
          label: ref.label,
          ...(ref.target !== undefined ? { target: ref.target } : {}),
          ...(ref.mark !== undefined ? { mark: ref.mark } : {}),
          ...(ref.quote !== undefined ? { quote: ref.quote } : {}),
        });
      }
    }
    if (!joined.trim()) continue;
    messages.push({
      id: entry.id,
      role: 'user',
      text: joined,
      ...(references.length ? { references } : {}),
      estimatedTokens: estimateStoredMessageTokens(items),
    });
  }

  let usedBytes = 2;
  const kept: ShareCardMessage[] = [];
  for (let index = messages.length - 1; index >= 0; index -= 1) {
    const candidate = messages[index]!;
    const size = encoder.encode(JSON.stringify(candidate)).length + 1;
    if (usedBytes + size > maxWireBytes) break;
    usedBytes += size;
    kept.push(candidate);
  }
  kept.reverse();
  return kept;
}
