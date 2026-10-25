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
function View() {
  return (
    <NativeChat
      style={{ flex: 1 }}
      entriesJSON={JSON.stringify(entries)}
      composerJSON='{"editable":false,"canSend":false}'
      clearDraftToken={0}
      emptyText=""
      onSend={() => {}}
      onReconnect={() => {}}
      onActivityPress={() => {}}
    />
  );
}
export const PendingPreviewScreen = definePage({
  id: 'pending-preview',
  title: 'Pending adaptations',
  Component: View,
  presentation: { style: 'push', headerVariant: 'transparent' },
});
