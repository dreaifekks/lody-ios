import Foundation
import UIKit
import XCTest
@testable import LodyKit

@MainActor
final class SessionMoreMenuTests: XCTestCase {
  private func localized(_ key: String) -> String {
    String(localized: String.LocalizationValue(key), bundle: .lody)
  }

  private func makeController(
    session: SessionItem,
    extraSessions: [SessionItem] = [],
    layout: StatusViewLayout
  ) -> SessionController {
    let workspaceId = "ws-more-\(UUID().uuidString)"
    let userId = "user-1"
    let catalog = SessionCatalog(
      sessions: [session] + extraSessions,
      statusView: StatusViewLayouts(mine: layout, team: layout, nowMs: 1_700_000_000_000, sectionsLoaded: true)
    )
    let state = SessionListState(
      userId: userId,
      workspaceId: workspaceId,
      workspaces: [AuthWorkspace(id: workspaceId, name: "Workspace", slug: "ws", image: nil)],
      catalog: catalog
    )
    let source = SessionSource(changes: [], read: { state }, write: { _, _, _ in })
    return SessionController(
      sessionId: session.id,
      source: source,
      feed: SessionFeedService(watch: { _, _ in {} }, reconnect: { _ in }, cached: { _, _, _ in nil }),
      previewCache: SessionPreviewCache(observeMemoryWarning: false)
    )
  }

  func testMoreMenuGroupsStatusActionsInSubmenuDirectlyAboveArchive() {
    let opener = SessionItem(id: "opener", title: "Pinned opener", status: "idle", pinned: true)
    let carried = SessionItem(id: "carried", title: "Carried child", status: "idle", pinned: false)
    let layout = StatusViewLayout(
      pinned: [
        StatusViewPinnedSection(
          sectionId: nil,
          name: nil,
          rows: [
            StatusViewRow(
              id: opener.id,
              tier: .pinned,
              children: [StatusViewRow(id: carried.id, tier: .pinned, canManage: true, canPrefer: true)],
              canManage: true,
              canPrefer: true
            ),
          ]
        ),
      ]
    )
    let controller = makeController(session: carried, extraSessions: [opener], layout: layout)
    let elements = controller.moreMenuElements()

    let statusTitle = localized("session.status.title")
    let archiveTitle = localized("session.action.archive")
    let laterTitle = localized("home.status.later")
    let settleTitle = localized("home.status.settle")
    let focusTitle = localized("home.status.moveToFocus")

    let topTitles = elements.map(\.title)
    XCTAssertFalse(topTitles.contains(laterTitle))
    XCTAssertFalse(topTitles.contains(settleTitle))
    XCTAssertFalse(topTitles.contains(focusTitle))

    guard let statusIndex = elements.firstIndex(where: { $0.title == statusTitle }),
          let archiveIndex = elements.firstIndex(where: { $0.title == archiveTitle }) else {
      return XCTFail("Expected both Conversation status submenu and Archive action in More menu: \(topTitles)")
    }
    XCTAssertEqual(statusIndex + 1, archiveIndex, "Conversation status submenu must appear directly above Archive")

    guard let statusSubmenu = elements[statusIndex] as? UIMenu else {
      return XCTFail("Conversation status must be a UIMenu submenu")
    }
    XCTAssertFalse(statusSubmenu.options.contains(.displayInline), "Conversation status must be a secondary submenu, not inline")
    XCTAssertEqual(statusSubmenu.children.map(\.title), [laterTitle, settleTitle, focusTitle])
    XCTAssertTrue(statusSubmenu.children[0] is UIMenu, "Later remains a nested submenu inside Conversation status")
  }

  func testMoreMenuStatusSubmenuFollowsTierAndHidesWhenUnavailable() {
    let statusTitle = localized("session.status.title")
    let laterTitle = localized("home.status.later")
    let settleTitle = localized("home.status.settle")
    let focusTitle = localized("home.status.moveToFocus")

    // Focus tier offers Later and Settle.
    let focusSession = SessionItem(id: "s-focus", title: "Focus", status: "idle")
    let focusController = makeController(
      session: focusSession,
      layout: StatusViewLayout(focus: [StatusViewRow(id: focusSession.id, tier: .focus, canManage: true)])
    )
    let focusStatus = focusController.moreMenuElements().first { $0.title == statusTitle } as? UIMenu
    XCTAssertEqual(focusStatus?.children.map(\.title), [laterTitle, settleTitle])

    // Settled tier offers Later and Move to Focus.
    let settledSession = SessionItem(id: "s-settled", title: "Settled", status: "idle")
    let settledController = makeController(
      session: settledSession,
      layout: StatusViewLayout(settled: [StatusViewRow(id: settledSession.id, tier: .settled, canManage: true)])
    )
    let settledStatus = settledController.moreMenuElements().first { $0.title == statusTitle } as? UIMenu
    XCTAssertEqual(settledStatus?.children.map(\.title), [laterTitle, focusTitle])

    // Archived conversation hides the status submenu.
    let archivedSession = SessionItem(id: "s-archived", title: "Archived", status: "idle", archived: true)
    let archivedController = makeController(
      session: archivedSession,
      layout: StatusViewLayout(focus: [StatusViewRow(id: archivedSession.id, tier: .focus, canManage: true)])
    )
    XCTAssertNil(archivedController.moreMenuElements().first { $0.title == statusTitle })

    // Pinned conversation hides the status submenu.
    let pinnedSession = SessionItem(id: "s-pinned", title: "Pinned", status: "idle", pinned: true)
    let pinnedController = makeController(
      session: pinnedSession,
      layout: StatusViewLayout(pinned: [
        StatusViewPinnedSection(sectionId: nil, name: nil, rows: [
          StatusViewRow(id: pinnedSession.id, tier: .pinned, canManage: true, canPrefer: true),
        ]),
      ])
    )
    XCTAssertNil(pinnedController.moreMenuElements().first { $0.title == statusTitle })

    // Read-only / non-manageable row hides the status submenu.
    let readOnlyController = makeController(
      session: focusSession,
      layout: StatusViewLayout(focus: [StatusViewRow(id: focusSession.id, tier: .focus, canManage: false)])
    )
    XCTAssertNil(readOnlyController.moreMenuElements().first { $0.title == statusTitle })
  }
}
