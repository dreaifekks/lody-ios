import Foundation

public struct RuntimeHealth {
  public private(set) var lastAck: TimeInterval = 0
  public private(set) var ready = false
  private var suspendedAt: TimeInterval?
  private var startupDeadline: TimeInterval?
  private var restarts: [TimeInterval] = []
  public init() {}
  public mutating func started(at now: TimeInterval) {
    lastAck = now
    ready = false
    if startupDeadline == nil { startupDeadline = now + 40 }
  }
  public mutating func startupCompleted() { startupDeadline = nil }
  public mutating func acknowledged(at now: TimeInterval) { lastAck = now; ready = true }
  public mutating func suspend(at now: TimeInterval) {
    if suspendedAt == nil { suspendedAt = now }
  }
  public mutating func resume(at now: TimeInterval) {
    if let suspendedAt, let startupDeadline { self.startupDeadline = startupDeadline + (now - suspendedAt) }
    suspendedAt = nil
    lastAck = now
  }
  public func startupExpired(at now: TimeInterval) -> Bool {
    suspendedAt == nil && startupDeadline.map { now >= $0 } == true
  }
  public func timedOut(at now: TimeInterval) -> Bool {
    startupExpired(at: now) || (suspendedAt == nil && now - lastAck >= (ready ? 8 : 20))
  }
  public mutating func allowRestart(at now: TimeInterval) -> Bool {
    restarts.removeAll { now - $0 >= 60 }
    guard !startupExpired(at: now), restarts.count < 3 else { return false }
    restarts.append(now)
    return true
  }
}
