import { useMemo, useState } from 'react';
import { View as RNView } from 'react-native';
import { NativeNavigationHeader, TerminalView } from '@lody-ios/kit';
import { definePage } from '@/lib/presentation';
import { usePalette } from '@/lib/theme/palette';
import { usePageRuntime } from '@/hooks/screens/usePageRuntime';
import { t } from '../lib/i18n/index.ts';

export type TerminalParams = {
  workspaceId: string;
  machineId: string;
  sessionId: string;
  host: string;
  port: number;
  /** Debug scenes echo locally instead of reaching a machine. */
  fixture?: boolean;
};

function View() {
  const { params } = usePageRuntime<TerminalParams>();
  const colors = usePalette();
  const [title, setTitle] = useState<string>();
  const source = useMemo(
    () =>
      JSON.stringify({
        workspaceId: params.workspaceId,
        machineId: params.machineId,
        sessionId: params.sessionId,
        host: params.host,
        port: params.port,
        fixture: params.fixture,
      }),
    [params],
  );
  return (
    <RNView style={{ flex: 1, backgroundColor: colors.background }}>
      <NativeNavigationHeader title={title || t('terminal.title')} />
      <TerminalView
        style={{ flex: 1 }}
        sourceJSON={source}
        onState={({ nativeEvent }) => {
          if (nativeEvent.title !== undefined) setTitle(nativeEvent.title);
        }}
      />
    </RNView>
  );
}

export const TerminalScreen = definePage<TerminalParams>({
  id: 'terminal',
  title: t('terminal.title'),
  Component: View,
  parseRouteParams: () => {
    throw new Error('Open this page from a session');
  },
  presentation: { style: 'push', headerVariant: 'transparent' },
});
