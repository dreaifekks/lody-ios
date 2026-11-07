import Foundation

/// The joined LAN hub. Its credential stays in Keychain; RN and the data
/// runtime only ever see the summary and the `lody-hub://<id>` address.
public enum LanHub {
  public enum Failure: Error { case unauthorized, unreachable(Int?) }

  public static func current() throws -> LanInvite? { try read() }

  /// Native-only hub call. Reject absolute/authority URLs and redirects so the
  /// bearer cannot escape the supplied hub. UI/runtime receive only projections.
  public static func request(_ invite: LanInvite, path: String, method: String = "GET", body: Data? = nil,
    timeout: TimeInterval = 15) async throws -> (Data, HTTPURLResponse) {
    guard path.hasPrefix("/"), !path.hasPrefix("//"),
      let base = URLComponents(string: invite.url),
      let url = URL(string: invite.url + path),
      let target = URLComponents(url: url, resolvingAgainstBaseURL: false),
      target.scheme == base.scheme, target.host == base.host, target.port == base.port,
      target.user == nil, target.password == nil, target.fragment == nil else { throw Failure.unreachable(nil) }
    var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
    request.httpMethod = method; request.httpBody = body
    request.setValue("Bearer \(invite.token)", forHTTPHeaderField: "Authorization")
    if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
    let config = URLSessionConfiguration.ephemeral
    config.httpShouldSetCookies = false; config.httpCookieStorage = nil
    let session = URLSession(configuration: config, delegate: HubOnly(), delegateQueue: nil)
    defer { session.invalidateAndCancel() }
    let (data, response) = try await session.data(for: request)
    guard let response = response as? HTTPURLResponse else { throw Failure.unreachable(nil) }
    return (data, response)
  }

  public static func read() throws -> LanInvite? {
    guard let stored = try AuthKeychain.read(account: AuthKeychain.lanHub) else { return nil }
    return try? JSONDecoder().decode(LanInvite.self, from: Data(stored.utf8))
  }

  public static func save(_ invite: LanInvite) throws {
    let data = try JSONEncoder().encode(invite)
    try AuthKeychain.save(String(decoding: data, as: UTF8.self), account: AuthKeychain.lanHub)
  }

  public static func clear() throws { try AuthKeychain.clear(account: AuthKeychain.lanHub) }

  /// The credential that owns this workspace, if the runtime is on a LAN.
  public static func credential(for workspace: String) -> LanInvite? {
    guard LanInvite.isWorkspace(workspace), let invite = try? read(), invite.workspaceId == workspace else { return nil }
    return invite
  }

  public static func summary(_ invite: LanInvite) -> LanHubSummary { LanHubSummary(invite) }

  /// Mirrors Lody's `probeLanHub`: 401/403 rejects the credential, and a
  /// missing meta stream still proves the hub is reachable.
  public static func probe(_ invite: LanInvite) async throws {
    let stream = "\(invite.workspaceId):meta".addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-_.~"))) ?? ""
    let status: Int
    do {
      let (_, response) = try await request(invite, path: "/ds/lody/\(stream)", method: "HEAD", timeout: 10)
      status = response.statusCode
    } catch { throw Failure.unreachable(nil) }
    try validateProbeStatus(status)
  }

  static func validateProbeStatus(_ status: Int) throws {
    if status == 401 || status == 403 { throw Failure.unauthorized }
    guard (200..<300).contains(status) || status == 404 else { throw Failure.unreachable(status) }
  }

  /// The GitHub token the hub keeps for its members (`lody-lan lan github
  /// setup`), asked at Lody's `/github/token` behind the LAN credential. nil
  /// when the hub has none or predates it. The token stays in native memory.
  public static func githubToken(_ invite: LanInvite) async throws -> String? {
    let data: Data
    let status: Int
    do {
      let reply = try await request(invite, path: "/github/token")
      data = reply.0; status = reply.1.statusCode
    } catch { throw Failure.unreachable(nil) }
    if status == 404 { return nil }
    if status == 401 || status == 403 { throw Failure.unauthorized }
    guard (200..<300).contains(status) else { throw Failure.unreachable(status) }
    let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    guard let token = body?["token"] as? String, !token.isEmpty else { return nil }
    return token
  }

  /// The LAN credential is for the hub alone; never follow it elsewhere.
  private final class HubOnly: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest) async -> URLRequest? {
      nil
    }
  }

  /// Keeps one connection to the hub, so successive measurements reuse it.
  private static let latencySession: URLSession = {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpMaximumConnectionsPerHost = 1
    configuration.timeoutIntervalForRequest = 5
    return URLSession(configuration: configuration, delegate: HubOnly(), delegateQueue: nil)
  }()

  /// Milliseconds from sending the probe's request to the hub's first byte,
  /// leaving out connection setup; nil when the hub does not answer it.
  public static func latency(_ invite: LanInvite) async -> Int? {
    let stream = "\(invite.workspaceId):meta".addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-_.~"))) ?? ""
    guard let url = URL(string: "\(invite.url)/ds/lody/\(stream)") else { return nil }
    var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 5)
    request.httpMethod = "HEAD"
    request.setValue("Bearer \(invite.token)", forHTTPHeaderField: "Authorization")
    let metrics = LatencyMetrics()
    var sent = Date()
    guard let reply = try? await latencySession.data(for: request, delegate: metrics),
          let status = (reply.1 as? HTTPURLResponse)?.statusCode,
          (200..<300).contains(status) || status == 404 else { return nil }
    var answered = Date()
    if let start = metrics.transaction?.requestStartDate, let end = metrics.transaction?.responseStartDate {
      sent = start
      answered = end
    }
    return max(0, Int((answered.timeIntervalSince(sent) * 1000).rounded()))
  }

  private final class LatencyMetrics: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private(set) var transaction: URLSessionTaskTransactionMetrics?
    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
      transaction = metrics.transactionMetrics.last
    }
  }
}

/// Safe for UI, SQLite and App Group projections. Never contains the bearer.
public struct LanHubSummary: Codable, Equatable, Sendable {
  public let id: String
  public let name: String
  public let url: String
  public let workspaceId: String
  public let userId: String

  public init(_ invite: LanInvite) {
    id = invite.id; name = invite.displayName; url = invite.url
    workspaceId = invite.workspaceId; userId = invite.userId
  }
}
