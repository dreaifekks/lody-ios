import Foundation

@main struct Check {
  @MainActor static func main() throws {
    let invite = try LanInvite.parse("lody-lan://token@hub:8788")
    let origin = LanHubSchemeHandler.origin(invite)
    let target = LanHubSchemeHandler.forward(URL(string: origin + "/ds/lody/stream?live=sse")!, invite: invite)
    assert(target?.absoluteString == "http://hub:8788/ds/lody/stream?live=sse")
    let dsRoute = LanHubSchemeHandler.route(URL(string: origin + "/ds/lody/stream?live=sse")!, method: "POST", invite: invite)
    assert(dsRoute == .init(url: URL(string: "http://hub:8788/ds/lody/stream?live=sse")!, authorized: true))
    for method in ["GET", "HEAD", "OPTIONS", nil] {
      let clockRoute = LanHubSchemeHandler.route(URL(string: origin + "/api/time")!, method: method, invite: invite)
      assert(clockRoute == .init(url: URL(string: "http://hub:8788/api/time")!, authorized: false), "clock \(String(describing: method))")
    }
    let clockQuery = LanHubSchemeHandler.route(URL(string: origin + "/api/time?t=1")!, method: "GET", invite: invite)
    assert(clockQuery == .init(url: URL(string: "http://hub:8788/api/time?t=1")!, authorized: false))
    for method in ["POST", "PUT", "DELETE", "PATCH"] {
      assert(LanHubSchemeHandler.route(URL(string: origin + "/api/time")!, method: method, invite: invite) == nil, method)
    }
    for address in [origin + "/github/token", origin + "/api/time/extra", origin + "/api/time/../github/token",
                    origin + "/ds/../github/token", origin + "/ds/%2e%2e/github/token",
                    origin + "/ds/%2f../github/token", origin + ":80/ds/lody/x", "lody-hub://other/ds/lody/x",
                    "lody-hub://other/api/time", "lody-hub://user@\(invite.id)/ds/lody/x",
                    origin + "/ds/lody/x#fragment", origin + "/api/time#fragment"] {
      assert(LanHubSchemeHandler.forward(URL(string: address)!, invite: invite) == nil, address)
    }
    print("PASS: owned Streams origin, unauthenticated /api/time passthrough, path traversal and foreign-origin rejection")
  }
}
