import Foundation

/// Message/mention resource grammar. AppLink remains the notification/deep-link route.
public struct SessionLink: Equatable, Sendable {
  public let sessionId: String
  public let workspaceId: String?
  public let tabSessionId: String?

  public init?(_ raw: String) {
    guard raw.utf16.count <= 8192,
      raw.range(of: #"[\s\\%]"#, options: .regularExpression) == nil else { return nil }
    if raw.range(of: #"^session://[A-Za-z0-9_-]+/?$"#, options: .regularExpression) != nil {
      sessionId = String(raw.dropFirst("session://".count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
      workspaceId = nil; tabSessionId = nil
      return
    }
    // Validate before URLComponents can normalize a path or authority.
    guard raw.range(of: #"^[a-zA-Z.-]+://session/[A-Za-z0-9_-]+(?:\?[^#]*)?$"#, options: .regularExpression) != nil,
      let url = URLComponents(string: raw),
      ["lody", "ai.lody.stable", "ai.lody.nightly", "lody-oss"].contains(url.scheme?.lowercased() ?? ""),
      url.host == "session", url.port == nil, url.user == nil, url.password == nil else { return nil }
    var query: [String: String] = [:]
    // URLSearchParams ignores empty '&' fields; mirror the public TS grammar.
    for field in (url.percentEncodedQuery ?? "").split(separator: "&") {
      let pair = field.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
      let key = String(pair[0])
      guard pair.count == 2, ["workspace", "tab"].contains(key), query[key] == nil,
        String(pair[1]).range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil else { return nil }
      query[key] = String(pair[1])
    }
    sessionId = String(url.path.dropFirst())
    workspaceId = query["workspace"]; tabSessionId = query["tab"]
  }
}

public enum SessionMessageLink: Equatable, Sendable {
  case session(String)
  case missingSession
  case url(URL)
  case loopback
  case none

  public static func resolve(_ href: String, workspaceId: String, sessionIds: Set<String>, machineHost: String?) -> Self {
    if let link = SessionLink(href) {
      if let workspace = link.workspaceId, workspace != workspaceId { return .missingSession }
      let id = link.tabSessionId ?? link.sessionId
      return sessionIds.contains(id) ? .session(id) : .missingSession
    }
    let value = href.trimmingCharacters(in: .whitespacesAndNewlines)
    let loopback = #"(?i)^(https?)://(localhost|127\.0\.0\.1|0\.0\.0\.0|\[::1\])(:[0-9]{1,5})?([/?#].*)?$"#
    if let range = value.range(of: loopback, options: .regularExpression), range == (value.startIndex..<value.endIndex) {
      guard let host = machineHost?.trimmingCharacters(in: .whitespacesAndNewlines), !host.isEmpty else { return .loopback }
      // Replace only the authority host; retain the original port/path/query/fragment.
      let schemeEnd = value.range(of: "://")!.upperBound
      let end = value[schemeEnd...].firstIndex(where: { "/?#".contains($0) }) ?? value.endIndex
      let authority = value[schemeEnd..<end]
      let port: Substring
      if authority.hasPrefix("[") {
        port = authority[authority.index(after: authority.firstIndex(of: "]")!)...]
      } else if let colon = authority.firstIndex(of: ":") { port = authority[colon...] }
      else { port = "" }
      let targetHost = host.contains(":") ? "[\(host)]" : host
      let rewritten = String(value[..<schemeEnd]).lowercased() + targetHost + String(port) + String(value[end...])
      guard let url = URL(string: rewritten) else { return .none }
      return .url(url)
    }
    guard let url = URL(string: value),
      ["http", "https", "file", "tg", "mailto", "tel"].contains(url.scheme?.lowercased() ?? "") else { return .none }
    return .url(url)
  }
}
