// Adapted from LodyAI/Lody packages/shared/src/prompt-shortcuts/access.ts
// AGPL-3.0-only; upstream e73d3109b26412186d67571992a3ba1363433645.
import { PromptShortcutError } from './model.ts';

export type ShortcutAccessDomain = {
  workspaceId: string;
  ownerUserId: string;
  visibility: 'private' | 'workspace';
};

const encode = (value: string): string => {
  if (!value || value.length > 200)
    throw new PromptShortcutError(
      'invalid_template',
      'Invalid access-domain identifier',
    );
  return encodeURIComponent(value);
};

/** Workspace-scoped Prompt Shortcut index Flock (`space_id = {workspaceId}`). */
export function getWorkspaceShortcutIndexStreamId(workspaceId: string): string {
  return `${encode(workspaceId)}:shortcut-index`;
}

/** Workspace-scoped Prompt Shortcut body LoroDoc (`space_id = {workspaceId}`). */
export function getWorkspaceShortcutBodyStreamId(
  workspaceId: string,
  documentId: string,
): string {
  return `${encode(workspaceId)}:shortcut:${encode(documentId)}`;
}

/** Legacy Phase 1 read-only fallback stream IDs. */
export function getShortcutIndexStreamId(domain: ShortcutAccessDomain): string {
  return `shortcut-index:${encode(domain.workspaceId)}:${encode(domain.ownerUserId)}:${domain.visibility}`;
}

export function getShortcutBodyStreamId(documentId: string): string {
  return `shortcut-body:${encode(documentId)}`;
}
