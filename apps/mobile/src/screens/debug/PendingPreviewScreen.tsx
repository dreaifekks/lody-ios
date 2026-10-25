import { useState } from 'react';
import { Stack } from 'expo-router';
import { View as RNView } from 'react-native';
import { useOpenFile } from '@/hooks/screens/useOpenFile';
import { messageLinkAction } from '@/features/sessions/messageLink';
import { NativeChat } from '@lody-ios/kit';
import { definePage } from '@/lib/presentation';

const entries = [
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
const links = [
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
function View() {
  const [fixture, setFixture] = useState('author');
  const [opened, setOpened] = useState('');
  const openFile = useOpenFile('ui-verify-files');
  let displayed = entries;
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
          {['author', 'links', 'tg'].map((value) => (
            <Stack.Toolbar.MenuAction
              key={value}
              onPress={() => {
                setOpened('');
                setFixture(value);
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
