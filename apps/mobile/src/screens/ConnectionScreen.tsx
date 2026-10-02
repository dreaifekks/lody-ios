import { useEffect } from 'react';
import { NativeGroupedList } from '@lody-ios/kit';
import { useAuth } from '@/cloud/auth/AuthProvider';
import { useCatalog } from '@/cloud/catalog/CatalogProvider';
import { useConnection, type Connection } from '@/cloud/catalog/connection';
import {
  connectionService,
  type ConnectionService,
} from '@/cloud/catalog/machineStatus';
import { connectionSections } from '@/features/settings/connection';
import {
  useHubLatency,
  useMachineStatus,
} from '@/features/settings/useConnectionStatus';
import { definePage } from '@/lib/presentation';
import { usePageRuntime } from '@/hooks/screens/usePageRuntime';
import { usePalette } from '@/lib/theme/palette';
import { relativeTime } from '@/ui/time';
import { t } from '../lib/i18n/index.ts';

/** The hub and every computer of the workspace, and how each answers now. */
export function ConnectionView({
  workspaceId,
  hub,
  connection,
  onResync,
  service = connectionService,
}: {
  workspaceId: string;
  /** Set on a LAN: the hub whose latency is shown first. */
  hub?: { name: string; address: string };
  connection: Connection;
  onResync: () => void;
  service?: ConnectionService;
}) {
  const colors = usePalette();
  const status = useMachineStatus(service, workspaceId);
  const latency = useHubLatency(hub ? service.hubLatency : undefined);
  const syncedAt = connection.syncedAt
    ? relativeTime(new Date(connection.syncedAt).toISOString())
    : '';
  return (
    <NativeGroupedList
      style={{ flex: 1 }}
      accent={colors.accent}
      placeholder=""
      refreshing={status.pulling}
      onRefresh={() => status.refresh(true)}
      sections={connectionSections({
        hub: hub && { ...hub, latency },
        connection,
        syncedAt,
        machines: status.machines,
        reach: status.reach,
        error: status.error,
        accent: colors.accent,
      })}
      onRowPress={({ nativeEvent: { id } }) => {
        if (id === 'sync' && connection.state === 'offline') onResync();
        if (id === 'retry') status.refresh(true);
      }}
    />
  );
}

function View() {
  const { cancel } = usePageRuntime();
  const { account } = useAuth();
  const { selected, refresh } = useCatalog();
  const connection = useConnection();
  useEffect(() => {
    if (!selected) cancel();
  }, [selected, cancel]);
  if (!selected) return null;
  const lan = account?.lan;
  return (
    <ConnectionView
      key={selected.id}
      workspaceId={selected.id}
      hub={
        lan && {
          name: lan.name,
          address: lan.url.replace(/^https?:\/\//, ''),
        }
      }
      connection={connection}
      onResync={refresh}
    />
  );
}

export const ConnectionScreen = definePage({
  id: 'connection',
  title: t('settings.section.connection'),
  Component: View,
  presentation: { style: 'push', headerVariant: 'transparent' },
});
