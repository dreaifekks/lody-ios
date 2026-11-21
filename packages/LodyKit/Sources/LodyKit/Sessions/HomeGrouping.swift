import Foundation

/// How iPhone Home groups chats; chosen in the view menu, stored per device. Time and project
/// groups list chats newest activity first; Status lists the runtime's Focus / Later / Settled
/// layout in its order. Defaults to status.
enum HomeGrouping: String, CaseIterable, Sendable {
  case time, project, status

  private static let key = "homeChatGrouping"

  static var stored: HomeGrouping {
    UserDefaults.standard.string(forKey: key).flatMap(HomeGrouping.init(rawValue:)) ?? .status
  }

  static func store(_ value: HomeGrouping) {
    UserDefaults.standard.set(value.rawValue, forKey: key)
    NotificationCenter.default.post(name: .lodyHomeGroupingChanged, object: nil)
  }
}

/// Whose chats Home lists: only the signed-in user's, or the whole workspace's. Chosen in the
/// view menu, stored per device; defaults to My tasks, so a new person starts on their own chats.
enum HomeScope: String, CaseIterable, Sendable {
  case mine, team

  private static let key = "homeChatScope"

  static var stored: HomeScope {
    UserDefaults.standard.string(forKey: key).flatMap(HomeScope.init(rawValue:)) ?? .mine
  }

  static func store(_ value: HomeScope) {
    UserDefaults.standard.set(value.rawValue, forKey: key)
    NotificationCenter.default.post(name: .lodyHomeGroupingChanged, object: nil)
  }
}

/// The view menu's Archived switch: while on, Chats lists only archived chats on a darker,
/// greyer page. Kept in memory, so every launch opens on the open chats.
enum HomeArchive {
  /// Read and written only from the main thread (view menus and list rendering).
  nonisolated(unsafe) private(set) static var shown = false

  static func set(_ value: Bool) {
    guard value != shown else { return }
    shown = value
    NotificationCenter.default.post(name: .lodyHomeGroupingChanged, object: nil)
  }
}

/// The catalog's CI letters as web reads them: s pass; f / e fail; p pending; x expected.
enum PullRequestCI: String, Sendable {
  case pass, fail, pending, expected

  init?(_ letter: String?) {
    switch letter {
    case "s": self = .pass
    case "f", "e": self = .fail
    case "p": self = .pending
    case "x": self = .expected
    default: return nil
    }
  }
}

extension Notification.Name {
  static let lodyHomeGroupingChanged = Notification.Name("LodyHomeGroupingChanged")
}
