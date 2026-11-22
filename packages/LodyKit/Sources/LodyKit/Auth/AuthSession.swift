import Foundation
import UIKit

struct AuthSnapshot: Encodable, Sendable {
  var account: AuthAccount?
  var busy = true
  var localReady = false
  var initialWorkspace = ""
  var catalogRevision = 0
  var error: String?
  /// An email sign-up or resend sent a verification link; nothing was installed.
  var verificationSent = false

  var json: String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .withoutEscapingSlashes
    return (try? encoder.encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
  }
}

final class AuthPublished: @unchecked Sendable {
  private let lock = NSLock()
  private var state = AuthSnapshot().json

  var json: String { lock.withLock { state } }

  fileprivate func set(_ json: String) -> Bool {
    lock.withLock {
      let changed = state != json
      state = json
      return changed
    }
  }
}

@MainActor
final class AuthSession {
  static let shared = AuthSession()
  nonisolated static let published = AuthPublished()

  private(set) var snapshot = AuthSnapshot()
  var api = AuthAPI()
  var presenter: (() -> UIViewController?)?
  var stopRuntime: (() -> Void)?
  var restartRuntime: (() -> Void)?
  var isLAN: Bool { snapshot.account?.isLAN == true }
  var probeLAN: @Sendable (LanInvite) async throws -> Void = { try await LanHub.probe($0) }

  private var account: AuthAccount?
  private var credential: String?
  private var busy = true
  private var localReady = false
  private var initialWorkspace = ""
  private var initialCatalog: String?
  private var catalogRevision = 0
  private var error: String?
  private var verificationSent = false
  private var current: Task<Void, Never>?
  private var attempt = 0
  private var modeRefresh: Task<Void, Never>?
  private var started = false
  private var committing = false
  private let providers = NativeAuthProviders()

  var catalogScope: AuthCatalogScope {
    AuthCatalogScope(account: account, localReady: localReady, initialWorkspace: initialWorkspace, initialCatalog: initialCatalog)
  }

  func start() {
    guard !started else { return }
    started = true
    Task { await restore() }
  }

  func restore() async {
    await begin { id in await self.performRestore(id) }
  }

  func login(_ method: NativeLoginMethod) async {
    guard !LodyUIVerify.enabled else { return }
    await begin { id in await self.performLogin(id, method: method) }
  }

  /// Probes first; failed or cancelled joins preserve the current identity.
  func joinLAN(_ inviteString: String) async throws {
    guard !LodyUIVerify.enabled else { throw AuthFailure(message: "Joining a LAN is disabled during offline UI verification") }
    try Task.checkCancellation()
    let invite = try LanInvite.parse(inviteString)
    var completed = false
    var failure: (any Error)?
    await begin { id in
      self.update(id) { self.busy = true; self.error = nil; self.verificationSent = false }
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

  func cancel() {
    guard !committing else { return }
    modeRefresh?.cancel(); modeRefresh = nil
    current?.cancel()
    attempt += 1
    providers.cancel()
    busy = false
    publish()
  }

  func refreshWorkspaceModes() async {
    if let modeRefresh { await modeRefresh.value; return }
    guard let account, let credential else { return }
    let identity = attempt, generation = LocalStore.shared.generation
    let task = Task { [self] in
      guard let rows = try? await api.workspaceModes(token: credential, workspaces: account.workspaces),
        active(identity), self.credential == credential, var current = self.account, current.user.id == account.user.id else { return }
      let modes = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
      current.workspaces = current.workspaces.map { row in
        guard let mode = modes[row.id] else { return row }
        var next = row; next.contentMode = mode.contentMode; next.genesisHash = mode.genesisHash
        return next
      }
      self.account = current
      publish()
      await save(current, generation: generation)
    }
    modeRefresh = task
    await task.value
    if attempt == identity { modeRefresh = nil }
  }

  func logout() async {
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

  func updateWorkspace(id: String, name: String) async throws {
    guard let account, let credential else { throw AuthFailure(message: String(localized: "workspace.edit.signedOut", bundle: .lody)) }
    let generation = LocalStore.shared.generation
    let updated = try await api.updateWorkspace(token: credential, id: id, name: name)
    await persist(updated, account: account, credential: credential, generation: generation)
  }

  func updateWorkspaceIcon(id: String, file: WorkspaceIconFile) async throws -> String {
    guard let account, let credential else { throw AuthFailure(message: String(localized: "workspace.edit.signedOut", bundle: .lody)) }
    let generation = LocalStore.shared.generation
    let image = try await api.uploadWorkspaceIcon(token: credential, id: id, file: file)
    let updated = try await api.updateWorkspaceIcon(token: credential, id: id, image: image)
    await persist(updated, account: account, credential: credential, generation: generation)
    return image
  }

  private func begin(_ work: @escaping @MainActor (Int) async -> Void) async {
    if committing { await current?.value }
    modeRefresh?.cancel(); modeRefresh = nil
    let previous = current
    previous?.cancel()
    providers.cancel()
    attempt += 1
    let id = attempt
    let task = Task {
      // Drain prior local persistence before admitting a replacement account.
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

  private func performLogin(_ id: Int, method: NativeLoginMethod) async {
    update(id) { busy = true; error = nil; verificationSent = false }
    do {
      let token: String
      switch method {
      case let .email(email, password): token = try await api.email(email: email, password: password)
      case let .register(name, email, password):
        guard let registered = try await api.register(name: name, email: email, password: password) else {
          update(id) { busy = false; localReady = true; verificationSent = true }
          return
        }
        token = registered
      case let .resendVerification(email):
        try await api.resendVerification(email: email)
        update(id) { busy = false; localReady = true; verificationSent = true }
        return
      case .apple, .google, .github, .discord:
        guard let controller = presenter?() else { throw CancellationError() }
        token = try await providers.signIn(method, presenting: controller, api: api)
      }
      guard active(id) else { return }
      let fresh = try await api.account(token: token)
      guard active(id) else { return }
      try await replaceIdentity(id, lan: nil, cloud: (fresh, token))
      NativeLastLoginMethod(method)?.write()
    } catch is CancellationError {
      // Cancellation is not an authentication error.
    } catch {
      update(id) { self.error = error.localizedDescription }
    }
    update(id) { busy = false; localReady = true }
  }

  private func replaceIdentity(_ id: Int, lan: LanInvite?, cloud: (AuthAccount, String)?) async throws {
    guard active(id) else { throw CancellationError() }
    let oldLAN = try LanHub.read(), oldCloud = try AuthKeychain.read()
    let fresh: AuthAccount
    if let lan { fresh = .lanAccount(lan) }
    else if let cloud { fresh = cloud.0 }
    else { throw CancellationError() }
    var replaced = false
    defer {
      committing = false
      if !replaced { restartRuntime?() }
    }
    stopRuntime?()
    await PushNotifications.shared.forgetDevice()
    guard active(id) else { throw CancellationError() }
    try await clearLocal()
    // clearLocal and save suspend: cancellation must be rechecked BEFORE Keychain writes.
    guard active(id) else { throw CancellationError() }
    await save(fresh)
    guard active(id) else { throw CancellationError() }
    committing = true
    do {
      if let lan {
        try LanHub.save(lan)
        try AuthKeychain.clear()
      } else if let cloud {
        try AuthKeychain.save(cloud.1)
        try LanHub.clear()
      } else { throw CancellationError() }
    } catch {
      if let oldLAN { try? LanHub.save(oldLAN) } else { try? LanHub.clear() }
      if let oldCloud { try? AuthKeychain.save(oldCloud) } else { try? AuthKeychain.clear() }
      throw error
    }
    update(id) {
      account = fresh; credential = cloud?.1; verificationSent = false
      initialWorkspace = lan?.workspaceId ?? ""; setCatalog(nil)
    }
    replaced = true
  }

  private func performLogout(_ id: Int, token: String?) async {
    update(id) { busy = true; error = nil }
    update(id) { account = nil; credential = nil; initialWorkspace = ""; setCatalog(nil) }
    do {
      guard await clearLocalAndCredentials() else { throw AuthFailure(message: String(localized: "auth.error.signOutIncomplete", bundle: .lody)) }
      if let token { try await api.signOut(token: token) }
    } catch {
      update(id) { self.error = String(localized: "auth.error.signOutIncomplete", bundle: .lody) }
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
    ShareStore.clear()
    try await Self.onStore { try $0.clear() }
  }

  private func clearCredentials() async throws {
    stopRuntime?()
    await PushNotifications.shared.forgetDevice()
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

  private func toast(_ key: String) {
    LodyToastOverlay.shared.show(message: String(localized: String.LocalizationValue(key), bundle: .lody), kind: .error)
  }

  private func publish() {
    if localReady && (!busy || account == nil) {
      PushNotifications.shared.identify(account?.user.id, credential: credential)
    }
    snapshot = AuthSnapshot(
      account: account,
      busy: busy,
      localReady: localReady,
      initialWorkspace: initialWorkspace,
      catalogRevision: catalogRevision,
      error: error,
      verificationSent: verificationSent
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
  static let lodyLANHubDidMove = Notification.Name("LodyLANHubDidMove")
  static let lodyAuthDidChange = Notification.Name("LodyAuthDidChange")
}
