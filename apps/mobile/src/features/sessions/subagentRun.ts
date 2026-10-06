import type { ItemSummary } from '../../models/session.ts';
import { t, tp } from '../../lib/i18n/index.ts';

export type SubagentTask = Extract<ItemSummary, { type: 'subagent_task' }>;

export type SubagentRun = NonNullable<SubagentTask['run']>;

const terminal = new Set(['completed', 'failed', 'cancelled']);

/** Whether the task already holds every step rather than only the latest. */
export function runComplete(task: SubagentTask) {
  const run = task.run;
  return (
    !run || run.itemCount === undefined || run.items.length >= run.itemCount
  );
}

/**
 * The task with the steps its sheet read on demand. The envelope's latest
 * step replaces or extends them while it is at least as new as that read.
 */
export function withRunItems(
  task: SubagentTask,
  read: { itemId: string; rev: number; items: ItemSummary[] } | undefined,
): SubagentTask {
  const run = task.run;
  if (!run || runComplete(task) || read?.itemId !== task.itemId) return task;
  const items = read.items.slice();
  const latest = run.items.at(-1);
  if (latest && task.rev >= read.rev) {
    const index = items.findIndex((item) => item.itemId === latest.itemId);
    if (index < 0) items.push(latest);
    else items[index] = latest;
  }
  return { ...task, run: { ...run, items, itemCount: undefined } };
}

export function runEntries(task: SubagentTask) {
  const run = task.run;
  if (!run) return [];
  const finished = terminal.has(run.state);
  return [
    {
      id: `run:${task.itemId}`,
      rev: task.rev,
      role: 'assistant',
      status: finished ? 'completed' : 'running',
      finished,
      items: run.items,
    },
  ];
}

const tokens = (value: number) =>
  value >= 1000 ? `${(value / 1000).toFixed(1)}k` : String(value);

export function runMeta(task: SubagentTask) {
  const run = task.run;
  if (!run) return '';
  return [
    run.modelId,
    run.totalTokens === undefined
      ? ''
      : t('subagent.run.tokens', { value: tokens(run.totalTokens) }),
    run.toolCallCount === undefined
      ? ''
      : tp('subagent.run.tools', run.toolCallCount, {
          count: run.toolCallCount,
        }),
    run.contextUsagePercent === undefined
      ? ''
      : t('subagent.run.context', { value: run.contextUsagePercent }),
  ]
    .filter(Boolean)
    .join(' · ');
}

export function liveTask(
  task: SubagentTask,
  entryId: string,
  entriesJSON: string,
): SubagentTask {
  const entries = JSON.parse(entriesJSON) as {
    id: string;
    items?: ItemSummary[];
  }[];
  const found = entries
    .find((entry) => entry.id === entryId)
    ?.items?.find((item) => item.itemId === task.itemId);
  return found?.type === 'subagent_task' ? (found as SubagentTask) : task;
}
