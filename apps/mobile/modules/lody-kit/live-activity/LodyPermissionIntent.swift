import AppIntents
import Foundation
#if canImport(LodyKit)
import LodyKit
#endif

/// Answers a permission request from the Live Activity. The system performs it
/// in the app, which forwards the choice to the LAN host; the widget never holds
/// the LAN credential. The answer may run a command, so the device must be
/// unlocked first.
///
/// Compiled into both the widget extension, which only draws the buttons, and
/// the app (see `plugins/push-extension.rb`), which performs it.
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
    #if canImport(LodyKit)
    try await LodyLiveActivityActions.respondPermission(sessionId: sessionId, requestId: requestId, optionId: optionId)
    #endif
    return .result()
  }
}
