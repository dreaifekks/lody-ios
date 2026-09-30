import {
  createContext,
  useContext,
  useEffect,
  useRef,
  useState,
  type PropsWithChildren,
} from 'react';
import { showToast } from '@/ui/toast';
import {
  runtimeInfo,
  readAuthToken,
  readLocalStartup,
  saveAuthToken,
  clearAuthToken,
  openAuthBrowser,
  closeAuthBrowser,
  readLanHub,
  joinLanHub,
  clearLanHub,
  type LanHubSummary,
} from '@lody-ios/kit';
import {
  AuthError,
  authRequest,
  getAccount,
  requestDeviceCode,
  pollDeviceToken,
  uploadWorkspaceIcon,
  updateWorkspace as updateWorkspaceRequest,
  updateWorkspaceIcon as updateWorkspaceIconRequest,
  type DeviceCode,
  type User,
  type Workspace,
} from './api';
import type { PickedWorkspaceIcon } from '@lody-ios/kit';

import { writeLocal, parseLocal, clearLocal } from '../kv';
import { accountKey } from './persist';
import type { SavedAccount } from '../../models/auth.ts';
import type { SavedCatalog } from '../../models/catalog.ts';
import { t } from '../../lib/i18n/index.ts';
import { uiVerify } from '@/lib/uiVerify';

/** `lan` is set when the account is a joined LAN hub instead of Lody Cloud. */
type Account = {
  token: string;
  user: User;
  workspaces: Workspace[];
  lan?: LanHubSummary;
};
type AuthState = {
  account: Account | null;
  busy: boolean;
  localReady: boolean;
  initialWorkspace: string;
  initialCatalog: SavedCatalog | null;
  code: DeviceCode | null;
  error: string | null;
};
type AuthContextValue = AuthState & {
  login: () => Promise<void>;
  joinLan: (invite: string) => Promise<void>;
  cancel: () => void;
  restore: () => Promise<void>;
  logout: () => Promise<void>;
  reopen: () => Promise<void>;
  updateWorkspace: (workspaceId: string, name: string) => Promise<void>;
  updateWorkspaceIcon: (
    workspaceId: string,
    file: PickedWorkspaceIcon,
  ) => Promise<string>;
};
const Context = createContext<AuthContextValue | null>(null);
/** Every member of a LAN acts as the one user derived from its credential. */
export function lanAccount(lan: LanHubSummary): Account {
  return {
    token: '',
    lan,
    user: {
      id: lan.userId,
      name: lan.name,
      email: lan.url.replace(/^https?:\/\//, ''),
    },
    workspaces: [{ id: lan.workspaceId, name: lan.name, slug: 'lan' }],
  };
}
const lanErrors = {
  lan_invalid_invite: 'lan.error.invalidInvite',
  lan_unauthorized: 'lan.error.unauthorized',
  lan_unreachable: 'lan.error.unreachable',
} as const;
export function lanErrorMessage(error: unknown) {
  const message = error instanceof Error ? error.message : '';
  const code = (Object.keys(lanErrors) as (keyof typeof lanErrors)[]).find(
    (key) => message.includes(key),
  );
  return t(code ? lanErrors[code] : 'lan.error.joinFailed');
}
export function AuthProvider({ children }: PropsWithChildren) {
  const [state, setState] = useState<AuthState>({
    account: null,
    busy: true,
    localReady: false,
    initialWorkspace: '',
    initialCatalog: null,
    code: null,
    error: null,
  });
  const pending = useRef<AbortController | null>(null);
  const alive = useRef(true);
  const begin = () => {
    pending.current?.abort();
    const controller = new AbortController();
    pending.current = controller;
    return controller.signal;
  };
  const update = (signal: AbortSignal, next: Partial<AuthState>) => {
    if (alive.current && !signal.aborted) setState((s) => ({ ...s, ...next }));
  };
  async function restore() {
    const signal = begin();
    if (uiVerify) {
      update(signal, { busy: false, localReady: true });
      return;
    }
    update(signal, { busy: true, error: null });
    try {
      const localStarted = performance.now();
      const [token, lan, boot] = await Promise.all([
        readAuthToken(),
        readLanHub().catch(() => null),
        readLocalStartup().catch(
          () =>
            ({}) as { account?: string; workspace?: string; catalog?: string },
        ),
      ]);
      if (signal.aborted) return;
      // A LAN needs no account service: the credential alone names the user and workspace.
      if (lan) {
        update(signal, {
          account: lanAccount(lan),
          localReady: true,
          initialWorkspace: lan.workspaceId,
          initialCatalog: parseLocal<SavedCatalog>(boot.catalog),
        });
        return;
      }
      const saved = parseLocal<SavedAccount>(boot.account);
      if (token && saved?.user?.id && Array.isArray(saved.workspaces)) {
        const initialCatalog = parseLocal<SavedCatalog>(boot.catalog);
        if (__DEV__)
          console.info(
            `LodyLocal hydrate_ms=${(performance.now() - localStarted).toFixed(2)}`,
          );
        update(signal, {
          account: { token, ...saved },
          localReady: true,
          initialWorkspace: boot.workspace ?? '',
          initialCatalog,
        });
      } else update(signal, { localReady: true });
      if (!token) {
        update(signal, { account: null });
        return;
      }
      // Match the native grant failure probe without changing product endpoints.
      if (__DEV__ && runtimeInfo.offlineProbe)
        throw new Error('Network unavailable');
      const account = await getAccount(token, signal);
      if (signal.aborted) return;
      if (saved && saved.user.id !== account.user.id) {
        await clearLocal();
        update(signal, { initialCatalog: null, initialWorkspace: '' });
      }
      await writeLocal(accountKey, account).catch(() =>
        showToast(t('auth.toast.accountSaveFailed')),
      );
      update(signal, { account: { token, ...account } });
    } catch (error) {
      if (error instanceof AuthError && !signal.aborted) {
        update(signal, { account: null, initialCatalog: null });
        await Promise.all([clearLocal(), clearAuthToken()]).catch(() =>
          showToast(t('auth.toast.clearLocalFailed')),
        );
      }
      update(signal, {
        error:
          error instanceof Error
            ? error.message
            : t('auth.error.restoreFailed'),
      });
    } finally {
      update(signal, { busy: false, localReady: true });
    }
  }
  async function login() {
    if (uiVerify)
      throw new Error('Login is disabled during offline UI verification');
    const signal = begin();
    update(signal, { busy: true, code: null, error: null });
    try {
      const code = await requestDeviceCode(signal);
      update(signal, { code });
      if (signal.aborted) throw new Error(t('common.cancelled'));
      await openAuthBrowser(code.verification_uri_complete);
      const token = await pollDeviceToken(code, signal);
      const account = await getAccount(token, signal);
      if (signal.aborted) throw new Error(t('common.cancelled'));
      await clearLocal();
      await clearLanHub();
      await saveAuthToken(token);
      await writeLocal(accountKey, account).catch(() =>
        showToast(t('auth.toast.accountSaveFailed')),
      );
      if (signal.aborted) throw new Error(t('common.cancelled'));
      update(signal, { account: { token, ...account }, code: null });
    } catch (error) {
      update(signal, {
        error:
          error instanceof Error ? error.message : t('auth.error.signInFailed'),
        code: null,
      });
    } finally {
      if (!signal.aborted) {
        await closeAuthBrowser();
        update(signal, { busy: false, localReady: true });
      }
    }
  }
  async function joinLan(invite: string) {
    if (uiVerify)
      throw new Error(
        'Joining a LAN is disabled during offline UI verification',
      );
    const signal = begin();
    update(signal, { busy: true, code: null, error: null });
    try {
      // Native checks the credential against the hub, then replaces any Cloud sign-in.
      const lan = await joinLanHub(invite);
      if (signal.aborted) {
        await clearLanHub();
        return;
      }
      await clearLocal();
      const account = lanAccount(lan);
      await writeLocal(accountKey, {
        user: account.user,
        workspaces: account.workspaces,
      }).catch(() => showToast(t('auth.toast.accountSaveFailed')));
      update(signal, {
        account,
        initialCatalog: null,
        initialWorkspace: lan.workspaceId,
      });
    } catch (error) {
      update(signal, { error: lanErrorMessage(error) });
    } finally {
      update(signal, { busy: false, localReady: true });
    }
  }
  function cancel() {
    pending.current?.abort();
    void closeAuthBrowser();
    setState((s) => ({ ...s, busy: false, code: null }));
  }
  async function logout() {
    const token = state.account?.token,
      lan = !!state.account?.lan,
      signal = begin();
    update(signal, { busy: true, error: null });
    try {
      update(signal, { account: null, code: null, initialCatalog: null });
      await Promise.all([clearLocal(), lan ? clearLanHub() : clearAuthToken()]);
      if (token) await authRequest('/sign-out', { token, body: {}, signal });
    } catch {
      update(signal, {
        error: t('auth.error.signOutIncomplete'),
      });
    } finally {
      update(signal, { busy: false, localReady: true });
    }
  }
  async function reopen() {
    if (!state.code) return;
    try {
      await openAuthBrowser(state.code.verification_uri_complete);
    } catch {
      setState((s) => ({ ...s, error: t('auth.error.openAuthorizePage') }));
    }
  }
  async function persistWorkspace(account: Account, updated: Workspace) {
    const workspaces = account.workspaces.map((workspace) =>
      workspace.id === updated.id ? updated : workspace,
    );
    await writeLocal(accountKey, { user: account.user, workspaces }).catch(() =>
      showToast(t('auth.toast.accountSaveFailed')),
    );
    setState((current) =>
      current.account?.token === account.token
        ? { ...current, account: { ...current.account, workspaces } }
        : current,
    );
  }
  async function updateWorkspace(workspaceId: string, name: string) {
    const account = state.account;
    if (!account) throw new Error(t('workspace.edit.signedOut'));
    if (account.lan) throw new Error(t('lan.error.cloudOnly'));
    const updated = await updateWorkspaceRequest(
      account.token,
      workspaceId,
      name,
    );
    await persistWorkspace(account, updated);
  }
  async function updateWorkspaceIcon(
    workspaceId: string,
    file: PickedWorkspaceIcon,
  ) {
    const account = state.account;
    if (!account) throw new Error(t('workspace.edit.signedOut'));
    if (account.lan) throw new Error(t('lan.error.cloudOnly'));
    const image = await uploadWorkspaceIcon(account.token, workspaceId, file);
    const updated = await updateWorkspaceIconRequest(
      account.token,
      workspaceId,
      image,
    );
    await persistWorkspace(account, updated);
    return image;
  }
  useEffect(() => {
    alive.current = true;
    void restore();
    return () => {
      alive.current = false;
      pending.current?.abort();
      void closeAuthBrowser();
    };
  }, []);
  return (
    <Context
      value={{
        ...state,
        login,
        joinLan,
        cancel,
        restore,
        logout,
        reopen,
        updateWorkspace,
        updateWorkspaceIcon,
      }}
    >
      {children}
    </Context>
  );
}
export function useAuth() {
  const value = useContext(Context);
  if (!value) throw new Error('Missing AuthProvider');
  return value;
}

export { Context as AuthContext };
