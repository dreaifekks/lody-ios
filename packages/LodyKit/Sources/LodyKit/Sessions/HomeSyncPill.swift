import LodyDesignSystem
import SwiftUI

/// Home's catalog connection, reduced to what the centre pill shows.
enum HomeSyncState: Equatable, Sendable {
  case live, syncing, connecting
}

/// The floating status pill centred in the Home navigation bar, mirroring the web
/// `MobileConnectionStatus`: a spinner while syncing or reconnecting (the runtime keeps
/// retrying, so a lost connection reads as "Connecting", never "Offline"), and a brief
/// green check after recovering. It never takes taps; nothing shows while live.
struct HomeSyncPill: View {
  enum Shown: Equatable { case syncing, connecting, recovered }

  let state: Shown?

  var body: some View {
    ZStack {
      if let state {
        HStack(spacing: LodySpacing.xs + LodySpacing.xxs) {
          mark(state)
          Text(label(state))
            .lodyTextStyle(.callout, fontOnly: true)
            .foregroundStyle(tint(state))
            .lineLimit(1)
        }
        .fixedSize(horizontal: true, vertical: false)
        .padding(.horizontal, LodySpacing.lg)
        .frame(height: LodySize.touchTarget)
        .glassEffect(.regular, in: .capsule)
        .transition(.scale(scale: 0.9).combined(with: .opacity).combined(with: .offset(y: -6)))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.updatesFrequently)
      }
    }
    .animation(LodySpring.snappy, value: state)
    .onChange(of: state) { _, next in
      guard let next else { return }
      AccessibilityNotification.Announcement(label(next)).post()
    }
  }

  @ViewBuilder
  private func mark(_ state: Shown) -> some View {
    switch state {
    case .syncing, .connecting: ProgressView().controlSize(.mini)
    case .recovered:
      LodyIcon.check.image.resizable().renderingMode(.template)
        .foregroundStyle(LodyColor.successDefault)
        .frame(width: LodyIconSize.xs, height: LodyIconSize.xs)
    }
  }

  private func label(_ state: Shown) -> String {
    switch state {
    case .syncing: String(localized: "home.status.syncing", bundle: .lody)
    case .connecting: String(localized: "home.status.connecting", bundle: .lody)
    case .recovered: String(localized: "home.status.connected", bundle: .lody)
    }
  }

  private func tint(_ state: Shown) -> Color {
    switch state {
    case .syncing, .connecting: LodyColor.textSecondary
    case .recovered: LodyColor.successDefault
    }
  }
}
