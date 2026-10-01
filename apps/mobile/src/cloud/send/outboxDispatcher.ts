import { useEffect, useRef } from 'react';
import { Alert } from 'react-native';
import {
  createSession,
  sendSessionTurn,
  confirmSessionCreation,
  confirmSessionTurn,
  ensureSession,
  releaseReserve,
} from '@lody-ios/kit';
import type { PendingSession, usePendingSends } from './pendingSends';
import type { Session } from '../../models/catalog';
import { sessionState } from '../../features/sessions/status';
import { t } from '../../lib/i18n/index.ts';
import { outboxInflight } from './outboxInflight';
import { quotaError } from './quotaError';
import { notReady, pause, sessionOpened, sessionOpenFailed } from './notReady';

export const MAX_SESSION_RESERVES = 8;
export const CONFIRM_INTERVAL_MS = 5000;
export { outboxInflight };

const occupying = new Set(['creating', 'sending', 'unknown', 'uploaded']);

const network = {
  createSession,
  sendSessionTurn,
  confirmSessionCreation,
  confirmSessionTurn,
  ensureSession,
  releaseReserve,
};

export function useOutboxDispatcher({
  outbox,
  userId,
  connected,
  serverSessions,
  foregroundSessionId,
  services = network,
}: {
  outbox: ReturnType<typeof usePendingSends>;
  userId: string;
  connected: boolean;
  serverSessions: Session[];
  foregroundSessionId: string;
  services?: {
    createSession: typeof createSession;
    sendSessionTurn: typeof sendSessionTurn;
    confirmSessionCreation?: typeof confirmSessionCreation;
    confirmSessionTurn?: typeof confirmSessionTurn;
    ensureSession: typeof ensureSession;
    releaseReserve: typeof releaseReserve;
  };
}) {
  const released = useRef(new Map<string, string>());
  const confirming = useRef(new Set<string>());
  // Uploaded turns whose dispatch pointer is known to be published.
  const pointed = useRef(new Set<string>());
  const unsettled = ({ send }: PendingSession) =>
    send.phase === 'unknown' ||
    (send.phase === 'uploaded' && !pointed.current.has(send.id));
  const unresolved = outbox.records.some(unsettled);

  // A lost result is settled against the hub: delivered, or never written and
  // offered for retry. An uploaded turn gets the pointer its send could not
  // publish. Nothing here writes the message again.
  useEffect(() => {
    const { confirmSessionCreation, confirmSessionTurn } = services;
    if (!confirmSessionCreation || !confirmSessionTurn) return;
    if (!outbox.ready || !userId || !connected || !unresolved) return;
    const check = () => {
      for (const record of outbox.getSnapshot().records)
        if (unsettled(record)) void confirm(record);
    };
    check();
    const timer = setInterval(check, CONFIRM_INTERVAL_MS);
    return () => clearInterval(timer);

    async function confirm({ session, send }: PendingSession) {
      if (confirming.current.has(session.id) || outboxInflight.has(session.id))
        return;
      confirming.current.add(session.id);
      try {
        let reply: string;
        if (send.creation) {
          reply = await confirmSessionCreation!(send.creation);
        } else {
          await services.ensureSession(session.id);
          reply = await confirmSessionTurn!(
            JSON.stringify({ sessionId: session.id, id: send.id }),
          );
        }
        const verdict = JSON.parse(reply);
        const latest = outbox
          .getSnapshot()
          .records.find((item) => item.session.id === session.id);
        if (latest?.send.id !== send.id || latest.send.phase !== send.phase)
          return;
        if (send.phase === 'uploaded') {
          // The hub acknowledged this turn; only its pointer was in question.
          if (verdict.state !== 'pending') pointed.current.add(send.id);
          return;
        }
        if (verdict.state === 'created') {
          await outbox.put({
            ...latest,
            send: { ...latest.send, creation: undefined, phase: 'waiting' },
          });
        } else if (['uploaded', 'queued'].includes(verdict.state)) {
          await outbox.put({
            ...latest,
            send: { ...latest.send, phase: verdict.state },
          });
        } else if (verdict.state === 'absent') {
          const reason = t('send.error.notDelivered');
          await outbox.put({
            ...latest,
            send: {
              ...latest.send,
              id: verdict.retryId ?? latest.send.id,
              phase: 'failed',
              reason,
            },
          });
          Alert.alert(t('send.alert.title'), reason);
        }
      } catch {
        // Still unsettled; the next check asks again.
      } finally {
        confirming.current.delete(session.id);
      }
    }
  }, [outbox.ready, userId, connected, unresolved]);

  useEffect(() => {
    if (!outbox.ready || !userId) return;
    let slots = 0;
    for (const record of outbox.records) {
      if (record.session.id === foregroundSessionId) continue;
      if (occupying.has(record.send.phase)) slots += 1;
    }
    for (const record of outbox.records) void consider(record);

    async function consider(record: PendingSession) {
      const { session, send } = record;
      if (['accepted', 'queued', 'failed'].includes(send.phase)) {
        const key = `${session.id}:${send.id}:${send.phase}`;
        if (released.current.get(session.id) === key) return;
        released.current.set(session.id, key);
        await services.releaseReserve(session.id).catch(() => {});
        return;
      }
      released.current.delete(session.id);
      const catalog = serverSessions.find((item) => item.id === session.id);
      if (
        (send.phase === 'unknown' || send.phase === 'uploaded') &&
        catalog?.latestUserMsgId === send.id
      ) {
        await outbox.remove(session.id).catch(() => {});
        await services.releaseReserve(session.id).catch(() => {});
        return;
      }
      if (send.creation && catalog && send.phase === 'unknown') {
        await outbox
          .put({
            ...record,
            send: { ...send, creation: undefined, phase: 'waiting' },
          })
          .catch(() => {});
        return;
      }
      if (session.id === foregroundSessionId) return;
      if (send.phase !== 'waiting' || outboxInflight.has(session.id)) return;
      if (!connected) return;
      if (slots >= MAX_SESSION_RESERVES) return;
      slots += 1;
      outboxInflight.add(session.id);
      // Released before a record returns to waiting: the effect that record
      // wakes would otherwise find the session busy and never run again.
      let held = true;
      const release = () => {
        if (held) outboxInflight.delete(session.id);
        held = false;
      };
      let started = false;
      try {
        await outbox.put({
          ...record,
          send: { ...send, phase: send.creation ? 'creating' : 'sending' },
        });
        const latest = outbox
          .getSnapshot()
          .records.find((item) => item.session.id === session.id)?.send;
        if (
          latest?.id !== send.id ||
          latest.phase !== (send.creation ? 'creating' : 'sending')
        )
          return;
        if (send.creation) {
          started = true;
          const result = JSON.parse(
            await services.createSession(send.creation),
          );
          if (result.state === 'created') {
            release();
            await outbox.put({
              session: result.session,
              send: { ...send, creation: undefined, phase: 'waiting' },
            });
          } else if (result.state === 'rejected') {
            if (notReady(result)) await again();
            else
              await fail(
                quotaError(result.reason, t('send.error.sessionNotCreated')),
              );
          } else {
            await outbox.put({
              ...record,
              send: { ...send, phase: 'unknown' },
            });
          }
          return;
        }
        try {
          await services.ensureSession(session.id);
          sessionOpened(send.id);
        } catch {
          // Nothing was written; the session may only be reconnecting.
          if (sessionOpenFailed(send.id)) await again();
          else await fail(t('native.runtime.sessionNotSyncedRetry'));
          return;
        }
        started = true;
        const result = JSON.parse(
          await services.sendSessionTurn(
            JSON.stringify({
              id: send.id,
              sessionId: session.id,
              machineId: session.machineId,
              userId,
              guide: send.guide === true,
              queue:
                !send.guide &&
                (send.queue === true ||
                  ['live', 'attention'].includes(sessionState(session.status))),
              text: send.text,
              attachments: send.attachments,
              cliType: session.cliType,
              agentType: session.agentType,
              resume: session.resume,
              modelId: send.choice.modelId,
              modeId: send.choice.modeId,
              reasoningEffort: send.choice.effort,
              reasoningEffortConfigId: send.choice.reasoningEffortConfigId,
              configOptionValues: send.choice.configOptionValues,
            }),
          ),
        );
        if (result.state === 'not_sent') {
          if (notReady(result)) await again();
          else await fail(quotaError(result.reason, t('send.error.notSent')));
          return;
        }
        const phase = ['accepted', 'uploaded', 'queued'].includes(result.state)
          ? result.state
          : 'unknown';
        await outbox.put({ ...record, send: { ...send, phase } });
      } catch {
        if (started) {
          await outbox
            .put({ ...record, send: { ...send, phase: 'unknown' } })
            .catch(() => {});
        } else {
          await fail(t('send.error.draftSaveFailed'));
        }
      } finally {
        release();
      }
      /** The runtime wrote nothing, so the send waits and is dispatched again. */
      async function again() {
        await pause();
        const latest = outbox
          .getSnapshot()
          .records.find((item) => item.session.id === session.id)?.send;
        if (latest?.id !== send.id || latest.phase === 'failed') return;
        release();
        await outbox
          .put({ ...record, send: { ...send, phase: 'waiting' } })
          .catch(() => {});
      }
      async function fail(reason: string) {
        if (reason === 'mention_expansion_failed')
          reason = t('send.error.mentions');
        await outbox
          .put({
            session,
            send: { ...send, phase: 'failed', reason },
          })
          .catch(() => {});
        Alert.alert(t('send.alert.title'), reason);
      }
    }
  }, [
    outbox.records,
    connected,
    serverSessions,
    userId,
    foregroundSessionId,
    outbox.ready,
  ]);
}
