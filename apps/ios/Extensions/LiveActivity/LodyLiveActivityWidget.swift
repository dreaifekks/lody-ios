import ActivityKit
import AppIntents
import Foundation
import SwiftUI
import WidgetKit

@main
struct LodyLiveActivityWidgetBundle: WidgetBundle {
    var body: some Widget {
        LodyLiveActivityWidget()
    }
}

struct LodyLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        return ActivityConfiguration(for: LodyConversationLiveActivityAttributes.self) { context in
            LodyActivityContentView(context: context)
                .activityBackgroundTint(LodyWidgetAppearance.background)
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            let isStale = context.isStale
            let leadStatus = context.state.items.first?.status ?? .unread
            let permissionItem = isStale ? nil : context.state.items.first { $0.status == .permission }
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    LodyActivityBrand(compact: true)
                        .padding(.leading, 10)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if isStale {
                        LodyStaleBadge()
                            .padding(.trailing, 10)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Group {
                        if let permissionItem {
                            LodyPermissionIslandCard(
                                item: permissionItem,
                                activityId: context.attributes.activityId,
                                workspaceId: context.attributes.workspaceId
                            )
                            .padding(.horizontal, 14)
                            .padding(.top, 2)
                        } else {
                            LodyConversationRows(
                                items: Array(context.state.items.prefix(3)),
                                isStale: isStale
                            )
                            .padding(.horizontal, 14)
                            .padding(.top, 4)
                        }
                    }
                    .opacity(isStale ? 0.72 : 1.0)
                }
            } compactLeading: {
                LodyCompactIslandMark(status: leadStatus, isStale: isStale)
            } compactTrailing: {
                if isStale {
                    Image(systemName: "wifi.slash")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.62))
                } else {
                    Text("\(context.state.totalCount)")
                        .font(.caption.weight(.bold))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                }
            } minimal: {
                LodyMinimalIslandMark(
                    status: leadStatus,
                    totalCount: context.state.totalCount,
                    isStale: isStale
                )
            }
            .keylineTint(isStale ? Color.white.opacity(0.35) : statusColor(leadStatus))
            .widgetURL(context.attributes.routeURL(for: context.state, preferredSessionId: permissionItem?.id))
        }
        .addLodySupplementalActivityFamilies()
    }
}

private extension ActivityConfiguration {
    func addLodySupplementalActivityFamilies() -> some WidgetConfiguration {
        // Keep this as an opaque-return helper with explicit returns: there is no
        // WidgetConfigurationBuilder, and inlining this branch makes body types diverge.
        if #available(iOSApplicationExtension 18.0, *) {
            return self.supplementalActivityFamilies([.small])
        } else {
            return self
        }
    }
}

private struct LodyActivityContentView: View {
    let context: ActivityViewContext<LodyConversationLiveActivityAttributes>

    var body: some View {
        if #available(iOSApplicationExtension 18.0, *) {
            LodySupplementalActivityView(context: context)
        } else {
            LodyLockScreenActivityView(context: context)
        }
    }
}

@available(iOSApplicationExtension 18.0, *)
private struct LodySupplementalActivityView: View {
    @Environment(\.activityFamily) private var activityFamily
    let context: ActivityViewContext<LodyConversationLiveActivityAttributes>

    var body: some View {
        switch activityFamily {
        case .small:
            if context.attributes.isLAN {
                LodyLanCompactActivityView(context: context)
            } else {
                LodyWatchSmallActivityView(context: context)
            }
        case .medium:
            LodyLockScreenActivityView(context: context)
        @unknown default:
            LodyLockScreenActivityView(context: context)
        }
    }
}

/// Compact Apple Watch / supplemental small card for LAN sessions: preserves focus details,
/// reasoning/activity steps, and direct permission buttons when a member requests approval.
@available(iOSApplicationExtension 18.0, *)
private struct LodyLanCompactActivityView: View {
    let context: ActivityViewContext<LodyConversationLiveActivityAttributes>

    private var focus: LodyConversationLiveActivityAttributes.ConversationItem? {
        context.state.items.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let focus {
                HStack(spacing: 5) {
                    if context.isStale {
                        Image(systemName: "wifi.slash")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.65))
                    } else {
                        LodyStatusDot(status: focus.status, size: 6)
                    }
                    Text(focus.title)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if let machine = focus.machineName, !machine.isEmpty {
                        Text(machine)
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.6))
                            .lineLimit(1)
                    }
                }
                if context.isStale {
                    Text(lodyLiveActivityLocalized("liveActivity.stale"))
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.65))
                        .lineLimit(1)
                } else if focus.status == .permission, focus.permissionRequestId != nil {
                    if let command = focus.permissionCommand, !command.isEmpty {
                        Text(command)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.84))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    if let responseState = focus.permissionResponseState {
                        LodyPermissionResponseFeedback(
                            state: responseState,
                            item: focus,
                            activityId: context.attributes.activityId
                        )
                    } else {
                        LodyPermissionActionButtons(
                            item: focus,
                            activityId: context.attributes.activityId,
                            workspaceId: context.attributes.workspaceId
                        )
                    }
                } else {
                    let detail = (focus.thought?.isEmpty == false ? focus.thought : focus.activity)
                    if let detail, !detail.isEmpty {
                        Text(detail)
                            .font(.system(size: 11, design: .rounded))
                            .foregroundStyle(.white.opacity(0.76))
                            .lineLimit(2)
                    } else {
                        Text(lodyLiveActivityConversationLabel(focus))
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(statusColor(focus.status))
                            .lineLimit(1)
                    }
                }
            } else {
                LodyWatchSmallActivityView(context: context)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .foregroundStyle(.white)
        .opacity(context.isStale ? 0.75 : 1.0)
        .widgetURL(context.attributes.routeURL(for: context.state))
    }
}

private struct LodyLockScreenActivityView: View {
    let context: ActivityViewContext<LodyConversationLiveActivityAttributes>

    private var lanPermissionItem: LodyConversationLiveActivityAttributes.ConversationItem? {
        guard context.attributes.isLAN, !context.isStale else { return nil }
        return context.state.items.first { $0.status == .permission && $0.permissionRequestId != nil }
    }

    private func listedItems(excluding permissionItem: LodyConversationLiveActivityAttributes.ConversationItem?) -> [LodyConversationLiveActivityAttributes.ConversationItem] {
        if let permissionItem {
            return Array(context.state.items.filter { $0.id != permissionItem.id }.prefix(3))
        }
        return Array(context.state.items.prefix(4))
    }

    var body: some View {
        let permissionItem = lanPermissionItem
        let rows = listedItems(excluding: permissionItem)
        let shownCount = rows.count + (permissionItem == nil ? 0 : 1)

        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                LodyActivityBrand(compact: false)
                Spacer(minLength: 6)
                if context.isStale {
                    LodyStaleBadge()
                }
            }

            if let permissionItem {
                LodyPermissionIslandCard(
                    item: permissionItem,
                    activityId: context.attributes.activityId,
                    workspaceId: context.attributes.workspaceId
                )
            }

            if !rows.isEmpty {
                LodyConversationRows(items: rows, isStale: context.isStale)
            }

            if context.state.totalCount > shownCount {
                Text(
                    String(
                        format: lodyLiveActivityLocalized("liveActivity.more"),
                        context.state.totalCount - shownCount
                    )
                )
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.white.opacity(0.54))
            }
        }
        .padding(16)
        .foregroundStyle(.white)
        .opacity(context.isStale ? 0.72 : 1.0)
        .widgetURL(context.attributes.routeURL(for: context.state, preferredSessionId: permissionItem?.id))
    }
}

@available(iOSApplicationExtension 18.0, *)
private struct LodyWatchSmallActivityView: View {
    let context: ActivityViewContext<LodyConversationLiveActivityAttributes>

    private var featuredItem: LodyConversationLiveActivityAttributes.ConversationItem? {
        context.state.items.first
    }

    private var counts: LodyResolvedStatusCounts {
        LodyResolvedStatusCounts(state: context.state)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Text("Lody")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .lineLimit(1)

                Spacer(minLength: 4)

                HStack(spacing: 4) {
                    LodyStatusDot(status: .running, size: 6)
                    Text("\(counts.running)")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .monospacedDigit()
                }
                .foregroundStyle(.white.opacity(0.86))
            }

            if let featuredItem {
                HStack(spacing: 4) {
                    LodyStatusDot(status: featuredItem.status, size: 6)
                    Text(lodyLiveActivityConversationLabel(featuredItem))
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(statusColor(featuredItem.status))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)

                    Text(featuredItem.title)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)
                }
            }

            HStack(spacing: 4) {
                LodyWatchCountCard(
                    label: lodyLiveActivityLocalized("liveActivity.count.permission"),
                    count: counts.waiting,
                    status: .permission
                )
                LodyWatchCountCard(
                    label: lodyLiveActivityLocalized("liveActivity.count.running"),
                    count: counts.running,
                    status: .running
                )
                LodyWatchCountCard(
                    label: lodyLiveActivityLocalized("liveActivity.count.unread"),
                    count: counts.unread,
                    status: .unread
                )
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .foregroundStyle(.white)
        .widgetURL(context.attributes.routeURL(for: context.state))
    }
}

private struct LodyWatchCountCard: View {
    let label: String
    let count: Int
    let status: LodyConversationActivityStatus

    var body: some View {
        HStack(spacing: 3) {
            Text(label)
                .font(.system(size: 8, weight: .semibold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text("\(count)")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, minHeight: 20)
        .padding(.horizontal, 4)
        .background(statusColor(status).opacity(count > 0 ? 0.26 : 0.12))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

private struct LodyResolvedStatusCounts {
    let waiting: Int
    let running: Int
    let unread: Int

    init(state: LodyConversationLiveActivityAttributes.ContentState) {
        let statusCounts = state.statusCounts
        waiting = statusCounts.permission + statusCounts.question
        running = statusCounts.running
        unread = statusCounts.unread
    }
}

private struct LodyPermissionIslandCard: View {
    let item: LodyConversationLiveActivityAttributes.ConversationItem
    let activityId: String
    let workspaceId: String

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            LodyPermissionConversationRow(item: item)

            if item.permissionRequestId != nil {
                LodyPermissionTerminalRow(item: item)
                if let responseState = item.permissionResponseState {
                    LodyPermissionResponseFeedback(
                        state: responseState,
                        item: item,
                        activityId: activityId
                    )
                } else {
                    LodyPermissionActionButtons(
                        item: item,
                        activityId: activityId,
                        workspaceId: workspaceId
                    )
                }
            }
        }
        .foregroundStyle(.white)
        .animation(.easeInOut(duration: 0.22), value: item.permissionResponseState)
    }
}

private struct LodyPermissionTerminalRow: View {
    let item: LodyConversationLiveActivityAttributes.ConversationItem

    var body: some View {
        HStack(spacing: 7) {
            ZStack {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(statusColor(.permission).opacity(0.17))

                Image(systemName: "terminal")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(statusColor(.permission))
            }
            .frame(width: 22, height: 18)
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .stroke(statusColor(.permission).opacity(0.35), lineWidth: 1)
            )

            if let command = normalizedCommand {
                Text(command)
                    .font(.caption2.monospaced().weight(.semibold))
                    .foregroundStyle(.white.opacity(0.88))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(1)
            }

            Spacer(minLength: 0)
        }
    }

    private var normalizedCommand: String? {
        guard let command = item.permissionCommand?.trimmingCharacters(in: .whitespacesAndNewlines),
              !command.isEmpty else {
            return nil
        }
        return command
    }
}

private struct LodyPermissionConversationRow: View {
    let item: LodyConversationLiveActivityAttributes.ConversationItem

    var body: some View {
        HStack(spacing: 7) {
            LodyAgentLogo(kind: item.agentLogoKind, text: item.agentLogoText)

            Text(item.title)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)

            Spacer(minLength: 0)
        }
    }
}

private struct LodyPermissionActionButtons: View {
    let item: LodyConversationLiveActivityAttributes.ConversationItem
    let activityId: String
    let workspaceId: String

    var body: some View {
        HStack(spacing: 8) {
            LodyPermissionActionLink(
                title: lodyLiveActivityLocalized("liveActivity.permission.action.reject"),
                systemImage: "xmark",
                action: "reject",
                item: item,
                activityId: activityId,
                workspaceId: workspaceId
            )

            LodyPermissionActionLink(
                title: lodyLiveActivityLocalized("liveActivity.permission.action.allow"),
                systemImage: "checkmark",
                action: "allow",
                item: item,
                activityId: activityId,
                workspaceId: workspaceId
            )
        }
        .padding(.top, 1)
    }
}

private struct LodyPermissionResponseFeedback: View {
    let state: LodyPermissionResponseState
    let item: LodyConversationLiveActivityAttributes.ConversationItem
    let activityId: String

    var body: some View {
        if isFailureState {
            if let requestId = normalizedRequestId,
               #available(iOSApplicationExtension 17.0, *) {
                Button(
                    intent: LodyLiveActivityPermissionFeedbackIntent(
                        activityId: activityId,
                        sessionId: item.id,
                        requestId: requestId
                    )
                ) {
                    feedbackContent
                }
                .buttonStyle(.plain)
            } else {
                feedbackContent
            }
        } else {
            feedbackContent
        }
    }

    private var feedbackContent: some View {
        HStack(spacing: 7) {
            LodyPermissionResponseIcon(state: state)

            Text(feedbackLabel)
                .font(.caption2.weight(.heavy))
                .lineLimit(1)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: 26)
        .padding(.horizontal, 10)
        .foregroundStyle(feedbackColor)
        .background(Capsule().fill(feedbackColor.opacity(0.16)))
        .overlay(Capsule().stroke(feedbackColor.opacity(0.34), lineWidth: 1))
        .transition(.opacity.combined(with: .scale(scale: 0.98)))
    }

    private var isFailureState: Bool {
        switch state {
        case .failed, .timedOut:
            return true
        case .sending, .allowed, .rejected:
            return false
        }
    }

    private var normalizedRequestId: String? {
        guard let requestId = item.permissionRequestId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !requestId.isEmpty else {
            return nil
        }
        return requestId
    }

    private var feedbackLabel: String {
        switch state {
        case .sending:
            return lodyLiveActivityLocalized("liveActivity.permission.response.sending")
        case .allowed:
            return lodyLiveActivityLocalized("liveActivity.permission.response.allowed")
        case .rejected:
            return lodyLiveActivityLocalized("liveActivity.permission.response.rejected")
        case .failed:
            return lodyLiveActivityLocalized("liveActivity.permission.response.failed")
        case .timedOut:
            return lodyLiveActivityLocalized("liveActivity.permission.response.timedOut")
        }
    }

    private var feedbackColor: Color {
        switch state {
        case .sending:
            return statusColor(.permission)
        case .allowed:
            return Color(red: 0.24, green: 0.84, blue: 0.50)
        case .rejected:
            return Color.white.opacity(0.84)
        case .failed, .timedOut:
            return Color(red: 1.0, green: 0.38, blue: 0.32)
        }
    }
}

private struct LodyPermissionResponseIcon: View {
    let state: LodyPermissionResponseState

    var body: some View {
        Group {
            switch state {
            case .sending:
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(statusColor(.permission))
                    .scaleEffect(0.58)
                    .frame(width: 14, height: 14)
            case .allowed:
                Image(systemName: "checkmark.circle.fill")
            case .rejected:
                Image(systemName: "xmark.circle.fill")
            case .failed, .timedOut:
                Image(systemName: "exclamationmark.triangle.fill")
            }
        }
        .font(.system(size: 12, weight: .heavy))
        .frame(width: 14, height: 14)
    }
}

private struct LodyPermissionActionLink: View {
    let title: String
    let systemImage: String
    let action: String
    let item: LodyConversationLiveActivityAttributes.ConversationItem
    let activityId: String
    let workspaceId: String

    var body: some View {
        if let requestId = normalizedRequestId {
            if #available(iOSApplicationExtension 17.0, *) {
                let resolvedOption = action == "allow" ? (item.allowOption?.id ?? "") : (item.denyOption?.id ?? "")
                Button(
                    intent: LodyLiveActivityPermissionResponseIntent(
                        activityId: activityId,
                        workspaceId: workspaceId,
                        sessionId: item.id,
                        requestId: requestId,
                        action: action,
                        optionId: resolvedOption
                    )
                ) {
                    label
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var normalizedRequestId: String? {
        guard let requestId = item.permissionRequestId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !requestId.isEmpty else {
            return nil
        }
        return requestId
    }

    private var label: some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
                .font(.system(size: 9, weight: .heavy))
            Text(title)
                .font(.caption2.weight(.heavy))
        }
        .lineLimit(1)
        .frame(maxWidth: .infinity, minHeight: 26)
        .foregroundStyle(action == "allow" ? Color.black : Color.white)
        .background(
            Capsule().fill(
                action == "allow"
                    ? statusColor(.permission)
                    : Color.white.opacity(0.13)
            )
        )
        .overlay(
            Capsule().stroke(
                action == "allow"
                    ? Color.clear
                    : Color.white.opacity(0.22),
                lineWidth: 1
            )
        )
    }
}

private struct LodyMiniConversationRow: View {
    let item: LodyConversationLiveActivityAttributes.ConversationItem

    var body: some View {
        HStack(spacing: 6) {
            LodyStatusDot(status: item.status, size: 6)
            Text(lodyLiveActivityConversationLabel(item))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(statusColor(item.status))
                .lineLimit(1)

            Text(item.title)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.white.opacity(0.74))
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 6)

            Text(item.updatedAtLabel)
                .font(.caption2.monospacedDigit().weight(.medium))
                .foregroundStyle(.white.opacity(0.46))
                .lineLimit(1)
        }
    }
}

private struct LodyActivityBrand: View {
    let compact: Bool

    var body: some View {
        HStack(spacing: compact ? 6 : 8) {
            LodyLogoMark(size: compact ? 17 : 22)
            Text("Lody")
                .font((compact ? Font.caption : Font.title3).weight(.bold))
                .foregroundStyle(.white)
                .lineLimit(1)
        }
    }
}

private struct LodyStaleBadge: View {
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "wifi.slash")
                .font(.system(size: 10, weight: .semibold))
            Text(lodyLiveActivityLocalized("liveActivity.stale"))
                .font(.caption2.weight(.medium))
                .lineLimit(1)
        }
        .foregroundStyle(.white.opacity(0.68))
    }
}

private struct LodyCompactIslandMark: View {
    let status: LodyConversationActivityStatus
    var isStale: Bool = false

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            LodyLogoMark(size: 17)
                .opacity(isStale ? 0.65 : 1.0)

            if !isStale {
                LodyStatusDot(status: status, size: 5)
                    .background(Circle().fill(.black))
                    .offset(x: -1, y: -1)
            }
        }
        .frame(width: 22, height: 20)
    }
}

private struct LodyMinimalIslandMark: View {
    let status: LodyConversationActivityStatus
    let totalCount: Int
    var isStale: Bool = false

    var body: some View {
        if isStale {
            Image(systemName: "wifi.slash")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.65))
                .frame(width: 22, height: 22)
        } else {
            ZStack(alignment: .bottomTrailing) {
                LodyLogoMark(size: 16)
                    .padding(2)
                    .background(Circle().fill(.white.opacity(0.10)))
                    .overlay(Circle().stroke(statusColor(status), lineWidth: 1.2))
                    .frame(width: 22, height: 22)

                Text(minimalCountLabel(totalCount))
                    .font(.system(size: 6.5, weight: .black, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.black)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .padding(.horizontal, 2)
                    .frame(minWidth: 10, minHeight: 9)
                    .background(Capsule().fill(statusColor(status)))
                    .offset(x: -1, y: -1)
            }
            .frame(width: 28, height: 28)
        }
    }
}

private struct LodyConversationRows: View {
    let items: [LodyConversationLiveActivityAttributes.ConversationItem]
    var isStale: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(items, id: \.id) { item in
                LodyConversationRow(item: item, isStale: isStale)
            }
        }
    }
}

private struct LodyConversationRow: View {
    let item: LodyConversationLiveActivityAttributes.ConversationItem
    var isStale: Bool = false

    private var secondaryDetail: String? {
        let machine = item.machineName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let runningText: String?
        if item.status == .running {
            if let activity = item.activity?.trimmingCharacters(in: .whitespacesAndNewlines), !activity.isEmpty {
                runningText = activity
            } else if let thought = item.thought?.trimmingCharacters(in: .whitespacesAndNewlines), !thought.isEmpty {
                runningText = thought
            } else {
                runningText = nil
            }
        } else {
            runningText = nil
        }
        let parts = [machine, runningText].compactMap { value -> String? in
            guard let value, !value.isEmpty else { return nil }
            return value
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 7) {
                LodyStatusDot(status: item.status)
                Text(lodyLiveActivityConversationLabel(item))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(statusColor(item.status))
                    .frame(width: 54, alignment: .leading)
                    .lineLimit(1)

                LodyAgentLogo(kind: item.agentLogoKind, text: item.agentLogoText)

                Text(item.title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(0)

                Spacer(minLength: 6)

                LodyConversationTrailingTime(item: item, isStale: isStale)
            }
            if let detail = secondaryDetail {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.64))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.leading, 69)
            }
        }
    }
}

private struct LodyConversationTrailingTime: View {
    let item: LodyConversationLiveActivityAttributes.ConversationItem
    let isStale: Bool

    private var isActiveStatus: Bool {
        item.status == .running || item.status == .permission || item.status == .question
    }

    var body: some View {
        if !item.updatedAtLabel.isEmpty {
            Text(item.updatedAtLabel)
                .font(.caption2.monospacedDigit().weight(.medium))
                .foregroundStyle(.white.opacity(0.56))
                .frame(minWidth: 58, alignment: .trailing)
                .lineLimit(1)
                .layoutPriority(2)
        } else if let startedAt = item.startedAt, startedAt > 0 {
            let startDate = Date(timeIntervalSince1970: startedAt / 1000)
            if let completedAt = item.completedAt, completedAt >= startedAt {
                let endDate = Date(timeIntervalSince1970: completedAt / 1000)
                Text(timerInterval: startDate...max(endDate, startDate), pauseTime: endDate, countsDown: false)
                    .font(.caption2.monospacedDigit().weight(.medium))
                    .foregroundStyle(.white.opacity(0.56))
                    .multilineTextAlignment(.trailing)
                    .frame(width: 48, alignment: .trailing)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .layoutPriority(2)
            } else if !isStale, isActiveStatus {
                // Bound the timer text width so an open-ended interval never pushes the title off screen.
                Text(timerInterval: startDate...Date.distantFuture, countsDown: false)
                    .font(.caption2.monospacedDigit().weight(.medium))
                    .foregroundStyle(.white.opacity(0.56))
                    .multilineTextAlignment(.trailing)
                    .frame(width: 48, alignment: .trailing)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .layoutPriority(2)
            }
        }
    }
}

private struct LodyStatusDot: View {
    let status: LodyConversationActivityStatus
    var size: CGFloat = 8

    var body: some View {
        Circle()
            .fill(statusColor(status))
            .frame(width: size, height: size)
            .shadow(color: statusColor(status).opacity(0.55), radius: 4, x: 0, y: 0)
    }
}

private func statusColor(_ status: LodyConversationActivityStatus) -> Color {
    switch status {
    case .permission:
        return LodyWidgetAppearance.waiting
    case .question:
        return Color(red: 0.50, green: 0.68, blue: 1.0)
    case .running:
        return LodyWidgetAppearance.running
    case .unread:
        return LodyWidgetAppearance.unread
    case .failed:
        return Color(red: 1.0, green: 0.38, blue: 0.32)
    }
}

private func minimalCountLabel(_ count: Int) -> String {
    if count > 9 {
        return "9+"
    }
    return "\(max(0, count))"
}
