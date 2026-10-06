import { sessionItemDetail } from '@lody-ios/kit';
import type { DetailResponse } from '../../models/session.ts';
import type { SubagentRun } from './subagentRun.ts';

export async function fetchDetail(params: {
  sessionId: string;
  entryId: string;
  itemId: string;
  cursor?: string;
}): Promise<DetailResponse> {
  return JSON.parse(await sessionItemDetail(JSON.stringify(params)));
}

/** Every step of a sub-agent run; the session envelope carries only the latest. */
export async function fetchSubagentRun(params: {
  sessionId: string;
  entryId: string;
  itemId: string;
}): Promise<{ itemId: string; rev: number; run: SubagentRun | null }> {
  return JSON.parse(
    await sessionItemDetail(JSON.stringify({ ...params, run: true })),
  );
}
