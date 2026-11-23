import LodyCore
import UserNotifications
import XCTest
@testable import LodyKit

@MainActor
final class LanPushLiveActivityTests: XCTestCase {
  private let nowMs: Double = 1_700_000_000_000

  func testLanSummaryIncludesOnlyActiveSessionsWithFreshHeartbeat() throws {
    let rawCatalog = """
    {
      "catalog": {
        "projects": [],
        "machineIds": ["m1", "m2"],
        "machineNames": {"m1": "devNuc", "m2": "homeN100"},
        "sessions": [
          {
            "id": "running-fresh",
            "title": "Yesterday review",
            "status": "running",
            "machineId": "m1",
            "agentType": "antigravity-acp",
            "lastMessageAt": \(nowMs - 1_200_000),
            "lastRunningSeen": \(nowMs - 30_000)
          },
          {
            "id": "permission-fresh",
            "title": "Deploy check",
            "status": "requestPermission",
            "machineId": "m2",
            "agentType": "codex",
            "awaitingUserSince": \(nowMs - 20_000),
            "lastRunningSeen": \(nowMs - 10_000)
          },
          {
            "id": "running-stale",
            "title": "Expired heartbeat",
            "status": "running",
            "machineId": "m1",
            "agentType": "claude-p",
            "lastRunningSeen": \(nowMs - 180_000)
          },
          {
            "id": "running-no-heartbeat",
            "title": "Missing heartbeat",
            "status": "running",
            "machineId": "m1",
            "agentType": "codex"
          },
          {
            "id": "finished-unread",
            "title": "Completed task",
            "status": "idle",
            "machineId": "m1",
            "agentType": "codex",
            "lastMessageAt": \(nowMs - 5_000),
            "lastReadAt": \(nowMs - 60_000)
          },
          {
            "id": "failed-turn",
            "title": "Failed task",
            "status": "error",
            "machineId": "m1",
            "agentType": "claude",
            "lastHandledUserMsgId": "u1",
            "lastFailedUserMsgId": "u1",
            "lastMessageAt": \(nowMs - 5_000)
          }
        ]
      },
      "syncedAt": \(nowMs)
    }
    """
    let decoded = try XCTUnwrap(SessionCatalog.decode(saved: Data(rawCatalog.utf8)))
    XCTAssertEqual(decoded.session("running-fresh")?.lastRunningSeen, nowMs - 30_000)

    let list = SessionListState(
      userId: "local:owner",
      workspaceId: "lw_testlanworkspace",
      catalog: decoded
    )
    let state = ConversationActivities.summary(list, now: nowMs)

    XCTAssertEqual(state.totalCount, 2)
    XCTAssertEqual(state.statusCounts.permission, 1)
    XCTAssertEqual(state.statusCounts.running, 1)
    XCTAssertEqual(state.statusCounts.unread, 0)
    XCTAssertEqual(state.items.map(\.id), ["permission-fresh", "running-fresh"])

    let perm = state.items[0]
    XCTAssertEqual(perm.status, .permission)
    XCTAssertEqual(perm.machineName, "homeN100")
    XCTAssertEqual(perm.agentLogoKind, "codex")
    XCTAssertEqual(perm.agentLogoText, "CX")
    XCTAssertEqual(perm.updatedAtLabel, "")
    XCTAssertEqual(perm.startedAt, nowMs - 20_000)

    let run = state.items[1]
    XCTAssertEqual(run.status, .running)
    XCTAssertEqual(run.machineName, "devNuc")
    XCTAssertEqual(run.agentLogoKind, "antigravity-acp")
    XCTAssertEqual(run.agentLogoText, "AG")
    XCTAssertEqual(run.updatedAtLabel, "")
    XCTAssertEqual(run.startedAt, nowMs - 30_000)

    XCTAssertEqual(
      ConversationActivities.nextLanHeartbeatExpiry(list, now: nowMs),
      (nowMs - 30_000) + ConversationActivities.lanHeartbeatTTL
    )
  }

  func testCloudSummaryRetainsUnreadSessionsWithoutHeartbeat() {
    var unread = SessionItem(
      id: "cloud-unread",
      title: "Finished cloud task",
      status: "idle",
      userId: "cloud-user",
      lastMessageAt: nowMs - 60_000,
      lastReadAt: nowMs - 120_000,
      agentType: "claude-p"
    )
    unread.lastRunningSeen = nil
    let list = SessionListState(
      userId: "cloud-user",
      workspaceId: "ws_cloud",
      catalog: SessionCatalog(sessions: [unread])
    )
    let state = ConversationActivities.summary(list, now: nowMs)
    XCTAssertEqual(state.totalCount, 1)
    XCTAssertEqual(state.statusCounts.unread, 1)
    XCTAssertEqual(state.items.first?.id, "cloud-unread")
    XCTAssertEqual(state.items.first?.agentLogoKind, "claude")
    XCTAssertFalse(state.items.first?.updatedAtLabel.isEmpty ?? true)
  }

  func testCarryingRemoteDetailPreservesHubFieldsAndSuppressesNoOpUpdates() {
    let remoteOption = LodyConversationLiveActivityAttributes.PermissionOption(
      id: "allow_once",
      label: "Allow",
      kind: "allow_once"
    )
    let remoteState = LodyConversationLiveActivityAttributes.ContentState(
      totalCount: 2,
      statusCounts: .init(permission: 1, question: 0, running: 1, unread: 0),
      items: [
        .init(
          id: "s-perm",
          status: .permission,
          statusLabel: "Permission",
          permissionRequestId: "req-1",
          permissionCommand: "git status",
          permissionResponseState: .sending,
          agentLogoKind: "codex",
          agentLogoText: "CX",
          title: "Check repo",
          updatedAt: nowMs - 10_000,
          updatedAtLabel: "",
          startedAt: nowMs - 60_000,
          machineName: "devNuc",
          permissionOptions: [remoteOption]
        ),
        .init(
          id: "s-run",
          status: .running,
          statusLabel: "Running",
          agentLogoKind: "antigravity-acp",
          agentLogoText: "AG",
          title: "Daily recap",
          updatedAt: nowMs - 5_000,
          updatedAtLabel: "",
          startedAt: nowMs - 120_000,
          machineName: "devNuc",
          activity: "Reading logs",
          thought: "Summarizing findings"
        ),
      ],
      updatedAt: nowMs - 5_000
    )

    let localFresh = LodyConversationLiveActivityAttributes.ContentState(
      totalCount: 2,
      statusCounts: .init(permission: 1, question: 0, running: 1, unread: 0),
      items: [
        .init(
          id: "s-perm",
          status: .permission,
          statusLabel: "permission",
          agentLogoKind: "codex",
          agentLogoText: "CX",
          title: "Check repo",
          updatedAt: nowMs,
          updatedAtLabel: "",
          startedAt: nowMs - 40_000,
          machineName: "devNuc"
        ),
        .init(
          id: "s-run",
          status: .running,
          statusLabel: "running",
          agentLogoKind: "antigravity-acp",
          agentLogoText: "AG",
          title: "Daily recap",
          updatedAt: nowMs,
          updatedAtLabel: "",
          startedAt: nowMs - 30_000,
          machineName: "devNuc"
        ),
      ],
      updatedAt: nowMs
    )

    let merged = ConversationActivities.carryingRemoteDetail(localFresh, from: remoteState)
    XCTAssertEqual(merged.items[0].permissionRequestId, "req-1")
    XCTAssertEqual(merged.items[0].permissionCommand, "git status")
    XCTAssertEqual(merged.items[0].permissionResponseState, .sending)
    XCTAssertEqual(merged.items[0].permissionOptions, [remoteOption])
    XCTAssertEqual(merged.items[0].startedAt, nowMs - 60_000)
    XCTAssertEqual(merged.items[1].activity, "Reading logs")
    XCTAssertEqual(merged.items[1].thought, "Summarizing findings")
    XCTAssertEqual(merged.items[1].startedAt, nowMs - 120_000)

    XCTAssertFalse(
      ConversationActivities.needsLocalUpdate(existing: remoteState, next: merged, isStale: false, isLAN: true)
    )
    XCTAssertTrue(
      ConversationActivities.needsLocalUpdate(existing: remoteState, next: merged, isStale: true, isLAN: true)
    )
  }

  func testLiveActivityRouteURLMatchesAppLinkParser() {
    let lanAttributes = LodyConversationLiveActivityAttributes(
      activityId: "lody-conversations:v5:lw_abc:local:u1",
      workspaceId: "lw_abc",
      workspaceSlug: nil,
      workspaceName: "Home",
      onesignal: .create(activityId: "lody-conversations:v5:lw_abc:local:u1")
    )
    let activeState = LodyConversationLiveActivityAttributes.ContentState(
      totalCount: 1,
      statusCounts: .init(running: 1),
      items: [
        .init(
          id: "ca37897d-85bf-8e80-8884-40ee401b801f",
          status: .running,
          statusLabel: "Running",
          agentLogoKind: "antigravity-acp",
          agentLogoText: "AG",
          title: "Home recap",
          updatedAt: nowMs,
          updatedAtLabel: ""
        ),
      ],
      updatedAt: nowMs
    )
    let sessionURL = lanAttributes.routeURL(for: activeState)
    XCTAssertEqual(sessionURL.absoluteString, "lody://lan/sessions/ca37897d-85bf-8e80-8884-40ee401b801f")
    XCTAssertEqual(
      AppLink.parse(sessionURL.absoluteString),
      .session(workspace: "lan", session: "ca37897d-85bf-8e80-8884-40ee401b801f")
    )

    let emptyState = LodyConversationLiveActivityAttributes.ContentState(
      totalCount: 0,
      statusCounts: .init(),
      items: [],
      updatedAt: nowMs
    )
    let fallbackURL = lanAttributes.routeURL(for: emptyState)
    XCTAssertEqual(fallbackURL.absoluteString, "lody:///activity")
    XCTAssertEqual(AppLink.parse(fallbackURL.absoluteString), .page("activity", [:]))

    let invalidState = LodyConversationLiveActivityAttributes.ContentState(
      totalCount: 1,
      statusCounts: .init(running: 1),
      items: [
        .init(
          id: "../escape",
          status: .running,
          statusLabel: "Running",
          agentLogoKind: "codex",
          agentLogoText: "CX",
          title: "Invalid",
          updatedAt: nowMs,
          updatedAtLabel: ""
        ),
      ],
      updatedAt: nowMs
    )
    XCTAssertEqual(lanAttributes.routeURL(for: invalidState).absoluteString, "lody:///activity")

    let mixedState = LodyConversationLiveActivityAttributes.ContentState(
      totalCount: 2,
      statusCounts: .init(permission: 1, question: 1),
      items: [
        .init(
          id: "question-session",
          status: .question,
          statusLabel: "Question",
          agentLogoKind: "claude",
          agentLogoText: "CC",
          title: "Question first",
          updatedAt: nowMs,
          updatedAtLabel: ""
        ),
        .init(
          id: "permission-session",
          status: .permission,
          statusLabel: "Permission",
          permissionRequestId: "req-2",
          agentLogoKind: "codex",
          agentLogoText: "CX",
          title: "Permission second",
          updatedAt: nowMs,
          updatedAtLabel: ""
        ),
      ],
      updatedAt: nowMs
    )
    XCTAssertEqual(
      lanAttributes.routeURL(for: mixedState, preferredSessionId: "permission-session").absoluteString,
      "lody://lan/sessions/permission-session"
    )
  }

  func testLanPushDeviceTokenRecordAndRetryPolicy() throws {
    let validHex = String(repeating: "aB", count: 32)
    let encoded = try XCTUnwrap(
      LanPushDeviceTokenRecord.encode(token: validHex, bundleId: "com.dreaife.lody", environment: "production")
    )
    XCTAssertEqual(
      LanPushDeviceTokenRecord.decode(encoded, expectedBundleId: "com.dreaife.lody", expectedEnvironment: "production"),
      validHex.lowercased()
    )
    XCTAssertNil(
      LanPushDeviceTokenRecord.decode(encoded, expectedBundleId: "app.innei.lody", expectedEnvironment: "production")
    )
    XCTAssertNil(
      LanPushDeviceTokenRecord.decode(encoded, expectedBundleId: "com.dreaife.lody", expectedEnvironment: "development")
    )
    XCTAssertNil(LanPushDeviceTokenRecord.encode(token: "short", bundleId: "com.dreaife.lody", environment: "production"))
    XCTAssertNil(LanPushDeviceTokenRecord.encode(token: String(repeating: "zz", count: 32), bundleId: "com.dreaife.lody", environment: "production"))

    XCTAssertTrue(LanPush.shouldRetry(httpStatus: 500))
    XCTAssertTrue(LanPush.shouldRetry(httpStatus: 503))
    XCTAssertTrue(LanPush.shouldRetry(httpStatus: 408))
    XCTAssertTrue(LanPush.shouldRetry(httpStatus: 429))
    XCTAssertFalse(LanPush.shouldRetry(httpStatus: 400))
    XCTAssertFalse(LanPush.shouldRetry(httpStatus: 401))
    XCTAssertFalse(LanPush.shouldRetry(httpStatus: 403))
    XCTAssertFalse(LanPush.shouldRetry(httpStatus: 404))

    XCTAssertTrue(LanPush.alertsAuthorized(.authorized))
    XCTAssertTrue(LanPush.alertsAuthorized(.provisional))
    XCTAssertTrue(LanPush.alertsAuthorized(.ephemeral))
    XCTAssertFalse(LanPush.alertsAuthorized(.denied))
    XCTAssertFalse(LanPush.alertsAuthorized(.notDetermined))
  }

  func testLanActivityTokenExitDoesNotEraseReplacementActivity() {
    var map = LanPushActivityTokens()
    let id = "lody-conversations:v5:lw_abc:local:u1"
    map.claim(nativeId: "native-a")
    map.claim(nativeId: "native-b")
    // Newer native-b delivers its token first; a late token from older native-a must not overwrite it.
    XCTAssertTrue(map.enter(id, hex: "bb", nativeId: "native-b"))
    XCTAssertFalse(map.enter(id, hex: "bb", nativeId: "native-b"))
    XCTAssertFalse(map.enter(id, hex: "aa", nativeId: "native-a"))
    XCTAssertEqual(map.values[id], "bb")
    // Late exit from the ended older activity must not remove the replacement token.
    XCTAssertFalse(map.exit(id, ifHex: "aa", nativeId: "native-a"))
    XCTAssertFalse(map.exit(id, ifHex: "bb", nativeId: "native-a"))
    XCTAssertEqual(map.values[id], "bb")
    // Active owner exiting removes the token cleanly.
    XCTAssertTrue(map.exit(id, ifHex: "bb", nativeId: "native-b"))
    XCTAssertNil(map.values[id])

    // When owner exits and an older live activity remains, explicit replacement promotes it cleanly.
    map.claim(nativeId: "native-1")
    map.claim(nativeId: "native-2")
    XCTAssertTrue(map.enter(id, hex: "22", nativeId: "native-2"))
    XCTAssertTrue(map.replace(id, departingNativeId: "native-2", replacementNativeId: "native-1", replacementHex: "11"))
    XCTAssertEqual(map.values[id], "11")
  }

  func testCarryingRemoteDetailDropsPermissionFieldsWhenStatusChanges() {
    let remote = LodyConversationLiveActivityAttributes.ContentState(
      totalCount: 1,
      statusCounts: .init(permission: 1),
      items: [
        .init(
          id: "s1",
          status: .permission,
          statusLabel: "Permission",
          permissionRequestId: "req-1",
          permissionCommand: "rm -rf /tmp/foo",
          agentLogoKind: "codex",
          agentLogoText: "CX",
          title: "Run task",
          updatedAt: nowMs - 5_000,
          updatedAtLabel: "",
          startedAt: nowMs - 60_000,
          permissionOptions: [.init(id: "allow", label: "Allow", kind: "allow_once")]
        ),
      ],
      updatedAt: nowMs - 5_000
    )
    let resumed = LodyConversationLiveActivityAttributes.ContentState(
      totalCount: 1,
      statusCounts: .init(running: 1),
      items: [
        .init(
          id: "s1",
          status: .running,
          statusLabel: "running",
          agentLogoKind: "codex",
          agentLogoText: "CX",
          title: "Run task",
          updatedAt: nowMs,
          updatedAtLabel: "",
          startedAt: nowMs - 10_000
        ),
      ],
      updatedAt: nowMs
    )
    let merged = ConversationActivities.carryingRemoteDetail(resumed, from: remote)
    XCTAssertNil(merged.items[0].permissionRequestId)
    XCTAssertNil(merged.items[0].permissionCommand)
    XCTAssertNil(merged.items[0].permissionOptions)
    XCTAssertTrue(
      ConversationActivities.needsLocalUpdate(existing: remote, next: merged, isStale: false, isLAN: true)
    )
  }

  func testLanPushWakeTrackerWaitsForDelayedReplacementActivityToken() {
    var wake = LanPushWakeTracker()
    let logicalId = "lody-conversations:v5:lw_abc:local:u1"

    // Old activity already has a token while a brand-new push-to-start activity is still awaiting its token.
    wake.markTokenEntered(nativeId: "old-native", tokenHex: "aaaa")
    wake.markAwaitingToken(nativeId: "new-native")
    XCTAssertTrue(wake.hasPendingWork)
    XCTAssertFalse(wake.canReleaseEarly)

    // First PUT only uploads the old token; background wake MUST NOT release early yet.
    let firstCovered = wake.coveredEntries(in: [logicalId: "aaaa"])
    wake.markUploadConfirmed(firstCovered)
    XCTAssertTrue(wake.hasPendingWork)
    XCTAssertFalse(wake.canReleaseEarly)

    // New activity token arrives and replaces the logical activity token; still awaiting upload confirmation.
    wake.markTokenEntered(nativeId: "new-native", tokenHex: "bbbb")
    XCTAssertTrue(wake.hasPendingWork)
    XCTAssertFalse(wake.canReleaseEarly)

    // Second PUT confirms the new token; now background wake may release early.
    let secondCovered = wake.coveredEntries(in: [logicalId: "bbbb"])
    wake.markUploadConfirmed(secondCovered)
    XCTAssertFalse(wake.hasPendingWork)
    XCTAssertTrue(wake.canReleaseEarly)
  }
}
