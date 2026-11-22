/**
 * Message quotes with comments, byte-compatible with web `message-quote.ts`.
 *
 * The quoted passage travels as text so every ACP Agent receives the
 * snapshot; a `message_quote` span (quoteVersion 1) marks the block so
 * clients render it as a quote and restore it into a card. A block without a
 * valid span is ordinary text: Markdown is never guessed into a quote.
 */
export const MESSAGE_QUOTE_VERSION = 1 as const;
/** Web `MAX_SELECTION_TEXT`: the longest passage a client may quote. */
export const MAX_MESSAGE_QUOTE_LENGTH = 50_000;
const MAX_MESSAGE_QUOTES = 16;
const MAX_COMMENT_LENGTH = 32_000;
const HEADER = '<message-quote>\nQuoted message (context):\n';
const FOOTER = '\n</message-quote>';

/** A composer card: a read-only snapshot and the user's comment on it. */
export type MessageQuote = { id: string; text: string; comment: string };

export type MessageQuoteSpan = {
  start: number;
  end: number;
  kind: 'message_quote';
  label: string;
  target?: string;
  quoteVersion: 1;
};

export function formatMessageQuote(snapshot: string): string {
  return (
    HEADER +
    snapshot
      .replace(/\r\n?/g, '\n')
      .split('\n')
      .map((line) => `> ${line}`)
      .join('\n') +
    FOOTER
  );
}

/** Only call for an explicitly versioned quote span, never to guess user Markdown. */
export function readMessageQuote(
  text: string,
  version: unknown,
): string | undefined {
  if (
    version !== MESSAGE_QUOTE_VERSION ||
    !text.startsWith(HEADER) ||
    !text.endsWith(FOOTER)
  )
    return undefined;
  const lines = text.slice(HEADER.length, -FOOTER.length).split('\n');
  if (!lines.every((line) => line.startsWith('> '))) return undefined;
  return lines.map((line) => line.slice(2)).join('\n');
}

const graphemeSegmenter = new Intl.Segmenter(undefined, {
  granularity: 'grapheme',
});
const wordSegmenter = new Intl.Segmenter(undefined, { granularity: 'word' });

function graphemeLength(text: string): number {
  let count = 0;
  for (const _ of graphemeSegmenter.segment(text)) count += 1;
  return count;
}

/** Web `formatMessageQuoteExcerpt` over the snapshot's collapsed whitespace, without cutting words. */
export function messageQuoteExcerpt(snapshot: string, maxLength = 32): string {
  const text = snapshot.replace(/\s+/g, ' ').trim();
  if (!text || graphemeLength(text) <= maxLength) return text;
  const budget = Math.max(1, maxLength - 3);
  let fitted = '';
  for (const { segment } of wordSegmenter.segment(text)) {
    const candidate = fitted + segment;
    if (graphemeLength(candidate.trimEnd()) <= budget) fitted = candidate;
    else break;
  }
  const trimmed = fitted.trimEnd();
  if (trimmed) return `${trimmed}...`;
  const head = Array.from(
    graphemeSegmenter.segment(text),
    ({ segment }) => segment,
  )
    .slice(0, budget)
    .join('')
    .trimEnd();
  return `${head}...`;
}

/**
 * The composer's cards from the wire. `[]` without cards, `undefined` when
 * any card is malformed: a send must never drop a quote the user added.
 */
export function messageQuotes(input: unknown): MessageQuote[] | undefined {
  if (input === undefined || input === null) return [];
  if (!Array.isArray(input) || input.length > MAX_MESSAGE_QUOTES)
    return undefined;
  const quotes: MessageQuote[] = [];
  for (const item of input) {
    if (!item || typeof item !== 'object') return undefined;
    const { id, text, comment } = item as Record<string, unknown>;
    if (typeof id !== 'string' || !id || id.length > 128) return undefined;
    if (
      typeof text !== 'string' ||
      !text.trim() ||
      text.length > MAX_MESSAGE_QUOTE_LENGTH
    )
      return undefined;
    if (comment !== undefined && typeof comment !== 'string') return undefined;
    if ((comment ?? '').length > MAX_COMMENT_LENGTH) return undefined;
    quotes.push({ id, text, comment: (comment ?? '').trim() });
  }
  return quotes;
}

/**
 * Appends the cards after the (already rewritten) main text: each quote
 * block, then its comment, every part separated by a blank line. The main
 * text's spans keep their offsets; each quote span is computed where its
 * block lands, so spans never overlap.
 */
export function appendMessageQuotes<S extends { start: number; end: number }>(
  text: string,
  spans: readonly S[],
  quotes: readonly MessageQuote[],
): { text: string; spans: (S | MessageQuoteSpan)[] } {
  let result = text;
  const next: (S | MessageQuoteSpan)[] = [...spans];
  for (const quote of quotes) {
    if (result) result += '\n\n';
    const start = result.length;
    result += formatMessageQuote(quote.text);
    next.push({
      start,
      end: result.length,
      kind: 'message_quote',
      label: `[${messageQuoteExcerpt(quote.text)}]`,
      target: quote.id,
      quoteVersion: MESSAGE_QUOTE_VERSION,
    });
    if (quote.comment) result += `\n\n${quote.comment}`;
  }
  return { text: result, spans: next };
}

/** The valid quote spans of `text`, sorted, earlier spans winning overlaps (web `sanitizeMessageTextSpans`). */
export function messageQuoteSpans(
  text: string,
  input: unknown,
): (MessageQuoteSpan & { quote: string })[] {
  if (!Array.isArray(input)) return [];
  const candidates: (MessageQuoteSpan & { quote: string })[] = [];
  for (const span of input) {
    if (!span || typeof span !== 'object') continue;
    const { start, end, kind, label, target, quoteVersion } = span as Record<
      string,
      unknown
    >;
    if (kind !== 'message_quote') continue;
    if (
      !Number.isInteger(start) ||
      !Number.isInteger(end) ||
      (start as number) < 0 ||
      (end as number) <= (start as number) ||
      (end as number) > text.length
    )
      continue;
    if (typeof label !== 'string' || !label) continue;
    if (target !== undefined && typeof target !== 'string') continue;
    const quote = readMessageQuote(
      text.slice(start as number, end as number),
      quoteVersion,
    );
    if (quote === undefined) continue;
    candidates.push({
      start: start as number,
      end: end as number,
      kind: 'message_quote',
      label,
      ...(target === undefined ? {} : { target }),
      quoteVersion: MESSAGE_QUOTE_VERSION,
      quote,
    });
  }
  candidates.sort((a, b) => a.start - b.start || a.end - b.end);
  let lastEnd = 0;
  return candidates.filter((span) => {
    if (span.start < lastEnd) return false;
    lastEnd = span.end;
    return true;
  });
}

/**
 * Restores a sent message into composer state: the text before the first
 * quote is the main text, each quote becomes a card and the text up to the
 * next quote its comment. Without a valid quote span the text is unchanged.
 */
export function splitMessageQuotes(
  text: string,
  spans: unknown,
): { text: string; quotes: MessageQuote[] } {
  const quotes = messageQuoteSpans(text, spans);
  if (!quotes.length) return { text, quotes: [] };
  return {
    text: text.slice(0, quotes[0].start).trim(),
    quotes: quotes.map((span, index) => ({
      id: span.target || crypto.randomUUID(),
      text: span.quote,
      comment: text.slice(span.end, quotes[index + 1]?.start).trim(),
    })),
  };
}
