import type { NativeListRow, NativeListSection } from '@lody-ios/kit';
import type { Connection } from '../../models/catalog.ts';
import type {
  MachineReach,
  WorkspaceMachine,
} from '../../models/connection.ts';
import { t } from '../../lib/i18n/index.ts';

export const connectionRow = {
  live: { symbol: 'circle.fill', label: 'settings.connection.live' },
  syncing: { symbol: 'circle', label: 'settings.connection.syncing' },
  offline: {
    symbol: 'xmark.octagon.fill',
    label: 'settings.connection.offline',
  },
} as const;

/** The joined LAN hub; `latency` is undefined until the first measurement. */
export type HubStatus = {
  name: string;
  address: string;
  latency: number | null | undefined;
};

export const latencyText = (ms: number) =>
  t('settings.connection.latency', { ms: Math.round(ms) });

export function hubLatencyText(latency: number | null | undefined) {
  if (latency === undefined) return t('settings.connection.measuring');
  if (latency === null) return t('settings.connection.noAnswer');
  return latencyText(latency);
}

/** What the account row adds after the hub address; nothing before the first answer. */
export function accountSubtitle(
  address: string,
  latency: number | null | undefined,
) {
  if (latency === undefined) return address;
  return `${address} · ${hubLatencyText(latency)}`;
}

export const machineRowId = (id: string) => `machine:${id}`;

function reachValue(reach: MachineReach | undefined): Partial<NativeListRow> {
  if (reach?.state === 'online') {
    const text = latencyText(reach.ms);
    return { value: text, accessibilityValue: text };
  }
  if (reach?.state === 'offline') {
    const text = t('settings.connection.machineOffline');
    return {
      valueSegments: [{ text, tint: 'danger' }],
      accessibilityValue: text,
    };
  }
  const text = t('settings.connection.checking');
  return { value: text, accessibilityValue: text };
}

export function machineRow(
  machine: WorkspaceMachine,
  reach: MachineReach | undefined,
  accent: string,
): NativeListRow {
  const subtitle = [
    machine.alias ? machine.name : undefined,
    machine.os,
    machine.version && `v${machine.version}`,
  ]
    .filter(Boolean)
    .join(' · ');
  const tint = {
    online: accent,
    offline: 'danger',
    checking: 'secondary',
  }[reach?.state ?? 'checking'];
  return {
    id: machineRowId(machine.id),
    title:
      machine.alias ?? machine.name ?? t('settings.connection.unnamedMachine'),
    subtitle: subtitle || undefined,
    image: 'desktopcomputer',
    imageTint: tint,
    ...reachValue(reach),
  };
}

export function connectionSections({
  hub,
  connection,
  syncedAt,
  machines,
  reach,
  error,
  accent,
}: {
  hub?: HubStatus;
  connection: Connection;
  /** `connection.syncedAt` already formatted for display. */
  syncedAt: string;
  machines: WorkspaceMachine[];
  reach: Record<string, MachineReach>;
  error: string;
  accent: string;
}): NativeListSection[] {
  const shape = connectionRow[connection.state];
  const sections: NativeListSection[] = [];
  if (hub) {
    const latencyTint = typeof hub.latency === 'number' ? accent : 'secondary';
    sections.push({
      id: 'hub',
      header: t('settings.connection.hub'),
      rows: [
        {
          id: 'hub',
          title: hub.name,
          subtitle: hub.address,
          image: 'server.rack',
          imageTint: hub.latency === null ? 'danger' : latencyTint,
          ...(hub.latency === null
            ? {
                valueSegments: [
                  { text: hubLatencyText(null), tint: 'danger' as const },
                ],
              }
            : { value: hubLatencyText(hub.latency) }),
          accessibilityValue: hubLatencyText(hub.latency),
        },
      ],
    });
  }
  sections.push({
    id: 'sync',
    header: t('settings.connection.sync'),
    rows: [
      {
        id: 'sync',
        title: t(shape.label),
        subtitle:
          connection.state === 'offline'
            ? t('settings.connection.tapToResync')
            : syncedAt && t('settings.connection.syncedAt', { time: syncedAt }),
        image: shape.symbol,
        imageTint: {
          live: accent,
          offline: 'danger',
          syncing: 'secondary',
        }[connection.state],
        action: connection.state === 'offline',
      },
    ],
  });
  const rows: NativeListRow[] = machines.map((machine) =>
    machineRow(machine, reach[machine.id], accent),
  );
  if (error && !machines.length)
    rows.push({
      id: 'retry',
      title: error,
      subtitle: t('settings.connection.retry'),
      image: 'exclamationmark.triangle',
      imageTint: 'danger',
      action: true,
    });
  sections.push({
    id: 'machines',
    header: t('settings.connection.machines'),
    footer: t('settings.connection.footer'),
    rows,
  });
  return sections;
}
