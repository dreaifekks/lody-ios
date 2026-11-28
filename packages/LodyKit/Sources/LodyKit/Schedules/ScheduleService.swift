import Foundation
import LodyCore
import UIKit

typealias ScheduleItem = RuntimeContract.ScheduleItem
typealias ScheduleRule = RuntimeContract.ScheduleRule
typealias ScheduleAction = RuntimeContract.ScheduleCommandParamsAction

/// Display snapshots owned by the Schedules page, shared with its pushed editors.
/// Account/workspace changes invalidate the owner and every outstanding response.
@MainActor
final class ScheduleCache {
  var valid = true
  var pending = Set<String>()
  var result: RuntimeContract.SchedulesResult?
  var details: [String: RuntimeContract.ScheduleDetail] = [:]
  var options: CreationOptions?

  func update(_ item: ScheduleItem) {
    guard valid else { return }
    if let index = result?.items.firstIndex(where: { $0.scheduleId == item.scheduleId }) {
      result?.items[index] = item
    }
    details[item.scheduleId]?.item = item
  }

  func remove(_ id: String) {
    result?.items.removeAll { $0.scheduleId == id }
    details[id] = nil
  }

  static func optimistic(_ item: ScheduleItem, action: ScheduleAction) -> ScheduleItem? {
    guard action == .pause || action == .resume else { return nil }
    var value = item
    value.enabled = action == .resume
    // The next execution time comes only from the runtime's reconciliation.
    value.state = action == .pause
      ? .init(group: .paused, kind: .paused)
      : .init(group: .running, kind: .notScheduled)
    return value
  }
}

/// Schedule I/O through the runtime's `schedules` / `scheduleDetail` / `scheduleCommand` calls, plus
/// the creation options the editor picks computers, agents, models and modes from. Injected so the
/// offline Home fixture scripts every outcome.
@MainActor
struct ScheduleService {
  var list: (_ workspaceId: String) async throws -> RuntimeContract.SchedulesResult
  var detail: (_ workspaceId: String, _ scheduleId: String) async throws -> RuntimeContract.ScheduleDetail
  var command: (_ params: RuntimeContract.ScheduleCommandParams) async throws -> RuntimeContract.ScheduleCommandResult
  var sessionLiveStatus: (_ workspaceId: String, _ sessionId: String, _ machineId: String) async throws -> RuntimeContract.SessionLiveStatusResult
  var options: (_ workspaceId: String) async throws -> CreationOptions
  var cachedList: (_ userId: String, _ workspaceId: String) async -> RuntimeContract.SchedulesResult? = { _, _ in nil }
  var persistList: (_ userId: String, _ workspaceId: String, _ result: RuntimeContract.SchedulesResult, _ generation: Int) -> Void = { _, _, _, _ in }

  static func cacheKey(userId: String, workspaceId: String) -> String {
    "schedules:v1:" + CreateJSON.encode([userId, workspaceId])
  }

  /// The offline Home fixture scripts schedules; everything else reads the live runtime.
  static var live: ScheduleService { NativeHomeFixture.active ? ScheduleFixture.shared.service : cloud }

  static var cloud: ScheduleService {
    ScheduleService(
      list: { workspaceId in
        try await ScheduleService.runtime(workspaceId).workspaceCall(RuntimeContract.Calls.Schedules.self) { workspace, _ in
          RuntimeContract.SchedulesParams(workspaceId: workspace)
        }
      },
      detail: { workspaceId, scheduleId in
        try await ScheduleService.runtime(workspaceId).workspaceCall(RuntimeContract.Calls.ScheduleDetail.self) { workspace, _ in
          RuntimeContract.ScheduleDetailParams(workspaceId: workspace, scheduleId: scheduleId)
        }
      },
      command: { params in
        try await ScheduleService.runtime(params.workspaceId).workspaceCall(RuntimeContract.Calls.ScheduleCommand.self) { workspace, _ in
          var scoped = params
          scoped.workspaceId = workspace
          return scoped
        }
      },
      sessionLiveStatus: { workspaceId, sessionId, machineId in
        try await ScheduleService.runtime(workspaceId).workspaceCall(RuntimeContract.Calls.SessionLiveStatus.self) { workspace, _ in
          RuntimeContract.SessionLiveStatusParams(workspaceId: workspace, sessionId: sessionId, machineId: machineId)
        }
      },
      // A schedule runs later, so an offline computer is still a target (as on Web); the new-chat
      // options offer only online agents.
      options: { workspaceId in
        let result = try await ScheduleService.runtime(workspaceId).workspaceCall(RuntimeContract.Calls.CreationOptions.self) { workspace, _ in
          RuntimeContract.CreationOptionsParams(workspaceId: workspace, includeOffline: true)
        }
        return try JSONDecoder().decode(CreationOptions.self, from: JSONEncoder().encode(result))
      },
      cachedList: { userId, workspaceId in
        guard !userId.isEmpty, !workspaceId.isEmpty else { return nil }
        let key = cacheKey(userId: userId, workspaceId: workspaceId)
        let raw: String? = await withCheckedContinuation { continuation in
          LocalStore.queue.async { continuation.resume(returning: (try? LocalStore.shared.read(key)) ?? nil) }
        }
        return raw.flatMap { CreateJSON.decode(RuntimeContract.SchedulesResult.self, $0) }
      },
      persistList: { userId, workspaceId, result, generation in
        guard !userId.isEmpty, !workspaceId.isEmpty else { return }
        let key = cacheKey(userId: userId, workspaceId: workspaceId)
        let raw = CreateJSON.encode(result)
        LocalStore.queue.async { try? LocalStore.shared.write(key, raw, generation: generation) }
      }
    )
  }

  private static func runtime(_ workspaceId: String) throws -> DataRuntime {
    guard let runtime = DataRuntime.current, runtime.workspace == workspaceId else {
      throw DataRuntime.failure("not_ready", String(localized: "native.runtime.sessionNotSynced", bundle: .lody))
    }
    return runtime
  }

  /// A fresh idempotency key for one user intent (`[A-Za-z0-9_-]`, at most 50 characters).
  static func requestId() -> String { UUID().uuidString.lowercased() }
}

/// Runtime schedule failures in words. The runtime throws its codes as the error message, which
/// `DataRuntime.perform` reports as `command_failed: <code>`.
enum ScheduleFailure {
  static let codes: Set<String> = [
    "schedule_not_found", "schedule_not_owner", "schedule_machine_unsupported", "schedule_prompt_invalid",
    "schedule_trigger_invalid", "schedule_title_invalid", "schedule_message_read_only", "schedule_deleted",
    "schedule_conflict", "schedule_invalid", "schedule_write_unknown", "metadata_not_ready", "workspace_changed",
  ]

  static func code(_ error: Error, write: Bool) -> String? {
    let text = (error as NSError).localizedDescription
    let parts = text.components(separatedBy: ": ")
    if let tail = parts.last, codes.contains(tail) { return tail }
    // A write whose reply never came back may or may not have applied.
    if write, let head = parts.first, ["send_timeout", "runtime_replaced"].contains(head) { return "schedule_write_unknown" }
    return nil
  }

  /// `true` when the write may have applied: the user must check before retrying.
  static func unknown(_ error: Error) -> Bool { code(error, write: true) == "schedule_write_unknown" }

  static func message(_ error: Error, write: Bool) -> String {
    guard let code = code(error, write: write) else {
      return String(localized: String.LocalizationValue(write ? "schedules.saveError" : "schedules.loadError"), bundle: .lody)
    }
    return String(localized: String.LocalizationValue("schedules.error." + code), bundle: .lody)
  }
}

/// Pre-run check for manual "Run now" on schedules that target an existing or owned chat.
@MainActor
enum ScheduleRunPrecheck {
  enum Decision: Equatable {
    case runImmediately
    case confirmBusy(chatTitle: String)
    case confirmUnknown(chatTitle: String)
  }

  /// Bound chat id when a manual run targets one existing chat, or `nil` when it creates a new chat.
  static func boundSessionId(for item: ScheduleItem) -> String? {
    switch item.destination {
    case .existingSession:
      return item.destinationSessionId
    case .ownSession:
      return item.destinationSessionId ?? item.lastSessionId
    case .newSession:
      return nil
    }
  }

  static func chatTitle(for sessionId: String, in catalog: SessionCatalog) -> String {
    if let raw = catalog.session(sessionId)?.title {
      let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      if !trimmed.isEmpty { return trimmed }
    }
    return ScheduleFormat.text("destination.untitledChat")
  }

  static func evaluate(
    item: ScheduleItem,
    workspaceId: String,
    catalog: SessionCatalog,
    service: ScheduleService
  ) async -> Decision {
    guard let sessionId = boundSessionId(for: item), !sessionId.isEmpty else {
      return .runImmediately
    }
    let title = chatTitle(for: sessionId, in: catalog)
    do {
      let status = try await service.sessionLiveStatus(workspaceId, sessionId, item.machineId)
      switch status.state {
      case .idle:
        return .runImmediately
      case .busy:
        return .confirmBusy(chatTitle: title)
      case .unknown:
        return .confirmUnknown(chatTitle: title)
      }
    } catch {
      return .confirmUnknown(chatTitle: title)
    }
  }

  static func confirmationAlert(
    item: ScheduleItem,
    decision: Decision,
    detail: Bool,
    onConfirm: @escaping () -> Void
  ) -> UIAlertController? {
    let title: String
    let message: String
    switch decision {
    case .runImmediately:
      return nil
    case .confirmBusy(let chatTitle):
      title = String(format: ScheduleFormat.text("runNowBusyTitle"), chatTitle)
      let helpKey = detail ? "runNowBusyDetailHelp" : "runNowBusyHelp"
      message = String(format: ScheduleFormat.text(helpKey), item.title)
    case .confirmUnknown(let chatTitle):
      title = String(format: ScheduleFormat.text("runNowStatusUnknownTitle"), chatTitle)
      let helpKey = detail ? "runNowStatusUnknownDetailHelp" : "runNowStatusUnknownHelp"
      message = String(format: ScheduleFormat.text(helpKey), item.title)
    }
    let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: ScheduleFormat.text("cancel"), style: .cancel))
    alert.addAction(UIAlertAction(title: ScheduleFormat.text("runNowConfirm"), style: .default) { _ in
      onConfirm()
    })
    return alert
  }
}
