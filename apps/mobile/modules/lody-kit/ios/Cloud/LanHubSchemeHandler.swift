import WebKit

/// Serves the data runtime's `lody-hub://<id>` origin from a LAN hub, like the
/// desktop shell's `lody-hub` protocol. The bearer is added here, so the
/// long-lived LAN credential never enters the WebView, and the page and its
/// Streams requests share one origin, so a plain-http hub is not mixed content.
@MainActor
final class LanHubSchemeHandler: NSObject, WKURLSchemeHandler {
  static let scheme = "lody-hub"
  static func origin(_ invite: LanInvite) -> String { "\(scheme)://\(invite.id)" }

  private static let requestHeadersDropped: Set<String> = ["authorization", "cookie", "host", "origin", "referer", "content-length"]
  private static let responseHeadersDropped: Set<String> = ["content-encoding", "content-length", "set-cookie", "transfer-encoding", "connection"]
  private static let cors = ["Access-Control-Allow-Origin": "*", "Access-Control-Expose-Headers": "*"]

  private let invite: LanInvite
  private let relay = Relay()
  private var session: URLSession?
  private var pending: [Int: any WKURLSchemeTask] = [:]
  private var tasks: [ObjectIdentifier: URLSessionDataTask] = [:]

  init(invite: LanInvite) {
    self.invite = invite
    super.init()
    relay.owner = self
    session = makeSession()
  }

  private func makeSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    // Catalog, machine, session and RPC long-polls stay open together.
    configuration.httpMaximumConnectionsPerHost = 32
    configuration.timeoutIntervalForRequest = 120
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.urlCache = nil
    configuration.httpShouldSetCookies = false
    return URLSession(configuration: configuration, delegate: relay, delegateQueue: .main)
  }

  /// Called when the owning WebView is replaced; a URLSession retains its delegate until invalidated.
  func invalidate() {
    pending.removeAll(); tasks.removeAll()
    session?.invalidateAndCancel(); session = nil
  }

  /// Drops every connection after a suspension. One that crossed a tunnel
  /// restart can stall for its whole timeout while a new one answers at once,
  /// so the page's requests fail now and its reads go again on fresh sockets.
  func reconnect() {
    guard session != nil else { return }
    let stale = Array(pending.values)
    pending.removeAll(); tasks.removeAll()
    session?.invalidateAndCancel()
    session = makeSession()
    for task in stale { task.didFailWithError(URLError(.networkConnectionLost)) }
  }

  func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
    let request = urlSchemeTask.request
    guard let url = request.url, let target = forward(url), let session else {
      respond(urlSchemeTask, status: 404); return
    }
    if request.httpMethod == "OPTIONS" {
      respond(urlSchemeTask, status: 204, headers: [
        "Access-Control-Allow-Methods": "GET, HEAD, POST, PUT, DELETE, OPTIONS",
        "Access-Control-Allow-Headers": request.value(forHTTPHeaderField: "Access-Control-Request-Headers") ?? "*",
        "Access-Control-Max-Age": "600",
      ])
      return
    }
    var outbound = URLRequest(url: target)
    outbound.httpMethod = request.httpMethod ?? "GET"
    for (name, value) in request.allHTTPHeaderFields ?? [:] where !Self.requestHeadersDropped.contains(name.lowercased()) {
      outbound.setValue(value, forHTTPHeaderField: name)
    }
    outbound.setValue("Bearer \(invite.token)", forHTTPHeaderField: "Authorization")
    outbound.httpBody = request.httpBody ?? request.httpBodyStream.map(Self.drain)
    let task = session.dataTask(with: outbound)
    pending[task.taskIdentifier] = urlSchemeTask
    tasks[ObjectIdentifier(urlSchemeTask as AnyObject)] = task
    task.resume()
  }

  func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
    guard let task = tasks.removeValue(forKey: ObjectIdentifier(urlSchemeTask as AnyObject)) else { return }
    pending.removeValue(forKey: task.taskIdentifier)
    task.cancel()
  }

  /// Only the Streams API is forwarded; the page itself is loaded from the bundle.
  private func forward(_ url: URL) -> URL? {
    let origin = Self.origin(invite)
    let address = url.absoluteString
    guard address.lowercased().hasPrefix(origin + "/ds/") else { return nil }
    return URL(string: invite.url + address.dropFirst(origin.count))
  }

  private func respond(_ task: any WKURLSchemeTask, status: Int, headers: [String: String] = [:]) {
    guard let url = task.request.url,
          let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: Self.cors.merging(headers) { _, new in new }) else {
      task.didFailWithError(URLError(.badURL)); return
    }
    task.didReceive(response)
    task.didFinish()
  }

  /// Task identifiers restart with each session, so a replaced session's late callbacks are ignored.
  fileprivate func received(_ response: URLResponse, for task: URLSessionTask, in session: URLSession) -> Bool {
    guard session === self.session,
          let schemeTask = pending[task.taskIdentifier], let url = schemeTask.request.url else { return false }
    let upstream = response as? HTTPURLResponse
    var headers = Self.cors
    for (key, value) in upstream?.allHeaderFields ?? [:] {
      guard let name = key as? String, let text = value as? String,
            !Self.responseHeadersDropped.contains(name.lowercased()) else { continue }
      headers[name] = text
    }
    let forwarded = HTTPURLResponse(url: url, statusCode: upstream?.statusCode ?? 502,
      httpVersion: "HTTP/1.1", headerFields: headers)
    schemeTask.didReceive(forwarded ?? response)
    return true
  }

  fileprivate func received(_ data: Data, for task: URLSessionTask, in session: URLSession) {
    guard session === self.session else { return }
    pending[task.taskIdentifier]?.didReceive(data)
  }

  fileprivate func completed(_ task: URLSessionTask, error: (any Error)?, in session: URLSession) {
    guard session === self.session,
          let schemeTask = pending.removeValue(forKey: task.taskIdentifier) else { return }
    tasks.removeValue(forKey: ObjectIdentifier(schemeTask as AnyObject))
    if let error { schemeTask.didFailWithError(error) } else { schemeTask.didFinish() }
  }

  private static func drain(_ stream: InputStream) -> Data {
    stream.open(); defer { stream.close() }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    while true {
      let count = stream.read(&buffer, maxLength: buffer.count)
      if count <= 0 { break }
      data.append(buffer, count: count)
    }
    return data
  }
}

/// URLSession callbacks arrive on the main queue (`delegateQueue: .main`).
private final class Relay: NSObject, URLSessionDataDelegate, @unchecked Sendable {
  weak var owner: LanHubSchemeHandler?

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
    let accepted = MainActor.assumeIsolated { owner?.received(response, for: dataTask, in: session) ?? false }
    completionHandler(accepted ? .allow : .cancel)
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    MainActor.assumeIsolated { owner?.received(data, for: dataTask, in: session) }
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
    MainActor.assumeIsolated { owner?.completed(task, error: error, in: session) }
  }

  /// The hub never redirects; following one could carry the bearer elsewhere.
  func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
    completionHandler(nil)
  }
}
