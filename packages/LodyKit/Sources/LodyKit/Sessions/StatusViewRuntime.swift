import Foundation
import LodyCore

/// The runtime's Status view methods (`packages/cloud-runtime/src/contract/status-view.ts`). Swift
/// builds the command JSON (`StatusViewCommand.json`) and decodes it into the generated params, so
/// the list keeps one Swift command type instead of mirroring the generated union case by case.
@MainActor
enum StatusViewRuntime {
  /// Runs `command` in the Home `scope` it came from (`move.beforeId` resolves against that list).
  /// Returns how many rows the runtime wrote; 0 means the planner refused it or it was a no-op.
  static func command(_ workspaceId: String, _ command: StatusViewCommand, scope: HomeScope) async throws -> Int {
    if StatusViewPreview.matches(workspaceId) { return StatusViewPreview.apply(command) }
    let runtime = try scoped(workspaceId)
    let params = try RuntimeJSON.decode(
      RuntimeContract.Calls.StatusViewCommand.Params.self,
      from: ["workspaceId": workspaceId, "command": command.json, "scope": scope.rawValue] as [String: Any]
    )
    return try await runtime.perform(RuntimeContract.Calls.StatusViewCommand.self, params).writes
  }

  /// The four Later presets resolved on the server clock, and that clock's current instant.
  static func presets(_ workspaceId: String) async throws -> (nowMs: Double, presets: [StatusViewSnoozePreset]) {
    if StatusViewPreview.matches(workspaceId) { return StatusViewPreview.presets() }
    let runtime = try scoped(workspaceId)
    let result = try await runtime.perform(RuntimeContract.Calls.SnoozePresets.self, RuntimeContract.Empty())
    return (result.nowMs, result.presets.map { StatusViewSnoozePreset(id: $0.id.rawValue, timestamp: $0.until) })
  }

  private static func scoped(_ workspaceId: String) throws -> DataRuntime {
    guard let runtime = DataRuntime.current, runtime.workspace == workspaceId else {
      throw DataRuntime.failure("not_ready", String(localized: "native.runtime.sessionNotSynced", bundle: .lody))
    }
    return runtime
  }
}
