import CryptoKit
import Foundation

/// A self-hosted Lody LAN hub credential. Parsing and the derived ids match
/// Lody's `parseLanInvite`, `deriveLanHubId` and `deriveLanHubUserId`, so this
/// device meets the desktop members in the same workspace as the same user.
public struct LanInvite: Codable, Equatable, Sendable {
  public enum Failure: Error, Equatable { case invalidInvite, invalidToken, invalidName }

  public static let defaultName = "Lody LAN"
  public static let workspacePrefix = "lw_"
  /// The slug RN gives the LAN workspace; push routes use it.
  public static let workspaceSlug = "lan"
  public static let userPrefix = "local:"
  public static let nameLimit = 40

  /// Hub origin, e.g. `http://100.64.0.1:8788`.
  public let url: String
  public let token: String
  public let name: String?
  /// The hub term this device follows (`lan-hub-terms.json` on a desktop);
  /// absent until the hub moved once.
  public var term: Int? = nil

  public init(url: String, token: String, name: String?, term: Int? = nil) {
    self.url = url; self.token = token; self.name = name; self.term = term
  }

  /// The same LAN at the address its hub moved to.
  public func moved(to url: String, term: Int) -> LanInvite {
    LanInvite(url: url, token: token, name: name, term: term)
  }

  public var id: String { Self.digest("lody-lan-hub:workspace:\(token)") }
  public var workspaceId: String { Self.workspacePrefix + id }
  public var userId: String { Self.userPrefix + Self.digest("lody-lan-hub:user:\(token)") }
  public var displayName: String { name ?? Self.defaultName }

  public static func isWorkspace(_ workspace: String) -> Bool { workspace.hasPrefix(workspacePrefix) }

  /// `lody-lan://<token>@host:port[/<name>]`; `lody-lans://` reaches the hub over https.
  public static func parse(_ input: String) throws -> LanInvite {
    let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let separator = text.range(of: "://") else { throw Failure.invalidInvite }
    let scheme = text[..<separator.lowerBound].lowercased()
    guard scheme == "lody-lan" || scheme == "lody-lans" else { throw Failure.invalidInvite }
    let secure = scheme == "lody-lans"
    let rest = text[separator.upperBound...]
    guard !rest.isEmpty,
          let parts = URLComponents(string: "\(secure ? "https" : "http")://\(rest)"),
          let encodedUser = parts.percentEncodedUser, !encodedUser.isEmpty,
          parts.percentEncodedPassword == nil, parts.percentEncodedQuery == nil,
          parts.percentEncodedFragment == nil,
          let host = parts.host, !host.isEmpty else { throw Failure.invalidInvite }
    guard let token = encodedUser.removingPercentEncoding, isToken(token) else { throw Failure.invalidToken }
    let path = parts.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    var name: String?
    if !path.isEmpty {
      guard let decoded = path.removingPercentEncoding else { throw Failure.invalidInvite }
      let collapsed = decoded.split(whereSeparator: \.isWhitespace).joined(separator: " ")
      guard !collapsed.isEmpty, collapsed.count <= nameLimit else { throw Failure.invalidName }
      name = collapsed
    }
    let defaultPort = secure ? 443 : 80
    let bare = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
    let authority = bare.contains(":") ? "[\(bare)]" : bare
    let port = parts.port.flatMap { $0 == defaultPort ? nil : ":\($0)" } ?? ""
    return LanInvite(url: "\(secure ? "https" : "http")://\(authority)\(port)", token: token, name: name)
  }

  /// The token travels in an HTTP header and in an invite link.
  public static func isToken(_ value: String) -> Bool {
    let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._~+/=-")
    return !value.isEmpty && value.unicodeScalars.allSatisfy(allowed.contains)
  }

  private static func digest(_ value: String) -> String {
    String(SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined().prefix(32))
  }
}
