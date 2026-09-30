import { requireNativeView } from 'expo';
import type { ComponentType } from 'react';
import type { NativeSyntheticEvent, ViewProps } from 'react-native';

export type TerminalState = {
  state: 'connecting' | 'ready' | 'exited' | 'failed';
  title?: string;
  message?: string;
};

/**
 * A shell on a LAN member in one session's directory. The credential stays
 * native; the source names only the workspace, machine, endpoint and session.
 */
export const TerminalView: ComponentType<
  ViewProps & {
    sourceJSON: string;
    onState?: (event: NativeSyntheticEvent<TerminalState>) => void;
  }
> = requireNativeView('LodyKit', 'LodyTerminalView');
