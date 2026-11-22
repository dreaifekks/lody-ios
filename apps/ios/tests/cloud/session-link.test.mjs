import test from 'node:test';
import assert from 'node:assert/strict';
import {
  buildSessionLink,
  parseSessionLink,
} from '../../../../packages/cloud-runtime/src/protocol/sessionLink.ts';
import { buildConversationMarkdown } from '../../../../packages/cloud-runtime/src/protocol/conversation-markdown.ts';

test('session links parse and build ?turn=<turnId> with colons, dots, dashes and underscores raw', () => {
  const turnId = 'assistant:inbox:completion:12.v1_a-b';
  const built = buildSessionLink({ sessionId: 'Ab_c', turnId });
  assert.equal(built, `lody://session/Ab_c?turn=${turnId}`);
  assert.deepEqual(parseSessionLink(built), { sessionId: 'Ab_c', turnId });

  const withWorkspace = buildSessionLink({
    sessionId: 'Ab_c',
    workspaceId: 'ws_1',
    turnId,
  });
  assert.equal(
    withWorkspace,
    `lody://session/Ab_c?workspace=ws_1&turn=${turnId}`,
  );
  assert.deepEqual(parseSessionLink(withWorkspace), {
    sessionId: 'Ab_c',
    workspaceId: 'ws_1',
    turnId,
  });

  const withTab = `lody://session/Ab_c?workspace=ws_1&tab=child_1&turn=${turnId}`;
  assert.deepEqual(parseSessionLink(withTab), {
    sessionId: 'Ab_c',
    workspaceId: 'ws_1',
    tabSessionId: 'child_1',
    turnId,
  });

  const exported = buildConversationMarkdown({
    history: [
      {
        id: 'a1',
        role: 'assistant',
        items: [{ type: 'text', text: `See [the receipt](${built}).` }],
      },
    ],
    workspaceId: 'ws_1',
  }).markdown;
  assert.match(
    exported,
    new RegExp(
      `lody://session/Ab_c\\?workspace=ws_1&turn=${turnId.replace(/\./g, '\\.')}`,
    ),
  );
});

test('session links reject malformed, duplicate, empty or percent-encoded turn parameters', () => {
  for (const rejected of [
    'lody://session/Ab_c?turn=assistant%3Ainbox',
    'lody://session/Ab_c?turn=a&turn=b',
    'lody://session/Ab_c?turn=a/b',
    'lody://session/Ab_c?turn=',
    'lody://session/Ab_c?turn=a+b',
    'lody://session/Ab_c?turn=a?b',
    'lody://session/Ab_c?workspace=ws_1&turn=bad space',
  ]) {
    assert.equal(parseSessionLink(rejected), null, rejected);
  }
  assert.throws(() => buildSessionLink({ sessionId: 'Ab_c', turnId: 'a b' }));
  assert.throws(() => buildSessionLink({ sessionId: 'Ab_c', turnId: '' }));
  assert.throws(() => buildSessionLink({ sessionId: 'Ab_c', turnId: 'a/b' }));
});
