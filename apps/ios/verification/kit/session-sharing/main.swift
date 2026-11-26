import Foundation
import os

enum AuthKeychain { static func read() throws -> String? { "synthetic-app-credential" } }
enum SessionAttachments {
  static func imageDownloadURL(workspace: String, session: String, imageId: String) -> URL {
    URL(string: "https://api.lody.ai/api/workspaces/\(workspace)/session-images/\(session)/\(imageId)")!
  }
}
final class ShareProtocol: URLProtocol {
  static let calls = OSAllocatedUnfairLock(initialState: [String]())
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    let host = request.url!.host!
    Self.calls.withLock { $0.append(host) }
    var body: [String: Any]
    var status = 200
    let token = request.value(forHTTPHeaderField: "Authorization")
    if host == "backend.lody.ai" && request.url!.path == "/api/session-history/roost-read-grant" {
      precondition(token == "Bearer synthetic-app-credential")
      status = 404
      body = ["error": "No matching routes found"]
    } else if host == "backend.lody.ai" {
      precondition(token == "Bearer synthetic-app-credential")
      body = ["token": "synthetic-jwt"]
    } else {
      precondition(host == "convex.lody.ai" && token == "Bearer synthetic-jwt")
      var data = request.httpBody ?? Data()
      if let stream = request.httpBodyStream {
        stream.open(); defer { stream.close() }
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
          let count = stream.read(&buffer, maxLength: buffer.count)
          if count <= 0 { break }
          data.append(contentsOf: buffer.prefix(count))
        }
      }
      let payload = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
      let path = payload["path"] as! String
      precondition(["sessionSharing:getManagement", "sessionSharing:revoke"].contains(path))
      precondition(request.url!.path == (path.hasSuffix("revoke") ? "/api/mutation" : "/api/query"))
      body = ["status": "success", "value": NSNull()]
      if path.hasSuffix("revoke") { body = ["status": "error", "errorMessage": "forbidden"] }
    }
    client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: body))
    client?.urlProtocolDidFinishLoading(self)
  }
  override func stopLoading() {}
}
@main @MainActor struct Check {
  static func main() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [ShareProtocol.self]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    let result = try await SessionSharing.run("api", args: ["method": "getManagement", "args": ["workspaceId": "workspace", "rootSessionId": "root"]], workspace: "workspace", userId: "user", session: session)
    precondition(result is NSNull, "A missing share is not an active link")
    let before = ShareProtocol.calls.withLock { $0.count }
    do {
      _ = try await SessionSharing.run("api", args: ["method": "getManagement", "args": ["workspaceId": "other", "rootSessionId": "root"]], workspace: "workspace", userId: "user", session: session)
      fatalError("Cross-workspace request accepted")
    } catch {}
    do {
      _ = try await SessionSharing.run("api", args: ["method": "anything", "args": [:]], workspace: "workspace", userId: "user", session: session)
      fatalError("Arbitrary backend mutation accepted")
    } catch {}
    // The published-share inventory was removed from mobile; its broker operation no longer exists.
    do {
      _ = try await SessionSharing.run("management", args: ["workspaceId": "workspace", "action": "list"], workspace: "workspace", userId: "user", session: session)
      fatalError("Removed share inventory operation accepted")
    } catch {}
    precondition(ShareProtocol.calls.withLock { $0.count } == before)
    do {
      _ = try await SessionSharing.run("api", args: ["method": "revoke", "args": ["shareId": "share", "expectedRevision": 1]], workspace: "workspace", userId: "user", session: session)
      fatalError("Rejected mutation reported success")
    } catch { precondition(error.localizedDescription == "share_unavailable") }
    precondition(ShareProtocol.calls.withLock { $0.count } == before + 2, "Never replay a mutation")
    // A Roost history read grant may name only a published stream of this workspace on its gateway.
    let key = String(repeating: "A", count: 43)
    func grant(_ url: String, owner: String = key) -> [String: Any] {
      ["state": "published", "binding": ["generation": "root", "ownerPublicKey": owner], "streamUrl": url, "token": "t", "expiresIn": 60]
    }
    let gateway = "https://streams.lody.ai"
    let published = "\(gateway)/ds/lody-rh/workspace%3Arh%3Am%3As%3A\(key)%3Aroot"
    precondition(SessionSharing.validCloudHistoryGrant(grant(published), workspace: "workspace", gatewayOrigin: gateway))
    for waiting in ["pending", "owner-required"] {
      precondition(SessionSharing.validCloudHistoryGrant(["state": waiting], workspace: "workspace", gatewayOrigin: gateway))
      precondition(!SessionSharing.validCloudHistoryGrant(["state": waiting, "token": "t"], workspace: "workspace", gatewayOrigin: gateway))
    }
    for rejected in [
      grant(published.replacingOccurrences(of: gateway, with: "https://evil.example")),
      grant(published.replacingOccurrences(of: "/lody-rh/", with: "/lody/")),
      grant(published.replacingOccurrences(of: "/workspace%3A", with: "/other%3A")),
      grant(published + "?x=1"),
      grant(published, owner: String(repeating: "B", count: 43)),
    ] {
      precondition(!SessionSharing.validCloudHistoryGrant(rejected, workspace: "workspace", gatewayOrigin: gateway))
    }
    // A backend without the cloud read-grant route keeps the owner read path.
    let missingRoute = try await SessionSharing.run("historyToken", args: ["intent": ["workspaceId": "workspace", "machineId": "m", "sessionId": "s", "cloudHistory": true]], workspace: "workspace", userId: "user", gatewayOrigin: gateway, session: session)
    precondition((missingRoute as? [String: Any])?["state"] as? String == "owner-required", "A missing read-grant route must fall back to the owner")
    print("Sharing native boundary passed: scoped operations, native-only credentials, null state, rejected mutation and no replay")
  }
}
