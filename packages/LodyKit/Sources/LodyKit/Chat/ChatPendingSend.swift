import Foundation

/// Local visual state uses the dispatch ID, so authoritative history takes its place.
struct ChatAttachmentUploadProgress: Decodable, Equatable {
  let phase: String
  let percent: Int?
}

/// A chip in message text as a UTF-16 range. Lives here because the Share Extension compiles this file
/// without the transcript sources.
struct ChatTextReference: Decodable, Equatable {
  var start: Int
  var end: Int
  let kind: String
  let target: String?
  /// `message_quote` only: the quoted snapshot this range shows (runtime `presentMessageText`).
  var quote: String? = nil
}

struct ChatPendingSend: Decodable {
  struct Attachment: Decodable {
    let id: String
    let name: String
    let uri: String
    let kind: String
  }
  let id: String
  let text: String
  let attachments: [Attachment]
  let status: String
  var displayText: String? = nil
  /// The composer's chips as ranges of `displayText`.
  var references: [ChatTextReference]? = nil
  var startedAt: Double? = nil
  var failed: Bool? = nil
  var reason: String? = nil
  var reconnect: Bool? = nil
  var queue: Bool? = nil
  var guide: Bool? = nil
  var phase: String? = nil
  var uploadProgress: [String: ChatAttachmentUploadProgress]? = nil
  /// The composer's quote cards, sent after the text (`ChatMessageQuote`).
  var quotes: [ChatMessageQuote]? = nil
}
