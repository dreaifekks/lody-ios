import { openSettings, settingsRows } from './settings';

class McpCatalogUnavailable extends Error {
  constructor(readonly retryable: boolean) {
    super('mcp_catalog_unavailable');
  }
}

// Selection is absent for a fresh draft, but [] explicitly disables all servers.
export async function sessionMcpSelection(
  workspaceId: string,
  grant: Parameters<typeof openSettings>[1],
  persisted: unknown,
  signal: AbortSignal,
): Promise<string[]> {
  if (Array.isArray(persisted) && persisted.length === 0) return [];
  try {
    const { flock } = await openSettings(
      `${workspaceId}:wf:workspace`,
      grant,
      signal,
    );
    const servers = settingsRows('mcp', flock);
    const selected = Array.isArray(persisted)
      ? persisted
      : servers
          .filter((server) => server.enabledByDefault)
          .map((server) => server.id);
    const available = new Map(servers.map((server) => [server.id, server]));
    const ids = [
      ...new Set(
        selected.filter(
          (id): id is string => typeof id === 'string' && available.has(id),
        ),
      ),
    ];
    if (ids.some((id) => !available.get(id)?.configured))
      throw new Error('mcp_connection_missing');
    return ids;
  } catch (error) {
    if (error instanceof Error && error.message === 'not_found') return [];
    if (error instanceof Error && error.message === 'mcp_connection_missing')
      throw error;
    // Only known transport failures/deadlines are safe to wait and retry. A
    // forbidden catalog, malformed data or missing connection needs user action.
    const network =
      error instanceof Error &&
      ['network_error', 'timeout'].includes(error.message);
    const interrupted =
      error instanceof Error &&
      (['AbortError', 'TimeoutError'].includes(error.name) ||
        error.message === 'unknown');
    const deadline =
      interrupted &&
      signal.aborted &&
      signal.reason instanceof Error &&
      signal.reason.name === 'TimeoutError';
    throw new McpCatalogUnavailable(network || deadline);
  }
}
