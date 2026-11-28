import Foundation
import UIKit
import XCTest
@testable import LodyKit

@MainActor
final class HomeCreateButtonTests: XCTestCase {
  private static func descendants(_ view: UIView) -> [UIView] {
    [view] + view.subviews.flatMap(descendants)
  }

  private func makeWindow(size: CGSize) -> UIWindow {
    let window = UIWindow(frame: CGRect(origin: .zero, size: size))
    window.makeKeyAndVisible()
    return window
  }

  private func compactCreateButton(in controller: UIViewController) -> UIButton? {
    Self.descendants(controller.view).compactMap { $0 as? UIButton }.first {
      $0.accessibilityIdentifier == "home-new-session"
    }
  }

  private func padCreateButton(in view: UIView) -> UIButton? {
    Self.descendants(view).compactMap { $0 as? UIButton }.first {
      $0.accessibilityIdentifier == "home-create"
    }
  }

  private func latestToastMessage() -> String? {
    guard let window = LodyToastOverlay.shared.hostedWindow else { return nil }
    return Self.descendants(window).compactMap { $0 as? LodyToastPillView }.last?.message
  }

  func testCompactCreateButtonStaysEnabledAcrossAllWorkspaceAndConnectionStates() throws {
    let suffix = UUID().uuidString
    let unknownID = "verify-unknown-\(suffix)"
    let e2eeID = "verify-e2ee-\(suffix)"
    let plainID = "verify-plain-\(suffix)"
    try WorkspaceModePins.shared.observe(plainID, mode: .plaintext)

    let unknownWorkspace = AuthWorkspace(id: unknownID, name: "Unknown", slug: nil, image: nil)
    let e2eeWorkspace = AuthWorkspace(id: e2eeID, name: "Encrypted", slug: nil, image: nil, contentMode: .e2ee)
    let plainWorkspace = AuthWorkspace(id: plainID, name: "Plain", slug: nil, image: nil, contentMode: .plaintext)

    let changed = Notification.Name("HomeCreateButtonTests.\(suffix)")
    var state = SessionListState()
    let source = SessionSource(
      changes: [changed],
      read: { state },
      write: { _, _, _ in }
    )

    let window = makeWindow(size: CGSize(width: 393, height: 852))
    let home = HomeController(source: source)
    LodyShell.shared.start(in: window, content: home)
    window.layoutIfNeeded()

    // On iOS < 27 the create action is the floating UIButton; on iOS 27+ it is the prominent UITab.
    func assertCreateEnabled(_ context: String) {
      if #available(iOS 27.0, *) {
        if let tabController = Self.findTabBarController(in: home) {
          let createTab = tabController.tab(forIdentifier: "home-new-session")
          XCTAssertEqual(createTab?.isEnabled, true, "iOS 27 create tab must stay enabled: \(context)")
        } else {
          XCTFail("Missing HomeTabsController: \(context)")
        }
      } else {
        guard let button = compactCreateButton(in: home) else {
          XCTFail("Missing floating create button: \(context)")
          return
        }
        XCTAssertTrue(button.isEnabled, "Floating create button must stay enabled (not gray): \(context)")
      }
    }

    // 1. Cold start / pre-hydration: signed out / workspace nil.
    assertCreateEnabled("cold launch before auth hydration (workspace == nil)")

    // 2. Signed in, workspace mode .unknown (offline/timeout/uncached describe).
    state = SessionListState(
      userId: "user-1",
      accountEmail: "tester@example.test",
      workspaceId: unknownID,
      loading: true,
      connected: false,
      presence: .unknown,
      workspaces: [unknownWorkspace, e2eeWorkspace, plainWorkspace]
    )
    NotificationCenter.default.post(name: changed, object: nil)
    window.layoutIfNeeded()
    assertCreateEnabled("unknown workspace encryption mode")

    // 3. Signed in, encrypted workspace (.e2ee).
    state.workspaceId = e2eeID
    state.loading = false
    state.connected = false
    NotificationCenter.default.post(name: changed, object: nil)
    window.layoutIfNeeded()
    assertCreateEnabled("e2ee workspace")

    // 4. Plaintext workspace while syncing, offline, and with no online machines.
    state.workspaceId = plainID
    state.loading = true
    state.connected = false
    state.presence = SettingsMachinePresence(state: "live", onlineMachineIds: [])
    NotificationCenter.default.post(name: changed, object: nil)
    window.layoutIfNeeded()
    assertCreateEnabled("plaintext syncing + offline + no online machines")

    // 5. Normal live plaintext workspace.
    state.loading = false
    state.connected = true
    state.presence = SettingsMachinePresence(state: "live", onlineMachineIds: ["m1"])
    NotificationCenter.default.post(name: changed, object: nil)
    window.layoutIfNeeded()
    assertCreateEnabled("plaintext live normal")
  }

  func testPadCreateButtonStaysEnabledAcrossAllWorkspaceStates() throws {
    let suffix = UUID().uuidString
    let unknownID = "verify-pad-unknown-\(suffix)"
    let e2eeID = "verify-pad-e2ee-\(suffix)"
    let plainID = "verify-pad-plain-\(suffix)"
    try WorkspaceModePins.shared.observe(plainID, mode: .plaintext)

    let unknownWorkspace = AuthWorkspace(id: unknownID, name: "Unknown", slug: nil, image: nil)
    let e2eeWorkspace = AuthWorkspace(id: e2eeID, name: "Encrypted", slug: nil, image: nil, contentMode: .e2ee)
    let plainWorkspace = AuthWorkspace(id: plainID, name: "Plain", slug: nil, image: nil, contentMode: .plaintext)

    let host = UIViewController()
    let content = UIViewController()
    let scroll = UIScrollView()
    let nav = UINavigationController(rootViewController: host)
    let window = makeWindow(size: CGSize(width: 1024, height: 768))
    if #available(iOS 17.0, *) {
      host.traitOverrides.horizontalSizeClass = .regular
    }
    window.rootViewController = nav
    window.layoutIfNeeded()

    let chrome = InboxChrome()
    chrome.attach(to: host, content: content, scrollView: scroll)

    for (label, selected) in [
      ("unknown", unknownWorkspace),
      ("e2ee", e2eeWorkspace),
      ("plaintext", plainWorkspace),
    ] {
      chrome.update(InboxChrome.Model(
        accountEmail: "tester@example.test",
        workspaces: [unknownWorkspace, e2eeWorkspace, plainWorkspace],
        selected: selected,
        devices: InboxDevices(catalog: SessionCatalog(), presence: .unknown),
        connection: .connecting
      ))
      window.layoutIfNeeded()
      let button = padCreateButton(in: host.view)
      XCTAssertNotNil(button, "Expected InboxPadBar create button in \(label)")
      XCTAssertTrue(button?.isEnabled == true, "iPad create button must stay enabled (not gray) in \(label)")
    }
  }

  func testTapEnforcesWorkspaceBoundariesAndPreventsDuplicateCreateNavigation() throws {
    let suffix = UUID().uuidString
    let unknownID = "verify-tap-unknown-\(suffix)"
    let e2eeID = "verify-tap-e2ee-\(suffix)"
    let plainID = "verify-tap-plain-\(suffix)"
    try WorkspaceModePins.shared.observe(plainID, mode: .plaintext)

    let unknownWorkspace = AuthWorkspace(id: unknownID, name: "Unknown", slug: nil, image: nil)
    let e2eeWorkspace = AuthWorkspace(id: e2eeID, name: "Encrypted", slug: nil, image: nil, contentMode: .e2ee)
    let plainWorkspace = AuthWorkspace(id: plainID, name: "Plain", slug: nil, image: nil, contentMode: .plaintext)

    let changed = Notification.Name("HomeCreateTapTests.\(suffix)")
    var state = SessionListState()
    let source = SessionSource(
      changes: [changed],
      read: { state },
      write: { _, _, _ in }
    )

    let window = makeWindow(size: CGSize(width: 393, height: 852))
    let home = HomeController(source: source)
    LodyShell.shared.start(in: window, content: home)
    window.layoutIfNeeded()
    guard let rootNav = window.rootViewController as? UINavigationController else {
      XCTFail("Missing root navigation controller")
      return
    }

    let inbox = Self.findInboxController(in: home)
    XCTAssertNotNil(inbox, "Missing InboxController")

    // Signed out / workspace == nil -> stays on Home, shows signInFirst toast.
    LodyToastOverlay.shared.dismiss()
    inbox?.newSession()
    XCTAssertEqual(rootNav.viewControllers.count, 1, "Signed-out tap must not push CreateSession")
    XCTAssertEqual(latestToastMessage(), String(localized: "tabs.toast.signInFirst", bundle: .lody))

    // Unknown workspace -> stays on Home, shows unknown-mode feedback, never opens plaintext creation.
    state = SessionListState(
      userId: "user-1",
      accountEmail: "tester@example.test",
      workspaceId: unknownID,
      workspaces: [unknownWorkspace, e2eeWorkspace, plainWorkspace]
    )
    NotificationCenter.default.post(name: changed, object: nil)
    LodyToastOverlay.shared.dismiss()
    inbox?.newSession()
    XCTAssertEqual(rootNav.viewControllers.count, 1, "Unknown workspace tap must not open CreateSession")
    XCTAssertEqual(latestToastMessage(), String(localized: "workspace.mode.unknown", bundle: .lody))
    XCTAssertThrowsError(try SessionNavigation.handle("create", ["workspaceId": unknownID]))

    // E2EE workspace -> stays on Home, shows E2EE unsupported feedback, never opens plaintext creation.
    state.workspaceId = e2eeID
    NotificationCenter.default.post(name: changed, object: nil)
    LodyToastOverlay.shared.dismiss()
    inbox?.newSession()
    XCTAssertEqual(rootNav.viewControllers.count, 1, "E2EE workspace tap must not open CreateSession")
    XCTAssertEqual(latestToastMessage(), String(localized: "workspace.e2ee.unsupported", bundle: .lody))
    XCTAssertThrowsError(try SessionNavigation.handle("create", ["workspaceId": e2eeID]))

    // Plaintext workspace (even while syncing/offline/no machines) -> opens standard CreateSession once.
    state.workspaceId = plainID
    state.loading = true
    state.connected = false
    state.presence = SettingsMachinePresence(state: "live", onlineMachineIds: [])
    NotificationCenter.default.post(name: changed, object: nil)

    let first = try SessionNavigation.handle("create", ["workspaceId": plainID])
    XCTAssertNotNil(first, "Plaintext create must open CreateSessionHostController")
    first?.loadViewIfNeeded()
    let second = try SessionNavigation.handle("create", ["workspaceId": plainID])
    XCTAssertTrue(first === second, "Duplicate create tap while open must reuse active page instead of stacking")
    let createPages = rootNav.viewControllers.filter { page in
      page.loadViewIfNeeded()
      return page.children.contains { $0 is CreateSessionHostController }
    }
    XCTAssertEqual(createPages.count, 1, "Root navigation must hold only one CreateSession page")

    // After closing, tapping again opens a fresh CreateSession page.
    first?.markClosed()
    rootNav.popToRootViewController(animated: false)
    let third = try SessionNavigation.handle("create", ["workspaceId": plainID])
    XCTAssertNotNil(third)
    XCTAssertFalse(first === third, "After closing, create must open a new page")
    third?.markClosed()
    rootNav.popToRootViewController(animated: false)
  }

  func testSchedulesNewScheduleEnforcesWorkspaceBoundaries() throws {
    let suffix = UUID().uuidString
    let unknownID = "verify-sched-unknown-\(suffix)"
    let e2eeID = "verify-sched-e2ee-\(suffix)"
    let plainID = "verify-sched-plain-\(suffix)"
    try WorkspaceModePins.shared.observe(plainID, mode: .plaintext)

    let unknownWorkspace = AuthWorkspace(id: unknownID, name: "Unknown", slug: nil, image: nil)
    let e2eeWorkspace = AuthWorkspace(id: e2eeID, name: "Encrypted", slug: nil, image: nil, contentMode: .e2ee)
    let plainWorkspace = AuthWorkspace(id: plainID, name: "Plain", slug: nil, image: nil, contentMode: .plaintext)

    let changed = Notification.Name("HomeCreateScheduleTests.\(suffix)")
    var state = SessionListState(
      userId: "user-1",
      accountEmail: "tester@example.test",
      workspaceId: unknownID,
      workspaces: [unknownWorkspace, e2eeWorkspace, plainWorkspace]
    )
    let source = SessionSource(changes: [changed], read: { state }, write: { _, _, _ in })
    let schedules = SchedulesController(source: source, service: ScheduleFixture.shared.service)
    let nav = UINavigationController(rootViewController: schedules)
    let window = makeWindow(size: CGSize(width: 393, height: 852))
    window.rootViewController = nav
    window.layoutIfNeeded()

    LodyToastOverlay.shared.dismiss()
    schedules.newSchedule()
    XCTAssertEqual(nav.viewControllers.count, 1, "Unknown workspace must not open schedule editor")
    XCTAssertEqual(latestToastMessage(), String(localized: "workspace.mode.unknown", bundle: .lody))

    state.workspaceId = e2eeID
    LodyToastOverlay.shared.dismiss()
    schedules.newSchedule()
    XCTAssertEqual(nav.viewControllers.count, 1, "E2EE workspace must not open schedule editor")
    XCTAssertEqual(latestToastMessage(), String(localized: "workspace.e2ee.unsupported", bundle: .lody))
  }

  private static func findTabBarController(in controller: UIViewController) -> UITabBarController? {
    if let tab = controller as? UITabBarController { return tab }
    for child in controller.children {
      if let found = findTabBarController(in: child) { return found }
    }
    return nil
  }

  private static func findInboxController(in controller: UIViewController) -> InboxController? {
    if let inbox = controller as? InboxController { return inbox }
    for child in controller.children {
      if let found = findInboxController(in: child) { return found }
    }
    return nil
  }
}
