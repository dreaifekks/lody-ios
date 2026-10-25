import type { LanSimulatorTarget } from '@lody-ios/kit';
import type { Catalog, Session } from '@lody/cloud-runtime/models/catalog';

export type SimulatorAvailability = NonNullable<
  Catalog['machineSimulators']
>[string];

/**
 * Where a session's simulators come from. On Cloud the session's Mac serves
 * them through the hosted gateway. On a LAN this device asks the member that
 * runs the session over its endpoint, which must publish
 * `protocolCapabilities.lanIosSimulator`; an archived session is refused there.
 */
export function sessionSimulatorAvailability(
  catalog: Pick<
    Catalog,
    'machineSimulators' | 'machineLanSimulators' | 'machineTerminals'
  >,
  session: Pick<Session, 'machineId' | 'archived'>,
  lanWorkspaceId: string | undefined,
): { availability?: SimulatorAvailability; lan?: LanSimulatorTarget } {
  if (!lanWorkspaceId)
    return { availability: catalog.machineSimulators?.[session.machineId] };
  const endpoint = catalog.machineTerminals?.[session.machineId];
  const availability = catalog.machineLanSimulators?.[session.machineId];
  if (!endpoint || !availability || session.archived) return {};
  return {
    availability,
    lan: {
      workspaceId: lanWorkspaceId,
      machineId: session.machineId,
      host: endpoint.host,
      port: endpoint.port,
    },
  };
}
