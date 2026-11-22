import UIKit

@MainActor
final class OnboardingPreviewController: OnboardingController {
  init() {
    let fixture = OnboardingFixture()
    super.init(service: fixture.service())
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }
}

@MainActor
private final class OnboardingFixture {
  private enum Phase { case idle, waiting, error, signedIn }

  private static let changed = Notification.Name("LodyOnboardingPreviewDidChange")
  private var phase = Phase.idle
  private var joinAttempts = 0

  func service() -> OnboardingService {
    OnboardingService(
      changes: [Self.changed],
      state: { [self] in state },
      login: { [self] _ in login() },
      cancel: { [self] in move(.error) },
      joinLAN: { [self] raw in
        joinAttempts += 1
        try await Task.sleep(for: .milliseconds(200))
        guard !raw.isEmpty, joinAttempts > 1 else { throw CancellationError() }
        move(.signedIn)
      }
    )
  }

  private func login() {
    let transitions: [Phase: Phase] = [.idle: .waiting, .waiting: .waiting, .error: .signedIn, .signedIn: .signedIn]
    let next = transitions[phase] ?? phase
    move(next)
    guard next == .waiting else { return }
    Task { [self] in
      try? await Task.sleep(for: .seconds(1.5))
      if phase == .waiting { move(.error) }
    }
  }

  private var state: OnboardingState {
    OnboardingState(
      signedIn: phase == .signedIn,
      busy: phase == .waiting,
      error: phase == .error ? String(localized: "auth.error.cancelledSignIn", bundle: .lody) : nil
    )
  }

  private func move(_ next: Phase) {
    phase = next
    NotificationCenter.default.post(name: Self.changed, object: nil)
  }

}
