import { useState } from 'react';
import { Stack } from 'expo-router';
import { View as RNView } from 'react-native';
import { useOpenFile } from '@/hooks/screens/useOpenFile';
import { messageLinkAction } from '@/features/sessions/messageLink';
import { NativeChat } from '@lody-ios/kit';
import { definePage } from '@/lib/presentation';

const entries: object[] = [
  {
    id: 'delegated',
    role: 'user',
    status: 'completed',
    finished: true,
    author: {
      kind: 'agent',
      name: 'Codex',
      role: { name: 'Reviewer', instanceLabel: 'mini' },
      model: 'GPT-6 Sol',
    },
    items: [
      {
        itemId: 'text',
        type: 'text',
        text: 'Please review the native changes.',
      },
    ],
  },
  {
    id: 'plain',
    role: 'user',
    status: 'completed',
    finished: true,
    items: [
      {
        itemId: 'text',
        type: 'text',
        text: 'A human message without an author.',
      },
    ],
  },
];
const links: object[] = [
  {
    id: 'bare',
    role: 'assistant',
    status: 'completed',
    finished: true,
    items: [
      { itemId: 'file', type: 'text', text: 'Open docs/report.md' },
      { itemId: 'unicode', type: 'text', text: '见notes/准备.md。' },
      { itemId: 'home', type: 'text', text: 'Home ~/out/report.md:12' },
      {
        itemId: 'session',
        type: 'text',
        text: 'lody://session/review?workspace=fixture',
      },
      { itemId: 'legacy', type: 'text', text: 'session://review' },
      { itemId: 'code', type: 'text', text: '`docs/sample.swift`' },
      {
        itemId: 'literal',
        type: 'text',
        text: '`session://review` and `cat docs/report.md`\n\n```text\ndocs/report.md\n```',
      },
    ],
  },
];
const board = [
  {
    id: 'silent',
    role: 'system',
    status: 'completed',
    finished: true,
    items: [
      {
        itemId: 'notice',
        type: 'system_notice',
        name: 'board_context_maintenance',
        meta: { trigger: 'idle', status: 'interrupted', kind: 'compact' },
      },
    ],
  },
  {
    id: 'batch',
    role: 'system',
    status: 'completed',
    finished: true,
    items: [
      {
        itemId: 'results',
        type: 'operation_completion_batch',
        memberCount: 52,
        members: [
          { title: 'Native review', status: 'succeeded' },
          { title: 'UI validation', status: 'failed' },
          { title: 'Third result', status: 'succeeded' },
          { title: 'Fourth result retained', status: 'succeeded' },
        ],
      },
    ],
  },
  {
    id: 'report',
    role: 'system',
    status: 'completed',
    finished: true,
    items: [
      {
        itemId: 'result',
        type: 'operation_completion',
        memberCount: 1,
        members: [{ title: 'Board thread finished', status: 'finished' }],
      },
    ],
  },
  {
    id: 'maintenance',
    role: 'system',
    status: 'completed',
    finished: true,
    items: [
      {
        itemId: 'notice',
        type: 'system_notice',
        name: 'board_context_maintenance',
        meta: { trigger: 'manual', status: 'done', kind: 'compact' },
      },
    ],
  },
  {
    id: 'chain',
    role: 'system',
    status: 'completed',
    finished: true,
    items: [
      { itemId: 'notice', type: 'system_notice', name: 'board_chain_limit' },
    ],
  },
  {
    id: 'proposal',
    role: 'system',
    status: 'completed',
    finished: true,
    items: [
      {
        itemId: 'notice',
        type: 'system_notice',
        name: 'agent_role_proposal',
        meta: {
          before: { name: 'Reviewer' },
          command: {
            action: 'update',
            patch: {
              description: 'Review native code',
              promptPrefix: 'Read-only review',
            },
          },
        },
      },
    ],
  },
];
function View() {
  const [fixture, setFixture] = useState('author');
  const [opened, setOpened] = useState('');
  const [findRequest, setFindRequest] = useState('{}');
  const openFile = useOpenFile('ui-verify-files');
  let displayed = entries;
  if (fixture === 'board') displayed = board;
  if (fixture === 'board-requested')
    displayed = [
      {
        id: 'requested',
        role: 'system',
        status: 'completed',
        finished: true,
        items: [
          {
            itemId: 'notice',
            type: 'system_notice',
            name: 'board_context_maintenance',
            meta: {
              trigger: 'manual',
              status: 'requested',
              kind: 'new_conversation',
            },
          },
        ],
      },
    ];
  if (fixture === 'links') displayed = links;
  if (fixture === 'tg')
    displayed = [
      {
        id: 'tg',
        role: 'assistant',
        status: 'completed',
        finished: true,
        items: [
          {
            itemId: 'link',
            type: 'text',
            text: '[Open Telegram](tg://resolve?domain=lody_fixture)',
          },
        ],
      },
    ];
  return (
    <>
      <Stack.Toolbar placement="right">
        <Stack.Toolbar.Menu
          icon="slider.horizontal.3"
          accessibilityLabel="Pending fixtures"
        >
          {[
            'author',
            'links',
            'tg',
            'board',
            'board-requested',
            'find-author',
            'find-body',
          ].map((value) => (
            <Stack.Toolbar.MenuAction
              key={value}
              onPress={() => {
                setOpened('');
                if (value === 'find-author' || value === 'find-body') {
                  setFixture('author');
                  setFindRequest(
                    JSON.stringify({
                      open: true,
                      id: String(Date.now()),
                      query: value === 'find-author' ? 'Codex' : 'review',
                      keyboard: false,
                    }),
                  );
                } else {
                  setFindRequest('{}');
                  setFixture(value);
                }
              }}
            >
              {value}
            </Stack.Toolbar.MenuAction>
          ))}
        </Stack.Toolbar.Menu>
      </Stack.Toolbar>
      <NativeChat
        style={{ flex: 1 }}
        entriesJSON={JSON.stringify(displayed)}
        findRequestJSON={findRequest}
        composerJSON='{"editable":false,"canSend":false}'
        clearDraftToken={0}
        emptyText=""
        onSend={() => {}}
        onReconnect={() => {}}
        onActivityPress={() => {}}
        onFilePress={({ nativeEvent }) => {
          setOpened(`file:${nativeEvent.path}:${nativeEvent.line}`);
          if (nativeEvent.path === 'docs/report.md')
            void openFile(nativeEvent.path, nativeEvent.line);
        }}
        onLinkPress={({ nativeEvent }) => {
          const action = messageLinkAction(nativeEvent.href, {
            sessions: [],
            workspaceId: 'fixture',
          });
          setOpened(`${action.kind}:${nativeEvent.href}`);
        }}
      />
      {opened ? (
        <RNView
          accessible
          testID="pending-opened"
          accessibilityLabel={opened}
          pointerEvents="none"
          style={{ position: 'absolute', bottom: 0, width: 44, height: 44 }}
        />
      ) : null}
    </>
  );
}
export const PendingPreviewScreen = definePage({
  id: 'pending-preview',
  title: 'Pending adaptations',
  Component: View,
  presentation: { style: 'push', headerVariant: 'transparent' },
});
