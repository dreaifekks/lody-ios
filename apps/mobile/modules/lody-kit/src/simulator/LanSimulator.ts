import { requireNativeModule } from 'expo';
import type {
  IosSimulatorCommand,
  IosSimulatorReply,
} from '../runtime/LodyKit';

const native = requireNativeModule<{
  lanSimulatorControl(payload: string): Promise<string>;
  lanSimulatorRelease(sessionId: string): Promise<void>;
}>('LodyKit');

/** The LAN member that runs a session, at the endpoint its machine metadata publishes. */
export type LanSimulatorTarget = {
  workspaceId: string;
  machineId: string;
  host: string;
  port: number;
};

/**
 * A simulator command for a session another LAN member runs, over its
 * `control` service. A viewer in the reply listens on this device's loopback
 * at the member's port until the operation ends or the port is released.
 */
export const lanSimulatorControl = async (
  target: LanSimulatorTarget,
  sessionId: string,
  command: IosSimulatorCommand,
): Promise<IosSimulatorReply> =>
  JSON.parse(
    await native.lanSimulatorControl(
      JSON.stringify({ ...target, sessionId, command }),
    ),
  );

/** Ends the loopback port that carries the session's viewer. */
export const lanSimulatorRelease = (sessionId: string) =>
  native.lanSimulatorRelease(sessionId);
