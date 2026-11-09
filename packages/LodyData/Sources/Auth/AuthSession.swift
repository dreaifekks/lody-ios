import Foundation

public struct AuthSnapshot: Encodable, Sendable {
  public struct Code: Encodable, Sendable {
    public let user_code: String
    public let verification_uri_complete: String
    public let expires_in: Double
    public let interval: Double

    public init(user_code: String, verification_uri_complete: String, expires_in: Double, interval: Double) {
      self.user_code = user_code
      self.verification_uri_complete = verification_uri_complete
      self.expires_in = expires_in
      self.interval = interval
    }
  }

  public var account: AuthAccount?
  public var busy = true
  public var localReady = false
  public var initialWorkspace = ""
  public var catalogRevision = 0
  public var code: Code?
  public var error: String?

  public var json: String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .withoutEscapingSlashes
    return (try? encoder.encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
  }

  public init(account: AuthAccount? = nil, busy: Bool = true, localReady: Bool = false, initialWorkspace: String = "", catalogRevision: Int = 0, code: Code? = nil, error: String? = nil) {
    self.account = account
    self.busy = busy
    self.localReady = localReady
    self.initialWorkspace = initialWorkspace
    self.catalogRevision = catalogRevision
    self.code = code
    self.error = error
  }
}

public final class AuthPublished: @unchecked Sendable {
  private let lock = NSLock()
  private var state = AuthSnapshot().json

  public var json: String { lock.withLock { state } }

  fileprivate func set(_ json: String) -> Bool {
    lock.withLock {
      let changed = state != json
      state = json
      return changed
    }
  }
}

@MainActor
public final class AuthSession {
  public static let shared = AuthSession()
  public nonisolated static let published = AuthPublished()

  public private(set) var snapshot = AuthSnapshot()
  public var api = AuthAPI()
  public var stopRuntime: (() -> Void)?
  public var restartRuntime: (() -> Void)?
  public var isLAN: Bool { snapshot.account?.isLAN == true }
  public var probeLAN: @Sendable (LanInvite) async throws -> Void = { try await LanHub.probe($0) }

  private var account: AuthAccount?
  private var credential: String?
  private var busy = true
  private var localReady = false
  private var initialWorkspace = ""
  private var initialCatalog: String?
  private var catalogRevision = 0
  private var code: DeviceCode?
  private var error: String?
  private var current: Task<Void, Never>?
  private var attempt = 0
  private var started = false
  private var committing = false

  public var catalogScope: AuthCatalogScope {
    AuthCatalogScope(account: account, localReady: localReady, initialWorkspace: initialWorkspace, initialCatalog: initialCatalog)
  }

  public func start() {
    guard !started else { return }
    started = true
    Task { await restore() }
  }

  public func restore() async {
    await begin { id in await self.performRestore(id) }
  }

  public func login() async throws {
    guard !LodyUIVerify.enabled else {
      throw AuthFailure(message: "Login is disabled during offline UI verification")
    }
    await begin { id in await self.performLogin(id) }
  }

  /// Probes first; failed or cancelled joins preserve the current identity.
  public func joinLAN(_ inviteString: String) async throws {
    guard !LodyUIVerify.enabled else { throw AuthFailure(message: "Joining a LAN is disabled during offline UI verification") }
    try Task.checkCancellation()
    let invite = try LanInvite.parse(inviteString)
    var completed = false
    var failure: (any Error)?
    await begin { id in
      self.update(id) { self.busy = true; self.code = nil; self.error = nil }
      do {
        try await self.probeLAN(invite)
        guard self.active(id) else { throw CancellationError() }
        try await self.replaceIdentity(id, lan: invite, cloud: nil)
        completed = true
      } catch {
        failure = error
        self.update(id) { self.error = error.localizedDescription }
      }
      self.update(id) { self.busy = false; self.localReady = true }
    }
    if let failure { throw failure }
    guard completed else { throw CancellationError() }
  }

  public func cancel() {
    guard !committing else { return }
    current?.cancel()
    attempt += 1
    closeBrowser()
    busy = false
    code = nil
    publish()
  }

  public func logout() async {
    let token = credential
    await begin { id in await self.performLogout(id, token: token) }
  }

  /// Refreshes UI context after an authenticated handover without changing identity.
  func lanHubMoved(_ invite: LanInvite) {
    guard account?.lan?.id == invite.id else { return }
    account = .lanAccount(invite)
    publish()
    let generation = LocalStore.shared.generation
    let fresh = account!
    Task { await save(fresh, generation: generation) }
  }

  public func reopen() {
    guard let code else { return }
    do { try openBrowser(code.verificationURL) } catch {
      self.error = String(localized: "auth.error.openAuthorizePage", bundle: .lodyData)
      publish()
    }
  }

  public func updateWorkspace(id: String, name: String) async throws {
    guard let account, let credential else { throw AuthFailure(message: String(localized: "workspace.edit.signedOut", bundle: .lodyData)) }
    let generation = LocalStore.shared.generation
    let updated = try await api.updateWorkspace(token: credential, id: id, name: name)
    await persist(updated, account: account, credential: credential, generation: generation)
  }

  public func updateWorkspaceIcon(id: String, file: WorkspaceIconFile) async throws -> String {
    guard let account, let credential else { throw AuthFailure(message: String(localized: "workspace.edit.signedOut", bundle: .lodyData)) }
    let generation = LocalStore.shared.generation
    let image = try await api.uploadWorkspaceIcon(token: credential, id: id, file: file)
    let updated = try await api.updateWorkspaceIcon(token: credential, id: id, image: image)
    await persist(updated, account: account, credential: credential, generation: generation)
    return image
  }

  private func begin(_ work: @escaping @MainActor (Int) async -> Void) async {
    if committing { await current?.value }
    closeBrowser()
    let previous = current
    previous?.cancel()
    attempt += 1
    let id = attempt
    let task = Task {
      await previous?.value
      guard self.active(id) else { return }
      await work(id)
    }
    current = task
    await withTaskCancellationHandler { await task.value } onCancel: {
      Task { @MainActor [weak self] in
        guard let self, self.attempt == id else { return }
        self.cancel()
      }
    }
  }

  private func active(_ id: Int) -> Bool { id == attempt && !Task.isCancelled }

  private func update(_ id: Int, _ change: () -> Void) {
    guard active(id) else { return }
    change()
    publish()
  }

  private func setCatalog(_ raw: String?) {
    initialCatalog = raw
    catalogRevision += 1
  }

  private func performRestore(_ id: Int) async {
    if LodyUIVerify.enabled {
      update(id) { busy = false; localReady = true }
      return
    }
    update(id) { busy = true; error = nil }
    do {
      try await hydrateAndRefresh(id)
    } catch {
      if (error as? AuthFailure)?.expired == true, active(id) {
        update(id) { account = nil; credential = nil; initialWorkspace = ""; setCatalog(nil) }
        if !(await clearLocalAndCredentials()) { toast("auth.toast.clearLocalFailed") }
      }
      update(id) { self.error = error.localizedDescription }
    }
    update(id) { busy = false; localReady = true }
  }

  private func hydrateAndRefresh(_ id: Int) async throws {
    let started = ProcessInfo.processInfo.systemUptime
    let lan = try LanHub.read()
    let token = try AuthKeychain.read()
    let boot = (try? await Self.onStore { try $0.startup() }) ?? [:]
    guard active(id) else { return }
    if let lan {
      let fresh = AuthAccount.lanAccount(lan)
      let same = AuthAccount.userID(boot["account"]) == fresh.user.id
      if !same { try await clearLocal() }
      guard active(id) else { return }
      await save(fresh)
      update(id) {
        account = fresh; credential = nil; localReady = true
        initialWorkspace = same ? boot["workspace"] ?? lan.workspaceId : lan.workspaceId
        setCatalog(same ? boot["catalog"] : nil)
      }
      return
    }
    if let token, let saved = AuthAccount.decode(boot["account"]), !saved.isLAN {
      #if DEBUG
      NSLog("LodyLocal hydrate_ms=%.2f", (ProcessInfo.processInfo.systemUptime - started) * 1000)
      #endif
      update(id) {
        account = saved
        credential = token
        localReady = true
        initialWorkspace = boot["workspace"] ?? ""
        setCatalog(boot["catalog"])
      }
    } else {
      update(id) { localReady = true }
    }
    guard let token else {
      update(id) { account = nil; credential = nil }
      return
    }
    #if DEBUG
    // Match the native grant failure probe without changing product endpoints.
    if LodyUIVerify.offline { throw AuthFailure(message: "Network unavailable") }
    #endif
    let fresh = try await api.account(token: token)
    guard active(id) else { return }
    if let saved = AuthAccount.userID(boot["account"]), saved != fresh.user.id {
      try await clearLocal()
      update(id) { setCatalog(nil); initialWorkspace = "" }
    }
    await save(fresh)
    update(id) { account = fresh; credential = token }
  }

  private func performLogin(_ id: Int) async {
    update(id) { busy = true; code = nil; error = nil }
    do {
      let code = try await api.deviceCode()
      update(id) { self.code = code }
      guard active(id) else { throw AuthFailure(message: String(localized: "common.cancelled", bundle: .lodyData)) }
      try openBrowser(code.verificationURL)
      let token = try await api.pollToken(code)
      let fresh = try await api.account(token: token)
      guard active(id) else { throw AuthFailure(message: String(localized: "common.cancelled", bundle: .lodyData)) }
      try await replaceIdentity(id, lan: nil, cloud: (fresh, token))
    } catch {
      update(id) { self.error = error.localizedDescription; code = nil }
    }
    guard active(id) else { return }
    closeBrowser()
    update(id) { busy = false; localReady = true }
  }

  private func replaceIdentity(_ id: Int, lan: LanInvite?, cloud: (AuthAccount, String)?) async throws {
    guard active(id) else { throw CancellationError() }
    let oldLAN = try LanHub.read(), oldCloud = try AuthKeychain.read()
    committing = true
    var replaced = false
    defer {
      committing = false
      if !replaced { restartRuntime?() }
    }
    stopRuntime?()
    await LodyHosting.current?.forgetDevice()
    guard active(id) else { throw CancellationError() }
    try await clearLocal()
    guard active(id) else { throw CancellationError() }
    let fresh: AuthAccount
    do {
      if let lan {
        try LanHub.save(lan)
        try AuthKeychain.clear()
        fresh = .lanAccount(lan)
      } else if let cloud {
        try AuthKeychain.save(cloud.1)
        try LanHub.clear()
        fresh = cloud.0
      } else { throw CancellationError() }
    } catch {
      if let oldLAN { try? LanHub.save(oldLAN) } else { try? LanHub.clear() }
      if let oldCloud { try? AuthKeychain.save(oldCloud) } else { try? AuthKeychain.clear() }
      throw error
    }
    update(id) {
      account = fresh; credential = cloud?.1; code = nil
      initialWorkspace = lan?.workspaceId ?? ""; setCatalog(nil)
    }
    replaced = true
    await save(fresh)
  }

  private func performLogout(_ id: Int, token: String?) async {
    update(id) { busy = true; error = nil }
    update(id) { account = nil; credential = nil; code = nil; initialWorkspace = ""; setCatalog(nil) }
    do {
      guard await clearLocalAndCredentials() else { throw AuthFailure(message: String(localized: "auth.error.signOutIncomplete", bundle: .lodyData)) }
      if let token { try await api.signOut(token: token) }
    } catch {
      update(id) { self.error = String(localized: "auth.error.signOutIncomplete", bundle: .lodyData) }
    }
    update(id) { busy = false; localReady = true }
  }

  private func clearLocalAndCredentials() async -> Bool {
    var cleared = true
    do { try await clearLocal() } catch { cleared = false }
    do { try await clearCredentials() } catch { cleared = false }
    return cleared
  }

  private func clearLocal() async throws {
    // Stop producers before clearing their queued writes, including background Sessions.
    stopRuntime?()
    LodyHosting.current?.clearSharedData()
    try await Self.onStore { try $0.clear() }
  }

  private func clearCredentials() async throws {
    stopRuntime?()
    await LodyHosting.current?.forgetDevice()
    var failure: (any Error)?
    do { try AuthKeychain.clear() } catch { failure = error }
    do { try LanHub.clear() } catch { failure = failure ?? error }
    if let failure { throw failure }
  }

  private func save(_ account: AuthAccount, generation: Int? = nil) async {
    let json = account.json
    do { try await Self.onStore { try $0.write("account", json, generation: generation) } }
    catch { toast("auth.toast.accountSaveFailed") }
  }

  private func persist(_ updated: AuthWorkspace, account: AuthAccount, credential: String, generation: Int) async {
    let workspaces = account.workspaces.map { $0.id == updated.id ? updated : $0 }
    await save(AuthAccount(user: account.user, workspaces: workspaces, lan: account.lan), generation: generation)
    guard self.credential == credential, var current = self.account else { return }
    current.workspaces = workspaces
    self.account = current
    publish()
  }

  private func openBrowser(_ address: String) throws {
    guard let url = URL(string: address), url.scheme == "https", url.host == "lody.ai",
          url.user == nil, url.password == nil, LodyHosting.current?.presentAuthorization(url) == true else {
      throw NSError(domain: "LodyKit.AuthBrowser", code: 1)
    }
  }

  private func closeBrowser() {
    LodyHosting.current?.dismissAuthorization()
  }

  private func toast(_ key: String) {
    LodyHosting.current?.toast(String(localized: String.LocalizationValue(key), bundle: .lodyData), kind: "error")
  }

  private func publish() {
    snapshot = AuthSnapshot(
      account: account,
      busy: busy,
      localReady: localReady,
      initialWorkspace: initialWorkspace,
      catalogRevision: catalogRevision,
      code: code.map {
        AuthSnapshot.Code(user_code: $0.userCode, verification_uri_complete: $0.verificationURL,
                          expires_in: $0.expiresIn, interval: $0.interval)
      },
      error: error
    )
    guard Self.published.set(snapshot.json) else { return }
    NotificationCenter.default.post(name: .lodyAuthDidChange, object: nil)
  }

  private nonisolated static func onStore<T: Sendable>(_ body: @escaping @Sendable (LocalStore) throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
      LocalStore.queue.async { continuation.resume(with: Result { try body(LocalStore.shared) }) }
    }
  }
}

extension Notification.Name {
  public static let lodyLANHubDidMove = Notification.Name("LodyLANHubDidMove")
  public static let lodyAuthDidChange = Notification.Name("LodyAuthDidChange")
}
