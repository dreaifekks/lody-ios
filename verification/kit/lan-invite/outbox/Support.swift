import Foundation
// Only transcript context is synthetic. Store, dispatcher, record, and inflight
// ownership come from production sources; this executable needs no app host.
public struct SessionTranscriptFacts: Sendable, Equatable {
  public var unfinishedTurnId: String?
  public var replied = Set<String>()
  public var entryIds = Set<String>()
  public init() {}
}
