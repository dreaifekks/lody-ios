import Foundation
import ActivityKit
@preconcurrency import OneSignalLiveActivities

@available(iOS 16.1, *)
public enum LodyConversationActivityStatus: String, Codable, Hashable, Sendable {
    case permission
    case question
    case running
    case unread
    case failed
}

@available(iOS 16.1, *)
public enum LodyPermissionResponseState: String, Codable, Hashable, Sendable {
    case sending
    case allowed
    case rejected
    case failed
    case timedOut
}

@available(iOS 16.1, *)
public struct LodyConversationLiveActivityAttributes: OneSignalLiveActivityAttributes, Sendable {
    public struct PermissionOption: Codable, Hashable, Sendable {
        public var id: String
        public var label: String
        public var kind: String

        public var allows: Bool { kind.hasPrefix("allow") }

        public init(id: String, label: String, kind: String) {
            self.id = id
            self.label = label
            self.kind = kind
        }
    }

    public struct ConversationItem: Codable, Hashable, Sendable {
        public var id: String
        public var status: LodyConversationActivityStatus
        public var statusLabel: String
        public var permissionRequestId: String?
        public var permissionCommand: String?
        public var permissionResponseState: LodyPermissionResponseState?
        public var agentLogoKind: String
        public var agentLogoText: String
        public var title: String
        public var updatedAt: Double
        public var updatedAtLabel: String
        public var startedAt: Double?
        public var completedAt: Double?
        public var machineName: String?
        public var activity: String?
        public var thought: String?
        public var permissionOptions: [PermissionOption]?

        public var allowOption: PermissionOption? { option(prefix: "allow") }
        public var denyOption: PermissionOption? { option(prefix: "reject") }

        private func option(prefix: String) -> PermissionOption? {
            let options = (permissionOptions ?? []).filter { $0.kind.hasPrefix(prefix) }
            return options.first { $0.kind.hasSuffix("_once") } ?? options.first
        }

        public init(
            id: String,
            status: LodyConversationActivityStatus,
            statusLabel: String,
            permissionRequestId: String? = nil,
            permissionCommand: String? = nil,
            permissionResponseState: LodyPermissionResponseState? = nil,
            agentLogoKind: String,
            agentLogoText: String,
            title: String,
            updatedAt: Double,
            updatedAtLabel: String,
            startedAt: Double? = nil,
            completedAt: Double? = nil,
            machineName: String? = nil,
            activity: String? = nil,
            thought: String? = nil,
            permissionOptions: [PermissionOption]? = nil
        ) {
            self.id = id
            self.status = status
            self.statusLabel = statusLabel
            self.permissionRequestId = permissionRequestId
            self.permissionCommand = permissionCommand
            self.permissionResponseState = permissionResponseState
            self.agentLogoKind = agentLogoKind
            self.agentLogoText = agentLogoText
            self.title = title
            self.updatedAt = updatedAt
            self.updatedAtLabel = updatedAtLabel
            self.startedAt = startedAt
            self.completedAt = completedAt
            self.machineName = machineName
            self.activity = activity
            self.thought = thought
            self.permissionOptions = permissionOptions
        }
    }

    public struct ContentState: Codable, Hashable, Sendable, OneSignalLiveActivityContentState {
        public struct StatusCounts: Codable, Hashable, Sendable {
            public var permission: Int
            public var question: Int
            public var running: Int
            public var unread: Int

            public init(permission: Int = 0, question: Int = 0, running: Int = 0, unread: Int = 0) {
                self.permission = permission
                self.question = question
                self.running = running
                self.unread = unread
            }

            public init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                permission = try container.decodeIfPresent(Int.self, forKey: .permission) ?? 0
                question = try container.decodeIfPresent(Int.self, forKey: .question) ?? 0
                running = try container.decodeIfPresent(Int.self, forKey: .running) ?? 0
                unread = try container.decodeIfPresent(Int.self, forKey: .unread) ?? 0
            }
        }

        public var totalCount: Int
        public var statusCounts: StatusCounts
        public var items: [ConversationItem]
        public var updatedAt: Double
        public var onesignal: OneSignalLiveActivityContentStateData?

        public init(
            totalCount: Int,
            statusCounts: StatusCounts,
            items: [ConversationItem],
            updatedAt: Double,
            onesignal: OneSignalLiveActivityContentStateData? = nil
        ) {
            self.totalCount = totalCount
            self.statusCounts = statusCounts
            self.items = items
            self.updatedAt = updatedAt
            self.onesignal = onesignal
        }

        private enum CodingKeys: String, CodingKey {
            case totalCount, statusCounts, items, updatedAt, onesignal
        }

        public init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            totalCount = try values.decode(Int.self, forKey: .totalCount)
            statusCounts = try values.decode(StatusCounts.self, forKey: .statusCounts)
            items = try values.decode([ConversationItem].self, forKey: .items)
            updatedAt = try values.decodeIfPresent(Double.self, forKey: .updatedAt) ?? 0
            onesignal = try values.decodeIfPresent(OneSignalLiveActivityContentStateData.self, forKey: .onesignal)
        }
    }

    public var activityId: String
    public var workspaceId: String
    public var workspaceSlug: String?
    public var workspaceName: String
    public var onesignal: OneSignalLiveActivityAttributeData

    public var isLAN: Bool { workspaceId.hasPrefix("lw_") }

    /// Deep-link route opened when the user taps the Dynamic Island or Lock Screen card.
    public func routeURL(for state: ContentState, preferredSessionId: String? = nil) -> URL {
        let fallback = URL(string: "lody:///activity")!
        let targetId = preferredSessionId ?? state.items.first?.id
        guard let targetId,
              let session = Self.encodedPathSegment(targetId) else {
            return fallback
        }
        let rawSlug = workspaceSlug?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let resolvedSlug: String
        if !rawSlug.isEmpty {
            resolvedSlug = rawSlug
        } else if isLAN {
            resolvedSlug = "lan"
        } else {
            resolvedSlug = workspaceId
        }
        guard let workspace = Self.encodedPathSegment(resolvedSlug),
              let url = URL(string: "lody://\(workspace)/sessions/\(session)") else {
            return fallback
        }
        return url
    }

    private static let routeSegmentAllowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))

    private static func encodedPathSegment(_ raw: String) -> String? {
        guard !raw.isEmpty, raw != ".", raw != "..",
              !raw.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 || $0 == "/" || $0 == "\\" }) else {
            return nil
        }
        return raw.addingPercentEncoding(withAllowedCharacters: routeSegmentAllowed)
    }

    public init(
        activityId: String,
        workspaceId: String,
        workspaceSlug: String? = nil,
        workspaceName: String,
        onesignal: OneSignalLiveActivityAttributeData
    ) {
        self.activityId = activityId
        self.workspaceId = workspaceId
        self.workspaceSlug = workspaceSlug
        self.workspaceName = workspaceName
        self.onesignal = onesignal
    }

    // Direct APNs and LAN starts have no vendor envelope, and LAN hubs may send
    // `userId` in place of `activityId`. Preserve the common ActivityKit wire type.
    private enum CodingKeys: String, CodingKey {
        case activityId, workspaceId, workspaceSlug, workspaceName, userId, onesignal
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        workspaceId = try values.decode(String.self, forKey: .workspaceId)
        workspaceSlug = try values.decodeIfPresent(String.self, forKey: .workspaceSlug)
        workspaceName = try values.decode(String.self, forKey: .workspaceName)
        if let wireId = try values.decodeIfPresent(String.self, forKey: .activityId), !wireId.isEmpty {
            activityId = wireId
        } else {
            let userId = try values.decode(String.self, forKey: .userId)
            activityId = "lody-conversations:v5:\(workspaceId):\(userId)"
        }
        onesignal = try values.decodeIfPresent(OneSignalLiveActivityAttributeData.self, forKey: .onesignal)
            ?? OneSignalLiveActivityAttributeData.create(activityId: activityId)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(activityId, forKey: .activityId)
        try container.encode(workspaceId, forKey: .workspaceId)
        try container.encodeIfPresent(workspaceSlug, forKey: .workspaceSlug)
        try container.encode(workspaceName, forKey: .workspaceName)
        try container.encode(onesignal, forKey: .onesignal)
    }
}
