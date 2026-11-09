import Foundation

@MainActor
final class Host: LodyHost {
  var isActive = true
  var isBackground = false
  var sawCredentialWhileForgetting = false
  func open(_ url: URL) async -> Bool { true }
  func copyLink(_ url: URL) {}
  func beginSendAllowance(expired: @escaping @MainActor () -> Void) -> AnyObject? { nil }
  func endSendAllowance(_ token: AnyObject) {}
  func toast(_ message: String, kind: String) {}
  func alert(title: String, message: String) {}
  func presentAuthorization(_ url: URL) -> Bool { true }
  func dismissAuthorization() {}
  func catalogDidUpdate(_ catalogJSON: String, workspaceId: String, workspaceSlug: String, workspaceName: String, userId: String) {}
  func clearSharedData() {}
  func forgetDevice() async {
    sawCredentialWhileForgetting = (try? LanHub.current()) != nil || (try? AuthKeychain.read()) != nil
    await Task.yield()
  }
}
actor Probe {
  private var waiting: CheckedContinuation<Void, Never>?
  var ready: Bool { waiting != nil }
  func wait() async { await withCheckedContinuation { waiting = $0 } }
  func finish() { waiting?.resume(); waiting = nil }
}

func check(_ condition: @autoclosure () throws -> Bool) throws { let value = try condition(); assert(value) }

@main struct Check {
  @MainActor static func main() async throws {
    let host = Host(); LodyHosting.current = host
    let auth = AuthSession()
    auth.api.transport = { request in
      let path = request.url!.path
      let text: String
      switch path {
      case "/api/auth/get-session": text = #"{"user":{"id":"cloud-user","email":"c@example.com","name":"Cloud"}}"#
      case "/api/auth/organization/list": text = #"[{"id":"cloud-workspace","name":"Cloud","slug":"cloud"}]"#
      case "/api/auth/device/code": text = #"{"device_code":"device","user_code":"code","verification_uri_complete":"https://lody.ai/device","expires_in":60,"interval":1}"#
      case "/api/auth/device/token": text = #"{"access_token":"new-cloud-token"}"#
      case "/api/auth/sign-out": text = "{}"
      default: fatalError("unexpected network path: \(path)")
      }
      return (Data(text.utf8), 200)
    }
    auth.api.sleep = { _ in }
    try AuthKeychain.save("cloud-token")
    await auth.restore()
    try check(auth.snapshot.account?.user.id == "cloud-user")

    let probe = Probe()
    auth.probeLAN = { _ in await probe.wait() }
    let cancelled = Task { try await auth.joinLAN("lody-lan://cancelled-token@hub:8788") }
    while !(await probe.ready) { await Task.yield() }
    auth.cancel()
    await probe.finish()
    do { try await cancelled.value; fatalError("cancelled join succeeded") } catch {}
    try check(auth.snapshot.account?.user.id == "cloud-user")
    try check((try AuthKeychain.read()) == "cloud-token")
    try check(try LanHub.current() == nil)

    auth.probeLAN = { _ in }
    var restarts = 0
    auth.restartRuntime = { restarts += 1 }
    LocalStore.failClear = true
    do { try await auth.joinLAN("lody-lan://rejected-commit@hub:8788"); fatalError("storage failure joined LAN") } catch {}
    LocalStore.failClear = false
    try check(restarts == 1)
    AuthKeychain.failNextSave(account: AuthKeychain.lanHub)
    do { try await auth.joinLAN("lody-lan://rejected-keychain@hub:8788"); fatalError("Keychain failure joined LAN") } catch {}
    try check(restarts == 2)
    try check(auth.snapshot.account?.user.id == "cloud-user")
    try check((try AuthKeychain.read()) == "cloud-token")
    try check(try LanHub.current() == nil)
    try await auth.joinLAN("lody-lan://joined-test-token@hub:8788/Home")
    let account = auth.snapshot.account!
    try check(account.isLAN && account.lan?.name == "Home")
    try check(try AuthKeychain.read() == nil)
    try check(!(try LocalStore.shared.startup())["account"]!.contains("joined-test-token"))
    let invite = try LanHub.current()!
    try LocalStore.shared.write("workspace", invite.workspaceId)
    try LocalStore.shared.write("catalog", "saved-catalog")

    let savedAPI = auth.api
    auth.api.transport = { _ in throw AuthFailure(message: "offline") }
    try await auth.login() // Existing API reports device-flow failures in snapshot.error.
    try check(auth.snapshot.account == account && auth.snapshot.error != nil)
    await auth.restore() // LAN restoration does not contact Cloud or probe the hub.
    try check(auth.snapshot.initialWorkspace == invite.workspaceId)
    try check(auth.catalogScope.initialCatalog == "saved-catalog")
    try check(auth.snapshot.account?.lan?.id == invite.id)

    auth.api = savedAPI
    try await auth.login()
    try check(auth.snapshot.account?.isLAN == false)
    try check(try LanHub.current() == nil)
    try check(try AuthKeychain.read() == "new-cloud-token")
    try check(auth.snapshot.initialWorkspace.isEmpty && auth.catalogScope.initialCatalog == nil)
    try check(host.sawCredentialWhileForgetting)

    try await auth.joinLAN("lody-lan://joined-test-token@hub:8788/Home")
    host.sawCredentialWhileForgetting = false
    await auth.logout()
    try check(host.sawCredentialWhileForgetting)
    try check(auth.snapshot.account == nil && (try LanHub.current()) == nil)
    try check(try AuthKeychain.read() == nil)
    print("PASS: cancelled join, Cloud/LAN replacement, failed login preservation, LAN restore context, async logout ordering")
  }
}
