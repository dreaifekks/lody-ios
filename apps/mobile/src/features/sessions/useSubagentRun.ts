import { useEffect, useRef, useState } from 'react';
import type { ItemSummary } from '@/models/session';
import { fetchSubagentRun } from './itemDetail';
import { runComplete, withRunItems, type SubagentTask } from './subagentRun';

type RunRead = { itemId: string; rev: number; items: ItemSummary[] };

/**
 * The task with every step of its run. The session envelope carries only the
 * latest step, so the sheet reads the run again whenever the task's rev moves,
 * one read at a time.
 */
export function useSubagentRun(
  task: SubagentTask,
  target?: { sessionId: string; entryId: string },
): SubagentTask {
  const [read, setRead] = useState<RunRead>();
  const alive = useRef(true);
  const reading = useRef({ busy: false, again: false });
  const complete = runComplete(task);
  const sessionId = target?.sessionId;
  const entryId = target?.entryId;
  const itemId = task.itemId;
  useEffect(() => {
    alive.current = true;
    return () => {
      alive.current = false;
    };
  }, []);
  useEffect(() => {
    if (complete || !sessionId || !entryId) return;
    const state = reading.current;
    if (state.busy) {
      state.again = true;
      return;
    }
    const start = () => {
      state.busy = true;
      state.again = false;
      fetchSubagentRun({ sessionId, entryId, itemId })
        .then((result) => {
          const items = result.run?.items;
          if (!alive.current || !items) return;
          // An older read that finishes late never replaces a newer one.
          setRead((old) =>
            old?.itemId === itemId && old.rev > result.rev
              ? old
              : { itemId, rev: result.rev, items },
          );
        })
        .catch(() => {})
        .finally(() => {
          state.busy = false;
          if (state.again && alive.current) start();
        });
    };
    start();
  }, [complete, sessionId, entryId, itemId, task.rev]);
  return withRunItems(task, read);
}
