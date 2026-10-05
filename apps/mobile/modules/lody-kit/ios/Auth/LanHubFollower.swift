import CryptoKit
import Foundation

/// Follows a LAN's hub to another machine, as Lody's `LanMembership` does for a
/// desktop member. A hub that was handed over answers its old address with the
/// new one, signed with the credential (`/lan/where`, `hub-handover.ts`); a hub
/// that failed over to its standby says nothing, so the members are asked over
/// the connection terminals use (`lan-hub-peers.ts`). The credential stays the
/// same, and with it the workspace and the user.
enum LanHubFollower {
  struct Location: Equatable, Sendable {
    let url: String
    /// `nil` from a hub of a build without terms.
    let term: Int?
  }

  struct Member: Sendable {
    let machineId: String
    let endpoint: LanTerminalEndpoint
  }

  enum HubAnswer: Equatable {
    case stays
    case moved(Location)
    case unreachable
  }

  static let wherePath = "/lan/where"
  /// Members asked at once; a LAN has a handful.
  static let memberLimit = 16

  /// Lody's `normalizeLanHubUrl`: the origin of an http(s) address.
  static func normalize(_ input: String) -> String? {
    let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let parts = URLComponents(string: trimmed),
          let scheme = parts.scheme?.lowercased(), scheme == "http" || scheme == "https",
          parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
          parts.path.isEmpty || parts.path == "/",
          let host = parts.host?.lowercased(), !host.isEmpty else { return nil }
    let bare = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    let authority = bare.contains(":") ? "[\(bare)]" : bare
    let port = parts.port.flatMap { $0 == (scheme == "https" ? 443 : 80) ? nil : ":\($0)" } ?? ""
    return "\(scheme)://\(authority)\(port)"
  }

  /// Lody's `verifyLanHubMove`: the address signed alone, and with a term the
  /// term and address signed together. Only the credential's holder can point
  /// this device elsewhere, and this device sends the credential there.
  static func verify(_ body: [String: Any], token: String) -> Location? {
    guard let movedTo = body["movedTo"] as? String, let url = normalize(movedTo),
          let signature = body["signature"] as? String,
          valid(signature, key: "lody-lan-hub:moved:\(token)", message: url) else { return nil }
    let termSignature = body["termSignature"] as? String
    guard let term = body["term"] as? Int else {
      return termSignature == nil ? Location(url: url, term: nil) : nil
    }
    guard term >= 0, let termSignature,
          valid(termSignature, key: "lody-lan-hub:location:\(token)", message: "\(term)\n\(url)") else { return nil }
    return Location(url: url, term: term)
  }

  /// Lody's `adopt`: a later term wins, and within one term the address that
  /// sorts first, so every member settles on the same hub. A hub without terms
  /// points somewhere later than anything known.
  static func adopt(_ invite: LanInvite, _ location: Location) -> LanInvite? {
    let known = invite.term ?? 0
    let term = location.term ?? known + 1
    let later = term > known || (term == known && location.url != invite.url && location.url < invite.url)
    return later ? invite.moved(to: location.url, term: term) : nil
  }

  /// Asks the hub at the invite's address whether it moved.
  static func askHub(_ invite: LanInvite) async -> HubAnswer {
    guard let url = URL(string: invite.url + wherePath) else { return .unreachable }
    var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
    request.setValue("Bearer \(invite.token)", forHTTPHeaderField: "Authorization")
    let data: Data
    let status: Int
    do {
      let reply = try await URLSession(configuration: .ephemeral, delegate: HubOnly(), delegateQueue: nil).data(for: request)
      data = reply.0
      status = (reply.1 as? HTTPURLResponse)?.statusCode ?? 0
    } catch { return .unreachable }
    // A hub that is handing over answers 503; one behind a proxy that lost it, 502/504.
    if status == 0 || status >= 500 { return .unreachable }
    guard status == 200 || status == 410,
          let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          let location = verify(body, token: invite.token), location.url != invite.url else { return .stays }
    return .moved(location)
  }

  /// Where the members that reach a hub follow it. Their answers are not
  /// signed: only a member completes the TLS-PSK handshake of the connection.
  static func askMembers(_ invite: LanInvite, members: [Member]) async -> Location? {
    let key = LanTerminalProtocol.key(token: invite.token)
    let lanId = invite.id
    let answers = await withTaskGroup(of: Location?.self, returning: [Location].self) { group in
      for member in members.prefix(memberLimit) {
        group.addTask {
          let channel = LanFileChannel(endpoint: member.endpoint, lanId: lanId, key: key, machineId: member.machineId)
          defer { channel.close() }
          do {
            try await channel.open(service: "hub")
            let answer = try await channel.request(["type": "where"], timeout: 15)
            guard answer["type"] as? String == "where", answer["reachable"] as? Bool == true,
                  let location = answer["location"] as? [String: Any],
                  let raw = location["url"] as? String, let url = normalize(raw),
                  let term = location["term"] as? Int, term >= 0 else { return nil }
            return Location(url: url, term: term)
          } catch { return nil }
        }
      }
      var found: [Location] = []
      for await answer in group { if let answer { found.append(answer) } }
      return found
    }
    return answers.max { left, right in
      let leftTerm = left.term ?? 0, rightTerm = right.term ?? 0
      return leftTerm != rightTerm ? leftTerm < rightTerm : left.url > right.url
    }
  }

  /// The members a projected catalog names: machines that publish a
  /// `lanTerminal` endpoint (`machineTerminals`).
  static func members(catalog: String?) -> [Member] {
    guard let catalog,
          let object = try? JSONSerialization.jsonObject(with: Data(catalog.utf8)) as? [String: Any],
          let terminals = object["machineTerminals"] as? [String: Any] else { return [] }
    return terminals.compactMap { machineId, value in
      guard let value = value as? [String: Any], let host = value["host"] as? String,
            !host.trimmingCharacters(in: .whitespaces).isEmpty,
            let port = (value["port"] as? Int).flatMap({ UInt16(exactly: $0) }), port > 0 else { return nil }
      return Member(machineId: machineId, endpoint: LanTerminalEndpoint(host: host, port: port))
    }
  }

  /// The invite at the hub's current address and term, or `nil` while it stays.
  /// The members are read only when the hub does not answer.
  static func locate(_ invite: LanInvite, members: @Sendable () async -> [Member]) async -> LanInvite? {
    switch await askHub(invite) {
    case .stays:
      return nil
    case .moved(let location):
      return adopt(invite, location)
    case .unreachable:
      let members = await members()
      guard !members.isEmpty, let location = await askMembers(invite, members: members),
            let next = adopt(invite, location) else { return nil }
      // A member names the hub it reaches; this device follows only one that
      // takes the credential from here.
      if next.url != invite.url {
        do { try await LanHub.probe(next) } catch { return nil }
      }
      return next
    }
  }

  /// The LAN credential is for the hub alone; never follow it elsewhere.
  private final class HubOnly: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest) async -> URLRequest? {
      nil
    }
  }

  private static func valid(_ hex: String, key: String, message: String) -> Bool {
    guard let code = bytes(hex: hex) else { return false }
    let key = SymmetricKey(data: SHA256.hash(data: Data(key.utf8)))
    return HMAC<SHA256>.isValidAuthenticationCode(code, authenticating: Data(message.utf8), using: key)
  }

  private static func bytes(hex: String) -> Data? {
    let digits = Array(hex.utf8)
    guard digits.count == 64 else { return nil }
    var data = Data(capacity: 32)
    for index in stride(from: 0, to: digits.count, by: 2) {
      guard let byte = UInt8(String(decoding: digits[index..<index + 2], as: UTF8.self), radix: 16) else { return nil }
      data.append(byte)
    }
    return data
  }
}
