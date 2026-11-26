import assert from 'node:assert/strict';
import test from 'node:test';
import { ConversationShareMessagesResult } from '../../../../packages/cloud-runtime/src/contract/sessions.ts';
import { buildConversationShareMessages } from '../../../../packages/cloud-runtime/src/protocol/conversation-share-image.ts';
import { appendMessageQuotes } from '../../../../packages/cloud-runtime/src/protocol/message-quotes.ts';

test('buildConversationShareMessages filters non-prose turns, decodes user quotes/mentions, and estimates working tokens', () => {
  const quoted = appendMessageQuotes(
    'Please check @src/app.ts',
    [
      {
        start: 13,
        end: 24,
        kind: 'file',
        label: 'src/app.ts',
        target: 'src/app.ts',
      },
    ],
    [
      {
        id: 'q-1',
        text: 'Line one\nLine two',
        comment: 'Why does this branch throw?',
      },
    ],
  );

  const history = [
    {
      id: 'sys-1',
      role: 'system',
      items: [{ type: 'text', text: 'System row' }],
    },
    {
      id: 'queued-1',
      role: 'user',
      status: 'queued',
      items: [{ type: 'text', text: 'Queued draft' }],
    },
    {
      id: 'img-only',
      role: 'user',
      items: [{ type: 'image', id: 'img-1', fileName: 'a.png' }],
    },
    {
      id: 'user-1',
      role: 'user',
      items: [
        { type: 'text', text: 'Intro line' },
        { type: 'text', text: quoted.text, spans: quoted.spans },
      ],
    },
    {
      id: 'tool-only',
      role: 'assistant',
      items: [{ type: 'tool_call', toolName: 'bash', rawInput: { cmd: 'ls' } }],
    },
    {
      id: 'asst-1',
      role: 'assistant',
      userTurnId: 'user-1',
      modelInfo: { modelId: 'claude-4', name: 'Claude 4 Sonnet' },
      items: [
        {
          type: 'thought',
          text: 'Hidden reasoning that still counts toward tokens',
        },
        { type: 'tool_call', toolName: 'read_file', rawOutput: 'file body' },
        { type: 'text', text: 'First answer paragraph.' },
        { type: 'text', text: '```ts\nconst ok = true;\n```' },
      ],
    },
  ];

  const messages = buildConversationShareMessages(history);
  assert.equal(messages.length, 2);
  assert.equal(messages[0].id, 'user-1');
  assert.equal(messages[0].role, 'user');
  assert.ok(!messages[0].text.includes('<message-quote>'));
  assert.ok(
    messages[0].text.includes('Intro line\n\nPlease check @src/app.ts'),
  );
  assert.ok(messages[0].text.includes('Line one\nLine two'));

  const quoteRef = messages[0].references?.find(
    (ref) => ref.kind === 'message_quote',
  );
  assert.ok(quoteRef);
  assert.equal(
    messages[0].text.slice(quoteRef.start, quoteRef.end),
    'Line one\nLine two',
  );
  assert.equal(quoteRef.quote, 'Line one\nLine two');

  const fileRef = messages[0].references?.find((ref) => ref.kind === 'file');
  assert.ok(fileRef);
  assert.equal(
    messages[0].text.slice(fileRef.start, fileRef.end),
    '@src/app.ts',
  );

  assert.equal(messages[1].id, 'asst-1');
  assert.equal(messages[1].role, 'assistant');
  assert.equal(messages[1].userTurnId, 'user-1');
  assert.equal(messages[1].modelName, 'Claude 4 Sonnet');
  assert.equal(
    messages[1].text,
    'First answer paragraph.\n\n```ts\nconst ok = true;\n```',
  );
  assert.ok(messages[1].estimatedTokens > 20);

  const parsed = ConversationShareMessagesResult.safeParse({
    state: 'ready',
    title: 'Share test',
    createdAt: '2026-11-26T02:00:00.000Z',
    cliType: 'builtin',
    agentType: 'claude',
    messages,
  });
  assert.equal(parsed.success, true);
});

test('buildConversationShareMessages keeps newest turns when wire budget binds', () => {
  const history = [
    {
      id: 'u1',
      role: 'user',
      items: [{ type: 'text', text: 'x'.repeat(400) }],
    },
    {
      id: 'a1',
      role: 'assistant',
      items: [{ type: 'text', text: 'y'.repeat(400) }],
    },
    {
      id: 'u2',
      role: 'user',
      items: [{ type: 'text', text: 'Newest question' }],
    },
    {
      id: 'a2',
      role: 'assistant',
      items: [{ type: 'text', text: 'Newest answer' }],
    },
  ];
  const bounded = buildConversationShareMessages(history, 400);
  assert.deepEqual(
    bounded.map((m) => m.id),
    ['u2', 'a2'],
  );
});
