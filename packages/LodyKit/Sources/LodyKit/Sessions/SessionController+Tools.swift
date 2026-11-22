import LodyCore
import UIKit

extension SessionController {
  var isLANSession: Bool { LanInvite.isWorkspace(source.state.workspaceId) }

  /// Availability of a platform on the session's computer: iOS may be `upgrade-required`.
  func deviceAvailability(_ platform: DevicePlatform, _ catalog: SessionCatalog, _ session: SessionItem) -> String? {
    switch platform {
    case .ios: catalog.simulatorAvailability(for: session, lan: isLANSession)
    case .android: isLANSession ? nil : catalog.machineEmulators[session.machineId]
    }
  }

  private func previewSessionKey(_ state: SessionListState) -> SessionPreviewCache.SessionKey {
    SessionPreviewCache.SessionKey(workspaceId: state.workspaceId, userId: state.userId, sessionId: sessionId)
  }

  private func supportsPreviewStopProcess(_ state: SessionListState) -> Bool {
    guard let session = state.catalog.session(sessionId) else { return false }
    return state.catalog.supportsPreviewStopProcess(machineId: session.machineId)
  }

  func prepareSimulator(_ state: SessionListState, _ session: SessionItem) {
    previewCache.clearOutside(workspaceId: state.workspaceId, userId: state.userId)
    let sessionKey = previewSessionKey(state)
    var restored = false
    for platform in DevicePlatform.allCases {
      guard deviceAvailability(platform, state.catalog, session) != nil else {
        if let old = devicePreviews.removeValue(forKey: platform) {
          if !previewCache.isDeviceCached(old) { old.finish() }
          restored = true
        }
        continue
      }
      let capability = platform == .android ? "androidEmulatorShutdown" : "iosSimulatorShutdown"
      let canShutdown = (state.catalog.machineCapabilities[session.machineId]?[capability] ?? 0) >= 1
      if let existing = devicePreviews[platform] {
        existing.canShutdownDevice = canShutdown
        continue
      }
      let key = SessionPreviewCache.DeviceKey(session: sessionKey, platform: platform)
      let store = previewCache.device(for: key) {
        SessionSimulator(sessionId: sessionId, service: deviceServices[platform]
          ?? .live(platform, workspaceId: state.workspaceId, userId: state.userId, sessionId: sessionId, target: { [source, sessionId] in
            let state = source.state
            guard platform == .ios, let session = state.catalog.session(sessionId),
              state.catalog.simulatorAvailability(for: session, lan: true) == "available",
              let endpoint = state.catalog.machineTerminals[session.machineId] else { return nil }
            return (endpoint, session.machineId)
          }))
      }
      store.canShutdownDevice = canShutdown
      devicePreviews[platform] = store
      if store.previewJSON.isEmpty == false { restored = true }
      store.watch(self) { [weak self, weak store] in
        guard let self, let store, self.devicePreviews[platform] === store else { return }
        updateFloatingPreview()
        renderComposer()
        render()
      }
    }
    if let cachedBrowser = previewCache.browser(for: sessionKey) {
      cachedBrowser.controller.canStopProcess = supportsPreviewStopProcess(state)
    }
    if restored { updateFloatingPreview() }
  }

  /// LAN sessions keep manual simulator access in the overflow menu alongside agent-started previews.
  func simulatorMenu() -> [UIMenuElement] {
    guard isLANSession, let session = source.state.catalog.session(sessionId),
      let availability = deviceAvailability(.ios, source.state.catalog, session) else { return [] }
    let action = UIAction(title: String(localized: "simulator.menu", bundle: .lody), image: UIImage(systemName: "iphone")) { [weak self] _ in
      self?.openSimulator(.ios)
    }
    if availability == "upgrade-required" { action.subtitle = String(localized: "simulator.upgradeRequired", bundle: .lody) }
    else if let simulator = devicePreviews[.ios], simulator.running { action.subtitle = simulator.phaseText + " · " + simulator.name }
    return [action]
  }

  /// One floating preview per conversation: the most recently opened live platform.
  private var floatingPlatform: DevicePlatform? {
    (devicePreviewOrder + DevicePlatform.allCases).first { devicePreviews[$0]?.previewJSON.isEmpty == false }
  }

  private func updateFloatingPreview() {
    chat.setSimulatorPreview(floatingPlatform.flatMap { devicePreviews[$0]?.previewJSON } ?? "")
  }

  private static func deviceKey(_ platform: DevicePlatform, _ suffix: String) -> String.LocalizationValue {
    String.LocalizationValue((platform == .android ? "emulator." : "simulator.") + suffix)
  }

  func openSimulator(_ platform: DevicePlatform) {
    guard !openingSimulator, let session = source.state.catalog.session(sessionId),
      let availability = deviceAvailability(platform, source.state.catalog, session),
      let simulator = devicePreviews[platform] else { return }
    if availability == "upgrade-required" {
      let alert = UIAlertController(title: String(localized: "simulator.menu", bundle: .lody), message: String(localized: "simulator.upgradeRequired", bundle: .lody), preferredStyle: .alert)
      alert.addAction(UIAlertAction(title: String(localized: "common.ok", bundle: .lody), style: .default)); present(alert, animated: true); return
    }
    let ownership = simulator.ownership
    let scope = source.state.key
    openingSimulator = true
    devicePreviewOrder.removeAll { $0 == platform }
    devicePreviewOrder.insert(platform, at: 0)
    Task { [weak self] in
      guard let self else { return }
      defer { openingSimulator = false }
      do {
        simulator.revealPreview()
        if simulator.connecting { showSimulator(platform); return }
        if simulator.running, simulator.service.canReuse() { showSimulator(platform); return }
        let resumed = try await simulator.resume()
        guard viewIfLoaded?.window != nil, source.state.key == scope, simulator.ownership == ownership else { return }
        if resumed { showSimulator(platform); return }
        let picker = SimulatorPickerController(store: simulator) { [weak self] device in
          guard let self, viewIfLoaded?.window != nil, source.state.key == scope,
                simulator.ownership == ownership else { return }
          simulator.start(device); showSimulator(platform)
        }
        LodyShell.shared.presentNative(picker, title: String(localized: Self.deviceKey(platform, "choose"), bundle: .lody), grabber: true)
      } catch {
        guard viewIfLoaded?.window != nil, source.state.key == scope, simulator.ownership == ownership else { return }
        toolError(error)
      }
    }
  }
  private func showSimulator(_ platform: DevicePlatform) {
    guard let simulator = devicePreviews[platform] else { return }
    LodyShell.shared.pushNative(SimulatorController(store: simulator), title: simulator.name, from: self)
  }
  private func toolError(_ error: Error) { LodyToastOverlay.shared.show(message: error.localizedDescription, kind: .error) }

  static func livePullRequest(_ reference: SessionPullRequest, _ state: SessionListState) -> PullRequestController {
    let scope = SettingsActor.live(["workspaceId": state.workspaceId, "userId": state.userId])
    let store = PullRequestStore(repository: reference.repository, number: reference.number, scope: scope,
      service: .live(workspaceId: state.workspaceId, repository: reference.repository, number: reference.number))
    return PullRequestController(store: store)
  }

  func openPullRequest(_ reference: SessionPullRequest) {
    // One tap on a transcript link can be delivered twice (as with file links); keep one
    // page per PR until it closes, while a different PR still opens normally.
    let key = "\(reference.repository.lowercased())#\(reference.number)"
    guard openPullRequests.insert(key).inserted else { return }
    let state = source.state
    let page = pullRequestPage(reference, state)
    page.investigate = { [weak self] text in
      guard let self, source.state.key == state.key else { throw OutboxError.scopeExpired }
      chat.composer.appendDraft(Self.json(["id": UUID().uuidString, "text": text]))
    }
    // A panel over the conversation (sheet with detents; the inspector on iPad), not a push.
    LodyShell.shared.presentDetail(page, title: "PR #\(reference.number)", from: self) { [weak self] in
      self?.openPullRequests.remove(key)
    }
  }

  /// A PR link in the conversation opens the native PR page when it belongs to the session's
  /// project (a multi-repository project's members included); others stay in the browser.
  func openPullRequestLink(_ link: ChatPullRequestLink) -> Bool {
    let catalog = source.state.catalog
    guard let session = catalog.session(sessionId) else { return false }
    let repositories = catalog.projects.first { $0.id == session.projectId }?.githubRepositories
      ?? (session.projectId.hasPrefix("github:") ? [String(session.projectId.dropFirst(7))] : [])
    guard let repository = repositories.first(where: { $0.caseInsensitiveCompare(link.repository) == .orderedSame }) else { return false }
    let known = session.pullRequests.last {
      $0.number == link.number && $0.repository.caseInsensitiveCompare(repository) == .orderedSame
    }
    openPullRequest(known ?? SessionPullRequest(repository: repository, number: link.number, status: "", ci: nil, url: link.url))
    return true
  }

  func updateDetails(_ json: String) { subagentPage?.update(json, generation: feed?.generation ?? 0) }

}

extension SessionController {
  /// Live resources as action bar icons: tap opens, the menu copies or stops.
  var browserItem: [String: Any]? {
    guard !isLANSession, AuthSession.shared.snapshot.account?.lan == nil, let preview = feed?.state.preview else { return nil }
    var actions: [[String: Any]] = [["id": "copy", "title": String(localized: "session.preview.copyLink", bundle: .lody), "symbol": "link"]]
    let cachedValid = previewCache.cachedBrowser(for: previewSessionKey(source.state))?.isValid() == true
    let canStopProcess = supportsPreviewStopProcess(source.state)
    if preview.active || cachedValid {
      actions.append([
        "id": "stop",
        "title": String(localized: canStopProcess ? "session.preview.disconnectRemoteOnly" : "session.preview.stop", bundle: .lody),
        "symbol": "stop.circle",
        "destructive": !canStopProcess,
      ])
      if canStopProcess {
        actions.append([
          "id": "stop-process",
          "title": String(localized: "session.preview.disconnectAndStopProcess", bundle: .lody),
          "symbol": "power",
          "destructive": true,
        ])
      }
    }
    return ["id": "browser", "symbol": "safari", "busy": browserBusy, "tap": true, "tint": "primary", "menuTitle": preview.label, "actions": actions,
      "accessibilityLabel": String.localizedStringWithFormat(String(localized: "session.preview.open", bundle: .lody), String(describing: preview.label))]
  }

  /// Action bar ids: `simulator` (iOS) and `emulator` (Android).
  static func deviceItemId(_ platform: DevicePlatform) -> String { platform == .android ? "emulator" : "simulator" }

  func deviceItem(_ platform: DevicePlatform) -> [String: Any]? {
    guard let session = source.state.catalog.session(sessionId),
      deviceAvailability(platform, source.state.catalog, session) == "available", let simulator = devicePreviews[platform] else { return nil }
    // The CLI records an agent start on the conversation that owns the device, so a Tab reads
    // its main conversation's request id.
    let owner = session.parentSessionId.flatMap { source.state.catalog.session($0) } ?? session
    let requested = platform == .android ? owner.androidEmulatorPreviewRequestId : owner.iosSimulatorPreviewRequestId
    guard requested != nil || simulator.running else { return nil }
    let name = simulator.running ? simulator.name : String(localized: Self.deviceKey(platform, "menu"), bundle: .lody)
    var item: [String: Any] = ["id": Self.deviceItemId(platform), "symbol": platform == .android ? DevicePlatform.androidSymbol : "iphone",
      "busy": simulator.connecting, "tap": true, "tint": "primary", "menuTitle": name,
      "accessibilityLabel": String.localizedStringWithFormat(String(localized: "simulator.chip.open", bundle: .lody), String(describing: name))]
    var actions: [[String: Any]] = []
    if simulator.running {
      actions.append([
        "id": "stop",
        "title": String(localized: "simulator.stop", bundle: .lody),
        "symbol": "stop.circle",
        "destructive": !simulator.canShutdownDevice,
      ])
      if simulator.canShutdownDevice {
        actions.append([
          "id": "stop-shutdown",
          "title": String(localized: Self.deviceKey(platform, "stopAndShutdown"), bundle: .lody),
          "symbol": "power",
          "destructive": true,
        ])
      }
    }
    item["actions"] = actions
    return item
  }

  func contextAction(_ action: String) {
    if action.hasPrefix("bar:") { infoBarAction(String(action.dropFirst(4))); return }
    // The floating device preview's own actions apply to the platform it shows.
    guard let platform = floatingPlatform ?? devicePreviewOrder.first else { return }
    if action == "expand" { openSimulator(platform); return }
    if action == "close" { devicePreviews[platform]?.hidePreview(); return }
    resourceAction(Self.deviceItemId(platform), action)
  }

  func resourceAction(_ resource: String, _ action: String) {
    if resource == "browser" { browserAction(action); return }
    let platform: DevicePlatform = resource == "emulator" ? .android : .ios
    if action == "stop" {
      Task { do { try await devicePreviews[platform]?.stop(shutdownDevice: false) } catch { toolError(error) } }
    } else if action == "stop-shutdown" {
      Task { do { try await devicePreviews[platform]?.stop(shutdownDevice: true) } catch { toolError(error) } }
    } else { openSimulator(platform) }
  }

  private func browserAction(_ action: String) {
    guard !isLANSession, AuthSession.shared.snapshot.account?.lan == nil else { return }
    let state = source.state
    let sessionKey = previewSessionKey(state)
    let isStop = action == "stop" || action == "stop-process"
    let stopProcess = action == "stop-process"

    if action == "copy", let cached = previewCache.browser(for: sessionKey), cached.isValid() {
      UIPasteboard.general.string = cached.url.absoluteString
      LodyToastOverlay.shared.show(message: String(localized: "session.preview.copied", bundle: .lody), kind: .neutral)
      return
    }

    if !isStop, action != "copy", let cached = previewCache.browser(for: sessionKey) {
      presentCachedBrowser(cached, state: state, sessionKey: sessionKey)
      if cached.isValid() {
        verifyCachedBrowserPreview(cached, state: state, sessionKey: sessionKey)
      } else {
        browserCheckTask?.cancel()
        browserCheckTask = nil
        cached.controller.linkStatus = .needsRegenerate
      }
      return
    }

    guard !browserBusy else { return }
    browserBusy = true; renderComposer()
    Task { [weak self] in
      guard let self else { return }
      defer { browserBusy = false; renderComposer() }
      do {
        if isStop {
          browserCheckTask?.cancel()
          browserCheckTask = nil
        }
        let command: RuntimeContract.SessionPreviewParamsAction = isStop ? .revoke : .create
        let reply = try await requestBrowserPreview(state, command, false, stopProcess)
        guard source.state.key == state.key else { throw OutboxError.scopeExpired }
        guard viewIfLoaded?.window != nil else { return }
        if let error = reply.error {
          let message = error == "unsupported" ? String(localized: "session.preview.unsupported", bundle: .lody) : reply.message ?? String(localized: "session.preview.generic", bundle: .lody)
          throw SettingsError(message)
        }
        if isStop {
          if let presented = previewCache.browser(for: sessionKey)?.controller, presented.viewIfLoaded?.window != nil {
            LodyShell.shared.close(from: presented)
          }
          previewCache.removeBrowser(for: sessionKey)
          let toastKey = stopProcess ? "session.preview.stoppedWithProcess" : "session.preview.stopped"
          LodyToastOverlay.shared.show(message: String(localized: String.LocalizationValue(toastKey), bundle: .lody), kind: .neutral)
          return
        }
        guard let url = SessionPreviewCache.validatedPreviewURL(reply.url) else {
          throw SettingsError(String(localized: "session.preview.generic", bundle: .lody))
        }
        let expiresAt = SessionPreviewCache.resolveExpiresAt(reply.expiresAt)
        let entry: SessionPreviewCache.BrowserEntry
        if let existing = previewCache.browser(for: sessionKey) {
          existing.url = url
          existing.expiresAt = expiresAt
          existing.controller.updateCachedURL(url)
          entry = existing
        } else {
          let controller = BrowserPreviewController(url: url)
          entry = previewCache.storeBrowser(url: url, expiresAt: expiresAt, controller: controller, for: sessionKey)
        }
        if action == "copy" {
          UIPasteboard.general.string = url.absoluteString
          LodyToastOverlay.shared.show(message: String(localized: "session.preview.copied", bundle: .lody), kind: .neutral)
        } else {
          entry.controller.linkStatus = .idle
          presentCachedBrowser(entry, state: state, sessionKey: sessionKey)
        }
      } catch {
        guard viewIfLoaded?.window != nil else { return }
        presentBrowserError(error)
      }
    }
  }

  private func presentCachedBrowser(_ entry: SessionPreviewCache.BrowserEntry, state: SessionListState, sessionKey: SessionPreviewCache.SessionKey) {
    let controller = entry.controller
    controller.canStopProcess = supportsPreviewStopProcess(state)
    controller.onRegenerate = { [weak self] in
      self?.regenerateBrowserPreview(state: state, sessionKey: sessionKey)
    }
    controller.onDisconnect = { [weak self] stopProcess in
      self?.browserAction(stopProcess ? "stop-process" : "stop")
    }
    if controller.viewIfLoaded?.window != nil { return }
    controller.detachFromParentIfNeeded()
    // Embedded beside the conversation on iPad (inspector column), a sheet on compact widths.
    LodyShell.shared.presentDetail(controller, title: String(localized: "session.preview.title", bundle: .lody), from: self)
  }

  private func verifyCachedBrowserPreview(_ entry: SessionPreviewCache.BrowserEntry, state: SessionListState, sessionKey: SessionPreviewCache.SessionKey) {
    browserCheckTask?.cancel()
    entry.controller.linkStatus = .checking
    browserCheckTask = Task { [weak self] in
      guard let self else { return }
      do {
        let reply = try await requestBrowserPreview(state, .status, false, false)
        guard !Task.isCancelled, source.state.key == state.key else { return }
        guard previewCache.browser(for: sessionKey) === entry else { return }
        if reply.active == true {
          let expiresAt = SessionPreviewCache.resolveExpiresAt(reply.expiresAt)
          if let refreshed = SessionPreviewCache.validatedPreviewURL(reply.url) {
            previewCache.updateBrowser(for: sessionKey, url: refreshed, expiresAt: expiresAt)
            entry.controller.updateCachedURL(refreshed)
          } else {
            entry.expiresAt = expiresAt
          }
          entry.controller.linkStatus = .idle
        } else if reply.active == false {
          entry.controller.linkStatus = .needsRegenerate
        } else {
          entry.controller.linkStatus = .unconfirmed
        }
      } catch {
        guard !Task.isCancelled, previewCache.browser(for: sessionKey) === entry else { return }
        entry.controller.linkStatus = .unconfirmed
      }
    }
  }

  private func regenerateBrowserPreview(state: SessionListState, sessionKey: SessionPreviewCache.SessionKey) {
    guard !browserBusy, let entry = previewCache.browser(for: sessionKey) else { return }
    browserCheckTask?.cancel()
    browserCheckTask = nil
    browserBusy = true; renderComposer()
    let previousPage = entry.controller.currentPageURL
    entry.controller.linkStatus = .regenerating
    Task { [weak self] in
      guard let self else { return }
      defer { browserBusy = false; renderComposer() }
      do {
        let reply = try await requestBrowserPreview(state, .create, true, false)
        guard source.state.key == state.key else { throw OutboxError.scopeExpired }
        if let error = reply.error {
          let message = error == "unsupported" ? String(localized: "session.preview.unsupported", bundle: .lody) : reply.message ?? String(localized: "session.preview.generic", bundle: .lody)
          throw SettingsError(message)
        }
        guard let freshBase = SessionPreviewCache.validatedPreviewURL(reply.url) else {
          throw SettingsError(String(localized: "session.preview.generic", bundle: .lody))
        }
        let targetURL = SessionPreviewCache.mergedPreviewURL(newBase: freshBase, previousPage: previousPage)
        let expiresAt = SessionPreviewCache.resolveExpiresAt(reply.expiresAt)
        previewCache.updateBrowser(for: sessionKey, url: freshBase, expiresAt: expiresAt)
        entry.controller.loadRegeneratedURL(targetURL)
      } catch {
        entry.controller.linkStatus = .needsRegenerate
        if viewIfLoaded?.window != nil { presentBrowserError(error) }
        else { LodyToastOverlay.shared.show(message: error.localizedDescription, kind: .error) }
      }
    }
  }

  private func presentBrowserError(_ error: Error) {
    let alert = UIAlertController(title: String(localized: "session.preview.failed", bundle: .lody), message: String(describing: error), preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: String(localized: "common.ok", bundle: .lody), style: .default))
    present(alert, animated: true)
  }
}

extension SessionController {
  /// Main session inserts these elements in the existing overflow menu.
  func terminalMenu(account: AuthAccount? = AuthSession.shared.snapshot.account) -> [UIMenuElement] {
    let state = source.state
    guard let session = state.catalog.session(sessionId), !session.archived,
          state.catalog.machineTerminals[session.machineId] != nil,
          account?.lan?.workspaceId == state.workspaceId,
          account?.user.id == state.userId else { return [] }
    return [UIAction(title: String(localized: "terminal.menu", bundle: .lody), image: UIImage(systemName: "terminal")) { [weak self] _ in
      self?.openTerminal()
    }]
  }

  func openTerminal() {
    guard let page = TerminalController.live(state: source.state, sessionId: sessionId) else { return }
    LodyShell.shared.pushNative(page, title: String(localized: "terminal.menu", bundle: .lody), from: self)
  }
}
