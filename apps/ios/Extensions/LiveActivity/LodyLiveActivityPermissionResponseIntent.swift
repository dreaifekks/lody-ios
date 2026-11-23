@preconcurrency import ActivityKit
import AppIntents
import Foundation
#if !LODY_LIVE_ACTIVITY_EXTENSION
import LodyKit
#endif

@available(iOS 17.0, iOSApplicationExtension 17.0, *)
struct LodyLiveActivityPermissionResponseIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Respond to Lody Permission"
    static let openAppWhenRun: Bool = false

    @Parameter(title: "Activity ID")
    var activityId: String

    @Parameter(title: "Workspace ID")
    var workspaceId: String

    @Parameter(title: "Session ID")
    var sessionId: String

    @Parameter(title: "Request ID")
    var requestId: String

    @Parameter(title: "Action")
    var action: String

    @Parameter(title: "Option ID")
    var optionId: String

    init() {
        self.activityId = ""
        self.workspaceId = ""
        self.sessionId = ""
        self.requestId = ""
        self.action = ""
        self.optionId = ""
    }

    init(activityId: String, workspaceId: String, sessionId: String, requestId: String, action: String, optionId: String = "") {
        self.activityId = activityId
        self.workspaceId = workspaceId
        self.sessionId = sessionId
        self.requestId = requestId
        self.action = action
        self.optionId = optionId
    }

    func perform() async throws -> some IntentResult {
        guard action == "allow" || action == "reject" else {
            throw LodyLiveActivityPermissionIntentError.invalidAction
        }
        await updatePermissionActivities(responseState: .sending)
        let matched = matchingActivities().first(where: { activity in
            activity.attributes.workspaceId == workspaceId && activity.content.state.items.contains {
                $0.id == sessionId && $0.permissionRequestId == requestId
            }
        })
        guard let matched else {
            await updatePermissionActivities(responseState: .failed)
            return .result()
        }

        if LanInvite.isWorkspace(workspaceId) {
            await performLAN(matched: matched)
            return .result()
        }

        guard let token = try AuthKeychain.read(), let site = URL(string: BackendEnvironment.site) else {
            await updatePermissionActivities(responseState: .failed)
            return .result()
        }

        let endpoint = site
            .appendingPathComponent("api")
            .appendingPathComponent("live-activity")
            .appendingPathComponent("permission-response")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "activityId": activityId,
                "workspaceId": workspaceId,
                "sessionId": sessionId,
                "requestId": requestId,
                "action": action,
            ])
        } catch {
            await updatePermissionActivities(responseState: .failed)
            return .result()
        }

        do {
            let (_, httpResponse) = try await performPermissionRequest(request)

            guard (200..<300).contains(httpResponse.statusCode) else {
                throw LodyLiveActivityPermissionIntentError.rejected(httpResponse.statusCode)
            }
            await updatePermissionActivities(responseState: successResponseState)
        } catch {
            await updatePermissionActivities(responseState: isTimeout(error) ? .timedOut : .failed)
            return .result()
        }

        return .result()
    }

    private func performLAN(matched: Activity<LodyConversationLiveActivityAttributes>) async {
        guard let invite = try? LanHub.read(), invite.workspaceId == workspaceId else {
            await updatePermissionActivities(responseState: .failed)
            return
        }
        let item = matched.content.state.items.first { $0.id == sessionId && $0.permissionRequestId == requestId }
        let resolvedOption: String
        if !optionId.isEmpty {
            resolvedOption = optionId
        } else if action == "allow", let allow = item?.allowOption?.id {
            resolvedOption = allow
        } else if action == "reject", let deny = item?.denyOption?.id {
            resolvedOption = deny
        } else {
            resolvedOption = action == "allow" ? "allow_once" : "reject_once"
        }
        do {
            let payload = try JSONSerialization.data(withJSONObject: [
                "sessionId": sessionId,
                "requestId": requestId,
                "optionId": resolvedOption,
            ])
            let (data, httpResponse) = try await LanHub.request(invite, path: "/push/permission", method: "POST", body: payload, timeout: 10)
            guard (200..<300).contains(httpResponse.statusCode) else {
                throw LodyLiveActivityPermissionIntentError.rejected(httpResponse.statusCode)
            }
            let answer = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            guard answer?["ok"] as? Bool == true else {
                throw LodyLiveActivityPermissionIntentError.invalidResponse
            }
            await updatePermissionActivities(responseState: successResponseState)
        } catch {
            await updatePermissionActivities(responseState: isTimeout(error) ? .timedOut : .failed)
        }
    }

    private var successResponseState: LodyPermissionResponseState {
        action == "allow" ? .allowed : .rejected
    }

    private func performPermissionRequest(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await withThrowingTaskGroup(of: LodyLiveActivityPermissionRequestResult.self) { group in
            group.addTask {
                let (data, response) = try await URLSession.shared.data(for: request)
                return LodyLiveActivityPermissionRequestResult(data: data, response: response)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: 10_000_000_000)
                throw LodyLiveActivityPermissionIntentError.timedOut
            }

            guard let result = try await group.next() else {
                throw LodyLiveActivityPermissionIntentError.invalidResponse
            }
            group.cancelAll()

            guard let httpResponse = result.response as? HTTPURLResponse else {
                throw LodyLiveActivityPermissionIntentError.invalidResponse
            }
            return (result.data, httpResponse)
        }
    }

    private func updatePermissionActivities(responseState: LodyPermissionResponseState) async {
        for activity in matchingActivities() {
            let currentState = activity.content.state
            guard let nextState = currentState.updatingPermissionResponse(
                sessionId: sessionId,
                requestId: requestId,
                responseState: responseState
            ) else {
                continue
            }
            let staleInterval: TimeInterval = activity.attributes.isLAN ? 30 * 60 : 5 * 60
            let nextStale = max(activity.content.staleDate ?? .distantPast, Date(timeIntervalSinceNow: staleInterval))
            await activity.update(
                ActivityContent(
                    state: nextState,
                    staleDate: nextStale,
                    relevanceScore: 100
                )
            )
        }
    }

    private func matchingActivities() -> [Activity<LodyConversationLiveActivityAttributes>] {
        return Activity<LodyConversationLiveActivityAttributes>.activities.filter {
            $0.attributes.activityId == activityId && ($0.activityState == .active || $0.activityState == .stale)
        }
    }

    private func isTimeout(_ error: Error) -> Bool {
        if case LodyLiveActivityPermissionIntentError.timedOut = error {
            return true
        }
        guard let urlError = error as? URLError else {
            return false
        }
        return urlError.code == .timedOut
    }
}

@available(iOS 17.0, iOSApplicationExtension 17.0, *)
struct LodyLiveActivityPermissionFeedbackIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Open Lody Permission"
    static let openAppWhenRun: Bool = true

    @Parameter(title: "Activity ID")
    var activityId: String

    @Parameter(title: "Session ID")
    var sessionId: String

    @Parameter(title: "Request ID")
    var requestId: String

    init() {
        self.activityId = ""
        self.sessionId = ""
        self.requestId = ""
    }

    init(activityId: String, sessionId: String, requestId: String) {
        self.activityId = activityId
        self.sessionId = sessionId
        self.requestId = requestId
    }

    func perform() async throws -> some IntentResult {
        for activity in matchingActivities() {
            let currentState = activity.content.state
            guard let nextState = currentState.clearingPermissionResponse(
                sessionId: sessionId,
                requestId: requestId
            ) else {
                continue
            }
            let staleInterval: TimeInterval = activity.attributes.isLAN ? 30 * 60 : 5 * 60
            let nextStale = max(activity.content.staleDate ?? .distantPast, Date(timeIntervalSinceNow: staleInterval))
            await activity.update(
                ActivityContent(
                    state: nextState,
                    staleDate: nextStale,
                    relevanceScore: 100
                )
            )
        }
        return .result()
    }

    private func matchingActivities() -> [Activity<LodyConversationLiveActivityAttributes>] {
        return Activity<LodyConversationLiveActivityAttributes>.activities.filter {
            $0.attributes.activityId == activityId && ($0.activityState == .active || $0.activityState == .stale)
        }
    }
}

@available(iOS 17.0, iOSApplicationExtension 17.0, *)
private struct LodyLiveActivityPermissionRequestResult {
    let data: Data
    let response: URLResponse
}

@available(iOS 17.0, iOSApplicationExtension 17.0, *)
private extension LodyConversationLiveActivityAttributes.ContentState {
    func updatingPermissionResponse(
        sessionId: String,
        requestId: String,
        responseState: LodyPermissionResponseState
    ) -> LodyConversationLiveActivityAttributes.ContentState? {
        var nextItems = items
        guard let itemIndex = nextItems.firstIndex(where: {
            $0.id == sessionId && $0.permissionRequestId == requestId
        }) else {
            return nil
        }

        var item = nextItems[itemIndex]
        item.permissionResponseState = responseState
        item.statusLabel = responseState.liveActivityLabel
        item.updatedAt = Date().timeIntervalSince1970 * 1000
        item.updatedAtLabel = lodyLiveActivityLocalized("liveActivity.time.now")
        nextItems[itemIndex] = item

        return LodyConversationLiveActivityAttributes.ContentState(
            totalCount: totalCount,
            statusCounts: statusCounts,
            items: nextItems,
            updatedAt: Date().timeIntervalSince1970 * 1000,
            onesignal: onesignal
        )
    }

    func clearingPermissionResponse(
        sessionId: String,
        requestId: String
    ) -> LodyConversationLiveActivityAttributes.ContentState? {
        var nextItems = items
        guard let itemIndex = nextItems.firstIndex(where: {
            $0.id == sessionId && $0.permissionRequestId == requestId
        }) else {
            return nil
        }

        var item = nextItems[itemIndex]
        item.permissionResponseState = nil
        item.statusLabel = item.status.defaultLiveActivityLabel
        item.updatedAt = Date().timeIntervalSince1970 * 1000
        item.updatedAtLabel = lodyLiveActivityLocalized("liveActivity.time.now")
        nextItems[itemIndex] = item

        return LodyConversationLiveActivityAttributes.ContentState(
            totalCount: totalCount,
            statusCounts: statusCounts,
            items: nextItems,
            updatedAt: Date().timeIntervalSince1970 * 1000,
            onesignal: onesignal
        )
    }
}

@available(iOS 17.0, iOSApplicationExtension 17.0, *)
private extension LodyPermissionResponseState {
    var liveActivityLabel: String {
        lodyLiveActivityPermissionResponseShortLabel(self)
    }
}

@available(iOS 17.0, iOSApplicationExtension 17.0, *)
private extension LodyConversationActivityStatus {
    var defaultLiveActivityLabel: String {
        lodyLiveActivityStatusLabel(self)
    }
}

enum LodyLiveActivityPermissionIntentError: Error {
    case invalidAction
    case invalidResponse
    case rejected(Int)
    case timedOut
}
