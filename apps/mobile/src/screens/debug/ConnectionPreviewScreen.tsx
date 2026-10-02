import { useState } from 'react';
import { ConnectionView } from '../ConnectionScreen';
import type { ConnectionService } from '@/cloud/catalog/machineStatus';
import type { Connection } from '@/models/catalog';
import { definePage } from '@/lib/presentation';
import { t } from '../../lib/i18n/index.ts';

// Deterministic outcomes at the service boundary: no hub, machine or network.
const service: ConnectionService = {
  machines: async () => [
    {
      id: 'nuc',
      name: 'homenucserver',
      alias: 'NUC',
      os: 'linux',
      version: '0.103.0',
    },
    { id: 'mac', name: 'MacBook Air', os: 'darwin', version: '0.103.0' },
    { id: 'n100', name: 'Ubuntu-N100', os: 'linux' },
  ],
  ping: async (_, machineId) => {
    if (machineId === 'n100') throw new Error('no answer');
    return machineId === 'mac' ? 227 : 18;
  },
  hubLatency: async () => 12,
};

function View() {
  const [connection, setConnection] = useState<Connection>({
    state: 'offline',
    machines: 3,
    syncedAt: Date.now() - 60_000,
  });
  return (
    <ConnectionView
      workspaceId="connection-preview"
      hub={{ name: 'Home', address: '100.92.194.31:8788' }}
      connection={connection}
      onResync={() =>
        setConnection({ state: 'live', machines: 3, syncedAt: Date.now() })
      }
      service={service}
    />
  );
}

export const ConnectionPreviewScreen = definePage({
  id: 'connection-preview',
  title: t('settings.section.connection'),
  Component: View,
  presentation: { style: 'push', headerVariant: 'transparent' },
});
