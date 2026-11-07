import AppIntents
import Foundation

/// Answers a permission request from the Live Activity. The system performs it
/// in the app, which forwards the choice to the LAN host; the widget never holds
/// the LAN credential. The answer may run a command, so the device must be
/// unlocked first.
///
/// Compiled into both the widget extension, which only draws the buttons, and
/// the app through Shared/LiveActivity in `project.yml`, which performs it.
struct LodyPermissionIntent: LiveActivityIntent {
  static var title: LocalizedStringResource { "Answer a permission request" }
  static var authenticationPolicy: IntentAuthenticationPolicy { .requiresAuthentication }
  static var isDiscoverable: Bool { false }

  @Parameter(title: "Session") var sessionId: String
  @Parameter(title: "Request") var requestId: String
  @Parameter(title: "Option") var optionId: String

  init() {}

  init(sessionId: String, requestId: String, optionId: String) {
    self.sessionId = sessionId
    self.requestId = requestId
    self.optionId = optionId
  }

  func perform() async throws -> some IntentResult {
    try await LodyLiveActivityActions.respondPermission(sessionId: sessionId, requestId: requestId, optionId: optionId)
    return .result()
  }
}

/// Installed only by the app. The extension renders the intent without credentials.
@MainActor
enum LodyLiveActivityActions {
  static var respond: ((String, String, String) async throws -> Void)?

  static func respondPermission(sessionId: String, requestId: String, optionId: String) async throws {
    guard let respond else { throw URLError(.userAuthenticationRequired) }
    try await respond(sessionId, requestId, optionId)
  }
}
