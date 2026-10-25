import Foundation

final class NotificationObservers {
  private var tokens: [NSObjectProtocol] = []
  func add(_ token: NSObjectProtocol) { tokens.append(token) }
  deinit { for token in tokens { NotificationCenter.default.removeObserver(token) } }
}
