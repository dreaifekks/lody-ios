import { useCallback, useEffect, useRef, useState } from 'react';
import { addAppActiveListener } from '@lody-ios/kit';
import type { ConnectionService } from '@/cloud/catalog/machineStatus';
import type { MachineReach, WorkspaceMachine } from '@/models/connection';
import { reachOf } from './connection.ts';
import { t } from '../../lib/i18n/index.ts';

export const HUB_LATENCY_INTERVAL_MS = 10_000;
export const MACHINE_PING_INTERVAL_MS = 15_000;

/** The hub's latency while the caller is shown; undefined until it first answers. */
export function useHubLatency(
  measure: ConnectionService['hubLatency'] | undefined,
) {
  const [latency, setLatency] = useState<number | null>();
  useEffect(() => {
    setLatency(undefined);
    if (!measure) return;
    let active = true;
    let running = false;
    const run = () => {
      if (running) return;
      running = true;
      void measure()
        .catch(() => null)
        .then((value) => {
          running = false;
          if (active) setLatency(value);
        });
    };
    run();
    const timer = setInterval(run, HUB_LATENCY_INTERVAL_MS);
    const subscription = addAppActiveListener(run);
    return () => {
      active = false;
      clearInterval(timer);
      subscription.remove();
    };
  }, [measure]);
  return latency;
}

/**
 * The workspace's computers and how each answered its last ping. A new round
 * keeps the previous answers on show until its own arrive.
 */
export function useMachineStatus(
  service: ConnectionService,
  workspaceId: string,
) {
  const [machines, setMachines] = useState<WorkspaceMachine[]>([]);
  const [reach, setReach] = useState<Record<string, MachineReach>>({});
  const [error, setError] = useState('');
  const [pulling, setPulling] = useState(false);
  const round = useRef(0);

  const refresh = useCallback(
    (manual = false) => {
      const id = ++round.current;
      if (manual) setPulling(true);
      const current = () => id === round.current;
      void service.machines(workspaceId).then(
        (list) => {
          if (!current()) return;
          setMachines(list);
          setError('');
          setPulling(false);
          setReach((old) =>
            Object.fromEntries(
              list.map((machine) => [
                machine.id,
                reachOf(machine, undefined, old[machine.id]),
              ]),
            ),
          );
          for (const machine of list)
            void service
              .ping(workspaceId, machine.id)
              .then(
                (ms) => ms,
                () => null,
              )
              .then((ms) => {
                if (current())
                  setReach((old) => ({
                    ...old,
                    [machine.id]: reachOf(machine, ms),
                  }));
              });
        },
        () => {
          if (!current()) return;
          setError(t('settings.connection.listFailed'));
          setPulling(false);
        },
      );
    },
    [service, workspaceId],
  );

  useEffect(() => {
    refresh();
    const timer = setInterval(refresh, MACHINE_PING_INTERVAL_MS);
    const subscription = addAppActiveListener(() => refresh());
    return () => {
      round.current++;
      clearInterval(timer);
      subscription.remove();
    };
  }, [refresh]);

  return { machines, reach, error, pulling, refresh };
}
