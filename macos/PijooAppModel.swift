import AppKit
import AuthenticationServices
import Combine
import CryptoKit
import Darwin
import Foundation
import Security
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

private final class AccountAuthenticationContext: NSObject, ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApp.keyWindow ?? NSApp.windows.first ?? NSWindow()
    }
}

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published var state: AppStateV2
    @Published var selectedChannelID: UUID?
    @Published var messages: [ChannelMessageRecord] = []
    @Published var members: [ChannelMember] = []
    @Published var invitations: [ChannelInvite] = []
    @Published var listenerStatus: [UUID: String] = [:]
    @Published var channelStatus: [UUID: String] = [:]
    @Published var lastError = "" {
        didSet {
            if !lastError.isEmpty, lastError != oldValue {
                ClientLog.record("error", "ui_error", detail: lastError)
            }
        }
    }
    @Published var busy = false
    @Published var launchAtLogin = false
    @Published var codexIntegrationStatus = "未启用"
    @Published private(set) var codexIntegrationConfigured = false
    @Published var codexIntegrationNeedsRestart = false
    @Published var loadedCodexMCPVersion = UserDefaults.standard.string(forKey: loadedCodexMCPVersionKey)
    @Published var updateStatus = "未检查"
    @Published var automaticUpdateChecks = UserDefaults.standard.bool(forKey: automaticUpdateChecksKey)
    @Published var draftNickname = ""
    @Published var draftChannelName = ""
    @Published var invitationInput = ""
    @Published var draftTask = ""
    @Published var selectedHostProvider = HostProviderChoice.codex
    @Published var conversationSearchResults: [HostConversationSummary] = []
    @Published var conversationSearchStatus = ""
    @Published private(set) var taskCreationStatus = ""
    @Published var hostConversationStates: [UUID: HostConversationRuntimeState] = [:]
    @Published private(set) var recoveryPendingMessageCount = 0
    @Published var composerText = ""
    @Published var composerMentionAll = false
    @Published var composerMentionMemberIDs: [String] = []
    @Published var showAddChannel = false
    @Published var oldBetaDataDetected = FileManager.default.fileExists(atPath: AppPaths.legacyBinding.path)
    @Published private(set) var accountFeatureAvailable = false
    @Published private(set) var accountSession: PijooAccountSession?
    @Published private(set) var accountStatus = "正在检查账号服务…"
    @Published private(set) var accountBusy = false

    private var listeners: [UUID: SubscriptionListener] = [:]
    private var startingListeners: Set<UUID> = []
    private var automaticallyReconnectingTaskIDs: Set<UUID> = []
    private var listenerGenerations: [UUID: Int] = [:]
    private var bridgeErrorKinds: [UUID: String] = [:]
    private var bridgeErrorMessages: [UUID: String] = [:]
    private var bridgeConnectionEscalations: [UUID: UUID] = [:]
    private var presentedBridgeError: String?
    private var feedTasks: [UUID: Task<Void, Never>] = [:]
    private var recoveryPausedSubscriptionIDs: Set<UUID> = []
    private var sleepStartedAt: Date?
    private var localSendServer: LocalSendServer?
    private var updateTimer: Timer?
    private let accountAuthenticationContext = AccountAuthenticationContext()
    private var accountAuthenticationSession: ASWebAuthenticationSession?

    private init() {
        try? AppPaths.prepare()
        var loaded = Self.loadState()
        Self.recoverDeliveryState(&loaded)
        if loaded.defaultCallsign.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            loaded.defaultCallsign = generatedLocalNickname()
        }
        state = loaded
        selectedChannelID = state.selectedChannelID ?? state.channels.first?.id
        draftNickname = state.defaultCallsign
        launchAtLogin = SMAppService.mainApp.status == .enabled
        ClientLog.record(
            "info",
            "app_started",
            detail: "version=\(currentVersion) os=\(ProcessInfo.processInfo.operatingSystemVersionString)"
        )
        persistState()
        refreshCodexIntegrationStatus()
        refreshSelectedChannel()
        if let installError = UpdateCoordinator.consumeInstallError() {
            updateStatus = "安装失败"
            DispatchQueue.main.async { [weak self] in self?.showNotice(title: "更新安装失败", message: installError) }
        } else {
            do {
                if try UpdateCoordinator.launchInstallerIfNeeded(currentVersion: currentVersion) {
                    updateStatus = "正在安装更新…"
                    return
                }
            } catch {
                updateStatus = error.localizedDescription
            }
        }
        do {
            let server = LocalSendServer(socketURL: AppPaths.sendSocket) { [weak self] request in
                guard let self else { return .failure("Pijoo app is unavailable") }
                return await self.handleLocalRequest(request)
            }
            try server.start()
            localSendServer = server
        } catch {
            lastError = "本机 MCP 服务启动失败：\(error.localizedDescription)"
        }
        showCodexRestartNoticeIfNeeded()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            for channel in self.state.channels { self.startChannelFeed(channel.id) }
            for subscription in self.state.subscriptions where subscription.enabled {
                Task { await self.startListener(subscription.id) }
            }
            self.configureAutomaticUpdateChecks()
            Task { await self.refreshAccount() }
        }
    }

    var currentVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "PijooReleaseVersion") as? String)
            ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
            ?? "0.0.0"
    }

    var selectedChannel: ChannelProfile? {
        guard let selectedChannelID else { return nil }
        return state.channels.first { $0.id == selectedChannelID }
    }

    var selectedSubscriptions: [ChannelSubscription] {
        guard let selectedChannelID else { return [] }
        return state.subscriptions.filter { $0.channelID == selectedChannelID }
    }

    var activeMentionMembers: [ChannelMember] { members.filter { $0.status == "active" } }
    var composerMentionLabel: String {
        if composerMentionAll { return "所有人" }
        let selected = composerMentionMemberIDs.compactMap { id in activeMentionMembers.first { $0.memberID == id } }
        if selected.count == 1 { return selected[0].name }
        if selected.count > 1 { return "\(selected[0].name)等\(selected.count)人" }
        return composerMentionMemberIDs.isEmpty ? "" : "已选 \(composerMentionMemberIDs.count) 人"
    }

    private var composerMentions: [String] {
        composerMentionAll ? ["all"] : composerMentionMemberIDs
    }

    private var composerMentionSnapshot: MessageMention? {
        if composerMentionAll { return MessageMention(kind: "all") }
        let selected = composerMentionMemberIDs.compactMap { id in
            activeMentionMembers.first(where: { $0.memberID == id }).map {
                MentionedMember(memberID: $0.memberID, memberName: $0.name)
            }
        }
        return selected.isEmpty ? nil : MessageMention(kind: "members", members: selected)
    }

    func clearComposerMentions() {
        composerMentionAll = false
        composerMentionMemberIDs = []
    }

    func toggleComposerMentionAll() {
        composerMentionAll.toggle()
        composerMentionMemberIDs = []
    }

    func toggleComposerMention(_ memberID: String) {
        composerMentionAll = false
        if let index = composerMentionMemberIDs.firstIndex(of: memberID) {
            composerMentionMemberIDs.remove(at: index)
        } else if composerMentionMemberIDs.count < 100 {
            composerMentionMemberIDs.append(memberID)
        }
    }

    var menuIcon: String { lastError.isEmpty ? "paperplane.circle" : "exclamationmark.triangle.fill" }
    var runningListenerCount: Int { listeners.count }
    var enabledSubscriptionCount: Int { state.subscriptions.filter(\.enabled).count }
    var disconnectedConversationTaskIDs: [UUID] {
        disconnectedHostTaskIDs(
            tasks: state.tasks,
            subscriptions: state.subscriptions,
            states: hostConversationStates
        )
    }
    var disconnectedConversationCount: Int { disconnectedConversationTaskIDs.count }
    func channelHasDisconnectedConversation(_ channelID: UUID) -> Bool {
        !disconnectedHostTaskIDs(
            tasks: state.tasks,
            subscriptions: state.subscriptions.filter { $0.channelID == channelID },
            states: hostConversationStates
        ).isEmpty
    }
    var codexReadiness: CodexIntegrationReadiness {
        codexIntegrationReadiness(
            configured: codexIntegrationConfigured,
            appVersion: currentVersion,
            loadedMCPVersion: loadedCodexMCPVersion
        )
    }
    var codexIntegrationReady: Bool { codexReadiness == .ready }
    var codexIntegrationBlockingTitle: String {
        codexReadiness == .notConfigured ? "先配置 Codex 集成" : "需要重启 ChatGPT"
    }
    var codexIntegrationBlockingMessage: String {
        switch codexReadiness {
        case .notConfigured:
            return "连接 AI 会话前，需要先安装 Pijoo MCP 与 Skill。"
        case .awaitingRestart:
            return "配置已写入。请完全退出并重新打开 ChatGPT，加载 Pijoo MCP \(currentVersion) 后再连接会话。"
        case .versionMismatch:
            return "ChatGPT 仍在使用 MCP \(loadedCodexMCPVersion ?? "未知版本")。请完全退出并重新打开 ChatGPT，加载 \(currentVersion) 后再连接会话。"
        case .ready:
            return ""
        }
    }

    func selectChannel(_ id: UUID?) {
        clearComposerMentions()
        selectedChannelID = id
        state.selectedChannelID = id
        persistState()
        refreshSelectedChannel()
    }

    func refreshSelectedChannel() {
        messages = selectedChannelID.map(MessageLedger.load) ?? []
        markSelectedChannelRead()
        members = []
        invitations = []
        if selectedChannelID != nil {
            Task {
                async let history: Void = refreshHistory()
                async let members: Void = refreshMembers()
                async let invitations: Void = refreshInvitations()
                _ = await (history, members, invitations)
            }
        }
    }

    private static func loadState() -> AppStateV2 {
        guard let data = try? Data(contentsOf: AppPaths.state),
              let decoded = try? JSONDecoder().decode(AppStateV2.self, from: data),
              decoded.version == 2 else { return AppStateV2() }
        return decoded
    }

    private static func recoverDeliveryState(_ state: inout AppStateV2) {
        for index in state.subscriptions.indices {
            let deliveries = MessageLedger.loadDeliveries(state.subscriptions[index].id)
            recoverSubscriptionDeliveryState(&state.subscriptions[index], deliveries: deliveries)
        }
    }

    private func persistState() {
        do {
            try persistStateOrThrow()
        } catch {
            lastError = "保存本机配置失败：\(error.localizedDescription)"
        }
    }

    private func persistStateOrThrow() throws {
        try AppPaths.prepare()
        state.selectedChannelID = selectedChannelID
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(state).write(to: AppPaths.state, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: AppPaths.state.path)
    }

    private func reconcileChannelMemberIdentity(
        _ profile: ChannelProfile,
        authenticatedMemberID: String
    ) throws -> ChannelProfile {
        guard let index = state.channels.firstIndex(where: { $0.id == profile.id }) else {
            throw AppFailure("频道本机配置不存在")
        }
        let previous = state.channels[index]
        let reconciled = try reconciledChannelProfile(previous, authenticatedMemberID: authenticatedMemberID)
        guard reconciled != previous else { return previous }
        state.channels[index] = reconciled
        do {
            try persistStateOrThrow()
        } catch {
            state.channels[index] = previous
            throw error
        }
        return reconciled
    }

    func unreadCount(_ channelID: UUID) -> Int {
        let lastViewed = state.channels.first(where: { $0.id == channelID })?.lastViewedMessageID ?? 0
        return MessageLedger.load(channelID).filter {
            $0.direction == .inbound && (Int64($0.messageID) ?? 0) > lastViewed
        }.count
    }

    private func markSelectedChannelRead() {
        guard let selectedChannelID,
              let latest = messages.compactMap({ Int64($0.messageID) }).max(),
              let index = state.channels.firstIndex(where: { $0.id == selectedChannelID }),
              latest > (state.channels[index].lastViewedMessageID ?? 0) else { return }
        state.channels[index].lastViewedMessageID = latest
        persistState()
    }
}

extension AppModel {
    fileprivate func handleLocalRequest(_ request: LocalSendRequest) async -> LocalSendResponse {
        do {
            switch request.operation {
            case "mcp_ready":
                guard let version = request.clientVersion else { throw AppFailure("client_version is required") }
                recordLoadedCodexMCPVersion(version)
                return .success(LocalOperationResult(message: "MCP \(version) 已加载"))
            case "list_channels":
                let task = taskBinding(for: request.sourceContext)
                let profiles = request.channel == nil ? state.channels : [try resolveChannel(request.channel)]
                let channels = profiles.map { profile in
                    let subscription = task.flatMap { task in
                        state.subscriptions.first { $0.channelID == profile.id && $0.taskID == task.id }
                    }
                    return LocalChannelSummary(
                        channel: profile.channel,
                        name: profile.displayName,
                        role: profile.role,
                        subscribed: subscription?.enabled == true,
                        defaultSend: subscription?.defaultSend == true
                    )
                }
                if let channel = request.channel {
                    let profile = try resolveChannel(channel)
                    let json = try await authorizedJSON(profile, suffix: "members", method: "GET")
                    guard let raw = json["members"], JSONSerialization.isValidJSONObject(raw) else {
                        throw AppFailure("频道成员响应无效")
                    }
                    let data = try JSONSerialization.data(withJSONObject: raw)
                    let members = try JSONDecoder().decode([ChannelMember].self, from: data)
                        .filter { $0.status == "active" }
                        .map { LocalMentionMemberSummary(
                            memberID: $0.memberID,
                            name: $0.name,
                            isSelf: $0.memberID == profile.memberID
                        ) }
                    return .success(LocalOperationResult(
                        channel: profile.channel,
                        channels: channels,
                        members: members,
                        message: "\(profile.displayName) 有 \(members.count) 名可 @ 成员"
                    ))
                }
                return .success(LocalOperationResult(channels: channels))
            case "inspect_message_source":
                guard let task = taskBinding(for: request.sourceContext),
                      let record = latestDeliveredChannelMessage(
                          taskID: task.id,
                          subscriptions: state.subscriptions,
                          deliveries: MessageLedger.loadDeliveries,
                          messages: MessageLedger.load
                      ),
                      let profile = state.channels.first(where: { $0.id == record.channelID }) else {
                    return .success(LocalOperationResult(
                        provenance: .notFound,
                        message: "当前会话没有可追溯的已投递 Pijoo 消息；这不证明其他消息一定是用户手动输入"
                    ))
                }
                let sourceKind: String
                switch record.source?.provider {
                case "pijoo": sourceKind = "pijoo_app"
                case "codex": sourceKind = "codex_mcp"
                default: sourceKind = "unknown"
                }
                return .success(LocalOperationResult(
                    provenance: LocalMessageProvenance(
                        found: true,
                        origin: "pijoo",
                        channel: profile.channel,
                        channelName: profile.displayName,
                        messageID: record.messageID,
                        senderName: record.from,
                        senderMemberID: record.senderMemberID,
                        senderEndpointID: record.senderEndpointID,
                        sourceKind: sourceKind,
                        sourceProvider: record.source?.provider,
                        sourceConversationID: record.source?.conversationID,
                        sourceLabel: record.source?.label,
                        receivedAt: record.at
                    ),
                    message: "最近一条已投递消息来自 Pijoo：\(profile.displayName) #\(record.messageID)，发送者 \(record.from)"
                ))
            case "send":
                guard let message = request.message else { throw AppFailure("message is required") }
                let (task, subscription, profile) = try outboundRoute(source: request.sourceContext, channel: request.channel)
                let sourceLabel = task.map { taskLabel($0.id) }
                    ?? "\(hostDisplayName(request.sourceContext.provider)) · \(request.sourceContext.conversationId.prefix(8))…"
                let source = MessageSourceReference(
                    provider: request.sourceContext.provider,
                    conversationID: request.sourceContext.conversationId,
                    label: sourceLabel
                )
                let endpoint = endpointCallsign(profile, conversationID: request.sourceContext.conversationId, kind: "t")
                do {
                    let receipt = try await sendChannelMessage(
                        message,
                        profile: profile,
                        endpoint: endpoint,
                        source: source,
                        mentions: request.mentions ?? []
                    )
                    upsertMessage(ChannelMessageRecord(
                        channelID: profile.id,
                        messageID: receipt.id,
                        direction: .outbound,
                        from: state.defaultCallsign,
                        to: "all",
                        text: message,
                        at: Date().timeIntervalSince1970 * 1000,
                        state: .accepted,
                        senderMemberID: receipt.memberID,
                        senderEndpointID: receipt.endpointID,
                        source: source,
                        mention: receipt.mention
                    ))
                    let confirmation = renderMessageTemplate(
                        subscription?.sentMessageTemplate ?? defaultSentMessageTemplate,
                        channelName: profile.displayName,
                        senderName: state.defaultCallsign,
                        messageSource: sourceLabel,
                        messageText: message,
                        messageID: receipt.id,
                        mentions: receipt.mention?.displayText ?? "无"
                    )
                    return .success(.send(
                        id: receipt.id,
                        callsign: receipt.callsign,
                        channel: profile.channel,
                        message: confirmation
                    ))
                } catch let error as ChannelSendFailure {
                    switch error {
                    case .definitive(let text): return .failure(text)
                    case .unknown(let text):
                        if let subscription { listenerStatus[subscription.id] = "发送结果未知" }
                        return .failure(text, outcome: "unknown")
                    }
                }
            case "subscribe":
                let profile = try resolveChannel(request.channel)
                let subscription = try await subscribe(source: request.sourceContext, profile: profile)
                return .success(LocalOperationResult(
                    channel: profile.channel,
                    settings: subscriptionSummary(subscription, profile: profile),
                    message: "当前会话将接收 \(profile.displayName) 的消息"
                ))
            case "unsubscribe":
                let profile = try resolveChannel(request.channel)
                let subscription = try requireSubscription(source: request.sourceContext, profile: profile)
                stopListener(subscription.id)
                updateSubscription(subscription.id) { $0.enabled = false }
                return .success(LocalOperationResult(channel: profile.channel, message: "已停止向当前会话转发 \(profile.displayName) 的消息"))
            case "get_settings":
                let profile = try resolveChannel(request.channel)
                let subscription = try requireSubscription(source: request.sourceContext, profile: profile)
                return .success(LocalOperationResult(settings: subscriptionSummary(subscription, profile: profile)))
            case "update_settings":
                let profile = try resolveChannel(request.channel)
                let subscription = try requireSubscription(source: request.sourceContext, profile: profile)
                try applySettings(request.settings, to: subscription.id)
                let updated = state.subscriptions.first { $0.id == subscription.id }!
                if updated.enabled { restartListenerIfNeeded(updated.id) }
                return .success(LocalOperationResult(
                    channel: profile.channel,
                    settings: subscriptionSummary(updated, profile: profile),
                    message: "当前会话的频道设置已更新"
                ))
            case "record_received":
                let message = try recordSidecarEvent(request, expectedState: .received)
                return .success(LocalOperationResult(message: message))
            case "record_outcome":
                try recordSidecarOutcome(request)
                return .success(LocalOperationResult(message: "recorded"))
            default:
                throw AppFailure("不支持的本机操作")
            }
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    func searchHostConversations() async {
        guard selectedHostProvider.supportsForwarding else { return }
        guard ensureCodexIntegrationReadyForBinding() else { return }
        let query = draftTask.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            conversationSearchResults = []
            conversationSearchStatus = ""
            return
        }
        busy = true
        defer { busy = false }
        do {
            var arguments = ["host-conversations", "--host-provider", selectedHostProvider.rawValue, "--limit", "30"]
            arguments.append(contentsOf: ["--query", query])
            let result = try await Sidecar.run(arguments)
            guard result.status == 0,
                  let data = result.stdout.data(using: .utf8),
                  let response = try? JSONDecoder().decode(HostConversationSearchResponse.self, from: data),
                  response.ok else {
                let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                throw AppFailure(detail.isEmpty ? "无法读取 AI 会话列表" : detail)
            }
            conversationSearchResults = response.conversations
            conversationSearchStatus = response.conversations.isEmpty ? "没有匹配的会话" : ""
            lastError = ""
        } catch {
            conversationSearchResults = []
            conversationSearchStatus = "搜索失败"
            fail(error)
        }
    }

    @discardableResult
    private func refreshHostConversationState(_ task: TaskBinding) async -> HostConversationRuntimeState? {
        guard let provider = HostProviderChoice(rawValue: task.provider), provider.supportsForwarding else { return nil }
        do {
            let result = try await Sidecar.run([
                "host-state", "--host-provider", task.provider,
                "--host-conversation", task.conversationID,
            ])
            guard result.status == 0,
                  let data = result.stdout.data(using: .utf8),
                  let state = try? JSONDecoder().decode(HostConversationRuntimeState.self, from: data) else {
                throw AppFailure("无法读取 ChatGPT 会话状态")
            }
            updateHostConversationState(state, taskID: task.id, automaticallyReconnect: true)
            return state
        } catch {
            hostConversationStates[task.id] = HostConversationRuntimeState(
                connected: false,
                workspace: nil,
                permission: "unknown"
            )
            ClientLog.record("warning", "host_state_refresh_failed", detail: error.localizedDescription)
            return nil
        }
    }

    func refreshHostConversationStates() async {
        for task in state.tasks { await refreshHostConversationState(task) }
        for subscription in state.subscriptions where subscription.enabled && listeners[subscription.id] == nil {
            restartListenerIfNeeded(subscription.id)
        }
    }

    func hostStateLabel(_ taskID: UUID) -> String {
        hostConversationStates[taskID]?.label ?? "正在读取会话目录与权限…"
    }

    func hostPermission(_ taskID: UUID) -> HostPermissionChoice? {
        guard let state = hostConversationStates[taskID], state.connected else { return nil }
        return HostPermissionChoice(rawValue: state.permission)
    }

    func hostPermissionCanChange(_ taskID: UUID) -> Bool {
        hostConversationStates[taskID]?.connected == true
    }

    func updateHostPermission(_ taskID: UUID, permission: HostPermissionChoice) async {
        guard let task = state.tasks.first(where: { $0.id == taskID }) else { return }
        guard hostPermissionCanChange(taskID) else {
            showNotice(title: "会话未连接", message: "请先打开并连接该会话，再修改权限。")
            return
        }
        busy = true
        defer { busy = false }
        do {
            let result = try await Sidecar.run([
                "host-state", "--host-provider", task.provider,
                "--host-conversation", task.conversationID,
                "--permission", permission.rawValue,
            ])
            guard result.status == 0,
                  let data = result.stdout.data(using: .utf8),
                  let updated = try? JSONDecoder().decode(HostConversationRuntimeState.self, from: data),
                  updated.connected,
                  updated.permission == permission.rawValue else {
                let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                throw AppFailure(detail.isEmpty ? "ChatGPT 未确认权限修改" : detail)
            }
            hostConversationStates[taskID] = updated
            lastError = ""
        } catch {
            await refreshHostConversationState(task)
            fail(error)
        }
    }

    func bindHostConversation(_ conversation: HostConversationSummary) async {
        if let provider = HostProviderChoice(rawValue: conversation.provider) {
            selectedHostProvider = provider
        }
        draftTask = conversation.conversationID
        await addTaskSubscription()
    }

    func createTaskSubscription() async {
        guard let profile = selectedChannel else { return }
        guard ensureCodexIntegrationReadyForBinding() else { return }
        guard selectedHostProvider.supportsForwarding else {
            showNotice(title: "暂不支持", message: "Pijoo 目前还不能向 Claude 会话转发消息。")
            return
        }
        let panel = NSOpenPanel()
        panel.message = "选择新会话要使用的工作目录"
        panel.prompt = "新建会话"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let workspace = panel.url else { return }

        busy = true
        taskCreationStatus = "正在创建专属会话，通常需要几秒…"
        defer {
            busy = false
            taskCreationStatus = ""
        }
        do {
            let provider = selectedHostProvider
            guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: provider.bundleIdentifier) else {
                throw AppFailure("未找到 \(provider.displayName) App")
            }
            let executable = app.appendingPathComponent("Contents/Resources/codex")
            guard FileManager.default.isExecutableFile(atPath: executable.path) else {
                throw AppFailure("\(provider.displayName) App 缺少可用的 Codex 组件")
            }
            let result = try await Sidecar.run([
                "host-create",
                "--host-provider", provider.rawValue,
                "--host-workspace", workspace.path,
                "--host-title", "Pijoo · \(profile.displayName)",
                "--codex-executable", executable.path,
            ])
            guard result.status == 0,
                  let data = result.stdout.data(using: .utf8),
                  let response = try? JSONDecoder().decode(HostConversationCreateResponse.self, from: data),
                  response.ok,
                  UUID(uuidString: response.conversationID) != nil else {
                let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                throw AppFailure(detail.isEmpty ? "无法新建 AI 会话" : detail)
            }
            let conversationID = response.conversationID.lowercased()
            taskCreationStatus = "会话已创建，正在等待 ChatGPT 连接…"
            guard let url = URL(string: "codex://threads/\(conversationID)") else {
                throw AppFailure("会话已创建（\(conversationID)），但无法在 \(provider.displayName) 中打开")
            }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            _ = try await NSWorkspace.shared.open(url, configuration: configuration)

            var lastPreflightError = ""
            var verified: (provider: String, conversationID: String)?
            for attempt in 0..<20 {
                do {
                    verified = try await preflightHostConversation(conversationID, provider: provider)
                    break
                } catch {
                    lastPreflightError = error.localizedDescription
                    if attempt < 19 { try await Task.sleep(nanoseconds: 500_000_000) }
                }
            }
            guard let verified else {
                throw AppFailure("会话已创建（\(conversationID)），但暂时无法连接。请在 Codex 中打开后按 ID 连接。\(lastPreflightError.isEmpty ? "" : "\n\(lastPreflightError)")")
            }
            taskCreationStatus = "正在关联当前频道…"
            _ = try await subscribe(
                source: LocalSource(provider: verified.provider, conversationId: verified.conversationID),
                profile: profile
            )
            clearConversationDraft()
        } catch {
            fail(error)
        }
    }

    func addTaskSubscription() async {
        guard let profile = selectedChannel else { return }
        guard ensureCodexIntegrationReadyForBinding() else { return }
        guard selectedHostProvider.supportsForwarding else {
            showNotice(title: "暂不支持", message: "Pijoo 目前还不能向 Claude 会话转发消息。")
            return
        }
        busy = true
        defer { busy = false }
        do {
            let raw = draftTask.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty else { throw AppFailure("请输入 AI 会话 ID 或链接") }
            let verified = try await preflightHostConversation(raw, provider: selectedHostProvider)
            _ = try await subscribe(
                source: LocalSource(provider: verified.provider, conversationId: verified.conversationID),
                profile: profile
            )
            clearConversationDraft()
        } catch {
            fail(error)
        }
    }

    private func preflightHostConversation(_ raw: String, provider: HostProviderChoice) async throws -> (provider: String, conversationID: String) {
        let result = try await Sidecar.run([
            "host-preflight",
            "--host-provider", provider.rawValue,
            "--host-conversation", raw,
        ])
        guard result.status == 0,
              let data = result.stdout.data(using: .utf8),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["ok"] as? Bool == true,
              let provider = json["provider"] as? String,
              let conversationID = json["conversation_id"] as? String,
              UUID(uuidString: conversationID) != nil else {
            let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw AppFailure(detail.isEmpty ? "AI 会话检测失败" : detail)
        }
        return (provider, conversationID.lowercased())
    }

    private func clearConversationDraft() {
        draftTask = ""
        conversationSearchResults = []
        conversationSearchStatus = ""
        lastError = ""
    }

    func setSubscriptionEnabled(_ id: UUID, enabled: Bool) {
        if enabled,
           state.subscriptions.first(where: { $0.id == id })?.uncertainMessageID != nil {
            fail(AppFailure("这条订阅有一条投递结果未知，请先选择“重试”或“跳过”"))
            return
        }
        updateSubscription(id) {
            $0.enabled = enabled
        }
        if enabled { Task { await startListener(id) } }
        else { stopListener(id) }
    }

    func setSubscriptionDefault(_ id: UUID, enabled: Bool) {
        guard let subscription = state.subscriptions.first(where: { $0.id == id }) else { return }
        if enabled {
            for index in state.subscriptions.indices where state.subscriptions[index].taskID == subscription.taskID {
                state.subscriptions[index].defaultSend = state.subscriptions[index].id == id
            }
            persistState()
        } else {
            updateSubscription(id) { $0.defaultSend = false }
        }
    }

    func setSubscriptionPolicy(_ id: UUID, policy: SelfMessagePolicy) {
        updateSubscription(id) { $0.selfMessagePolicy = policy }
        restartListenerIfNeeded(id)
    }

    func setSubscriptionReceiveScope(_ id: UUID, scope: ReceiveScope) {
        updateSubscription(id) { $0.receiveScope = scope }
        restartListenerIfNeeded(id)
    }

    func setSubscriptionTemplate(_ id: UUID, template: String) {
        do {
            let value = try validateMessageTemplate(template, defaultTemplate: defaultMessageTemplate)
            updateSubscription(id) { $0.template = value }
            restartListenerIfNeeded(id)
        } catch {
            fail(error)
        }
    }

    func setSubscriptionSentMessageTemplate(_ id: UUID, template: String) {
        do {
            let value = try validateMessageTemplate(template, defaultTemplate: defaultSentMessageTemplate)
            updateSubscription(id) { $0.sentMessageTemplate = value }
        } catch {
            fail(error)
        }
    }

    func removeSubscription(_ id: UUID) {
        stopListener(id)
        try? MessageLedger.removeDeliveries(id)
        guard let removed = state.subscriptions.first(where: { $0.id == id }) else { return }
        state.subscriptions.removeAll { $0.id == id }
        if !state.subscriptions.contains(where: { $0.taskID == removed.taskID }) {
            state.tasks.removeAll { $0.id == removed.taskID }
            hostConversationStates.removeValue(forKey: removed.taskID)
            automaticallyReconnectingTaskIDs.remove(removed.taskID)
        }
        persistState()
    }

    func taskLabel(_ taskID: UUID) -> String {
        guard let task = state.tasks.first(where: { $0.id == taskID }) else { return "未知会话" }
        return "\(hostDisplayName(task.provider)) · \(task.conversationID.prefix(8))…"
    }

    @discardableResult
    func openTask(_ taskID: UUID, activates: Bool = true) -> Bool {
        guard let task = state.tasks.first(where: { $0.id == taskID }) else {
            fail(AppFailure("AI 会话不存在"))
            return false
        }
        guard task.provider == "codex",
              let url = URL(string: "codex://threads/\(task.conversationID)") else {
            fail(AppFailure("无法打开 \(hostDisplayName(task.provider)) 会话，请确认对应 AI 应用已安装且会话仍存在"))
            return false
        }

        if activates {
            guard NSWorkspace.shared.open(url) else {
                fail(AppFailure("无法打开 \(hostDisplayName(task.provider)) 会话，请确认对应 AI 应用已安装且会话仍存在"))
                return false
            }
        } else {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            NSWorkspace.shared.open(url, configuration: configuration)
        }
        return true
    }

    private func updateHostConversationState(
        _ state: HostConversationRuntimeState,
        taskID: UUID,
        automaticallyReconnect: Bool = false
    ) {
        hostConversationStates[taskID] = state
        if state.connected {
            automaticallyReconnectingTaskIDs.remove(taskID)
        } else if automaticallyReconnect, automaticallyReconnectingTaskIDs.insert(taskID).inserted {
            ClientLog.record("info", "host_conversation_auto_reconnect_requested")
            if !openTask(taskID, activates: false) {
                automaticallyReconnectingTaskIDs.remove(taskID)
            }
        }
    }

    func refreshHostConversation(_ taskID: UUID) async {
        guard let task = state.tasks.first(where: { $0.id == taskID }) else { return }
        automaticallyReconnectingTaskIDs.remove(taskID)
        await refreshHostConversationState(task)
        for subscription in state.subscriptions
            where subscription.taskID == taskID && subscription.enabled && listeners[subscription.id] == nil {
            restartListenerIfNeeded(subscription.id)
        }
    }

    private func taskBinding(for source: LocalSource) -> TaskBinding? {
        state.tasks.first {
            $0.provider == source.provider && $0.conversationID.lowercased() == source.conversationId.lowercased()
        }
    }

    private func resolveChannel(_ raw: String?) throws -> ChannelProfile {
        guard let query = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty else {
            throw AppFailure("channel is required")
        }
        let matches = state.channels.filter {
            $0.id.uuidString.caseInsensitiveCompare(query) == .orderedSame ||
                $0.channel.caseInsensitiveCompare(query) == .orderedSame ||
                $0.displayName.caseInsensitiveCompare(query) == .orderedSame
        }
        guard matches.count == 1, let match = matches.first else {
            throw AppFailure(matches.isEmpty ? "本机没有频道 \(query)" : "频道名称有歧义，请使用频道 ID")
        }
        return match
    }

    private func requireSubscription(source: LocalSource, profile: ChannelProfile) throws -> ChannelSubscription {
        guard let task = taskBinding(for: source),
              let subscription = state.subscriptions.first(where: {
                  $0.taskID == task.id && $0.channelID == profile.id
              }) else {
            throw AppFailure("当前会话尚未接收该频道消息")
        }
        return subscription
    }

    private func outboundRoute(
        source: LocalSource,
        channel: String?
    ) throws -> (TaskBinding?, ChannelSubscription?, ChannelProfile) {
        let task = taskBinding(for: source)
        let explicitProfile = channel?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? try resolveChannel(channel)
            : nil
        let selection = try outboundSelection(
            taskID: task?.id,
            explicitChannelID: explicitProfile?.id,
            channels: state.channels,
            subscriptions: state.subscriptions
        )
        guard let profile = state.channels.first(where: { $0.id == selection.channelID }) else {
            throw AppFailure("发送频道不存在")
        }
        let subscription = selection.subscriptionID.flatMap { id in
            state.subscriptions.first { $0.id == id }
        }
        return (task, subscription, profile)
    }

    @discardableResult
    private func subscribe(
        source: LocalSource,
        profile: ChannelProfile
    ) async throws -> ChannelSubscription {
        let task: TaskBinding
        if let index = state.tasks.firstIndex(where: {
            $0.provider == source.provider && $0.conversationID.lowercased() == source.conversationId.lowercased()
        }) {
            task = state.tasks[index]
        } else {
            task = TaskBinding(
                id: UUID(),
                provider: source.provider,
                conversationID: source.conversationId.lowercased()
            )
            state.tasks.append(task)
        }
        let subscription: ChannelSubscription
        if let index = state.subscriptions.firstIndex(where: { $0.taskID == task.id && $0.channelID == profile.id }) {
            guard state.subscriptions[index].uncertainMessageID == nil else {
                throw AppFailure("这条订阅有一条投递结果未知，请先在 App 中选择“重试”或“跳过”")
            }
            state.subscriptions[index].enabled = true
            subscription = state.subscriptions[index]
        } else {
            let baseline = try await currentRemoteCursor(profile)
            if let index = state.subscriptions.firstIndex(where: { $0.taskID == task.id && $0.channelID == profile.id }) {
                guard state.subscriptions[index].uncertainMessageID == nil else {
                    throw AppFailure("这条订阅有一条投递结果未知，请先在 App 中选择“重试”或“跳过”")
                }
                state.subscriptions[index].enabled = true
                subscription = state.subscriptions[index]
            } else {
                let hasDefault = state.subscriptions.contains { $0.taskID == task.id && $0.defaultSend }
                subscription = ChannelSubscription(
                    id: UUID(),
                    channelID: profile.id,
                    taskID: task.id,
                    enabled: true,
                    template: defaultMessageTemplate,
                    sentMessageTemplate: defaultSentMessageTemplate,
                    selfMessagePolicy: .includeOtherEndpoints,
                    defaultSend: !hasDefault,
                    lastDeliveredMessageID: baseline,
                    lastDeliveredAt: nil
                )
                state.subscriptions.append(subscription)
            }
        }
        persistState()
        await startListener(subscription.id)
        return state.subscriptions.first(where: { $0.id == subscription.id }) ?? subscription
    }

    private func currentRemoteCursor(_ profile: ChannelProfile) async throws -> Int64 {
        let json = try await authorizedJSON(profile, suffix: "history?limit=1", method: "GET")
        guard let last = (json["history"] as? [[String: Any]])?.last else { return 0 }
        if let id = last["id"] as? NSNumber { return id.int64Value }
        if let id = last["id"] as? String, let value = Int64(id) { return value }
        throw AppFailure("频道历史响应缺少消息 ID")
    }

    private func subscriptionSummary(_ subscription: ChannelSubscription, profile: ChannelProfile) -> LocalSubscriptionSummary {
        LocalSubscriptionSummary(
            channel: profile.channel,
            receiveEnabled: subscription.enabled,
            template: subscription.template,
            sentMessageTemplate: subscription.sentMessageTemplate ?? defaultSentMessageTemplate,
            selfMessagePolicy: subscription.selfMessagePolicy,
            receiveScope: subscription.receiveScope ?? .allMessages,
            defaultSend: subscription.defaultSend
        )
    }

    private func updateSubscription(_ id: UUID, update: (inout ChannelSubscription) -> Void) {
        guard let index = state.subscriptions.firstIndex(where: { $0.id == id }) else { return }
        update(&state.subscriptions[index])
        persistState()
    }

    private func applySettings(_ patch: LocalSettingsPatch?, to id: UUID) throws {
        guard let patch else { throw AppFailure("settings are required") }
        let template = try patch.template.map {
            try validateMessageTemplate($0, defaultTemplate: defaultMessageTemplate)
        }
        let sentMessageTemplate = try patch.sentMessageTemplate.map {
            try validateMessageTemplate($0, defaultTemplate: defaultSentMessageTemplate)
        }
        guard let index = state.subscriptions.firstIndex(where: { $0.id == id }) else {
            throw AppFailure("订阅不存在")
        }
        if let template { state.subscriptions[index].template = template }
        if let sentMessageTemplate { state.subscriptions[index].sentMessageTemplate = sentMessageTemplate }
        if let policy = patch.selfMessagePolicy { state.subscriptions[index].selfMessagePolicy = policy }
        if let scope = patch.receiveScope { state.subscriptions[index].receiveScope = scope }
        if let defaultSend = patch.defaultSend {
            if defaultSend {
                let taskID = state.subscriptions[index].taskID
                for candidate in state.subscriptions.indices where state.subscriptions[candidate].taskID == taskID {
                    state.subscriptions[candidate].defaultSend = candidate == index
                }
            } else {
                state.subscriptions[index].defaultSend = false
            }
        }
        persistState()
    }

}

extension AppModel {
    func startListener(_ id: UUID) async {
        guard listeners[id] == nil,
              !recoveryPausedSubscriptionIDs.contains(id),
              let subscription = state.subscriptions.first(where: { $0.id == id }), subscription.enabled,
              let profile = state.channels.first(where: { $0.id == subscription.channelID }),
              let task = state.tasks.first(where: { $0.id == subscription.taskID }) else { return }
        guard subscription.uncertainMessageID == nil else {
            listenerStatus[id] = "结果未知，请先重试或跳过"
            return
        }
        guard !startingListeners.contains(id) else { return }
        let generation = listenerGenerations[id, default: 0]
        startingListeners.insert(id)
        defer {
            startingListeners.remove(id)
            if listenerGenerations[id, default: 0] != generation,
               listenerCanStart(id, generation: listenerGenerations[id, default: 0]) {
                Task { await startListener(id) }
            }
        }
        listenerStatus[id] = "正在检查 \(hostDisplayName(task.provider))…"
        do {
            let preflight = try await Sidecar.run([
                "host-preflight",
                "--host-provider", task.provider,
                "--host-conversation", task.conversationID,
                "--require-owner",
            ])
            guard listenerCanStart(id, generation: generation) else { return }
            guard preflight.status == 0 else {
                let detail = preflight.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                if isDisconnectedHostError(detail) {
                    updateHostConversationState(HostConversationRuntimeState(
                        connected: false,
                        workspace: nil,
                        permission: "unknown"
                    ), taskID: task.id, automaticallyReconnect: true)
                    listenerStatus[id] = "会话未连接"
                    ClientLog.record("info", "listener_waiting_for_host_conversation")
                    scheduleListenerRestart(id)
                    return
                }
                throw AppFailure(detail.isEmpty ? "AI 会话当前不可用" : detail)
            }
            automaticallyReconnectingTaskIDs.remove(task.id)
            if hostConversationStates[task.id]?.connected != true {
                hostConversationStates[task.id] = HostConversationRuntimeState(
                    connected: true,
                    workspace: nil,
                    permission: "unknown"
                )
            }
            guard let credential = try KeychainStore.get(service: keychainService, account: profile.credentialAccount),
                  !credential.isEmpty else { throw AppFailure("Keychain 中没有频道成员凭证") }

            let process = Process()
            let output = Pipe()
            let error = Pipe()
            let input = Pipe()
            let txEndpoint = endpointCallsign(profile, conversationID: task.conversationID, kind: "t")
            let txJoin = try await requestJSON(
                url: try channelBaseURL(profile).appendingPathComponent("join"),
                method: "POST",
                bearer: credential,
                body: ["callsign": txEndpoint, "name": state.defaultCallsign]
            )
            guard listenerCanStart(id, generation: generation) else { return }
            guard let authenticatedMemberID = txJoin["member_id"] as? String, !authenticatedMemberID.isEmpty,
                  let txEndpointID = txJoin["endpoint_id"] as? String, !txEndpointID.isEmpty else {
                throw AppFailure("服务端未返回可信 task endpoint 身份")
            }
            let reconciledProfile = try reconcileChannelMemberIdentity(
                profile,
                authenticatedMemberID: authenticatedMemberID
            )
            process.executableURL = Sidecar.executable
            var arguments = [
                "listen-here",
                "--origin", profile.origin,
                "--channel", profile.channel,
                "--identity-key", endpointCallsign(reconciledProfile, conversationID: task.conversationID, kind: "r"),
                "--host-provider", task.provider,
                "--host-conversation", task.conversationID,
                "--secrets-stdin",
                "--status-json",
                "--quiet",
                "--channel-name", reconciledProfile.displayName,
                "--message-template", subscription.template,
                "--receive-scope", (subscription.receiveScope ?? .allMessages).rawValue,
                "--self-message-policy", subscription.selfMessagePolicy.rawValue,
                "--self-endpoint-id", txEndpointID,
                "--self-member-id", reconciledProfile.memberID,
                "--app-socket", AppPaths.sendSocket.path,
                "--subscription-id", subscription.id.uuidString.lowercased(),
            ]
            if let since = subscription.lastDeliveredMessageID {
                arguments.append(contentsOf: ["--since", String(since)])
            }
            process.arguments = arguments
            process.standardOutput = output
            process.standardError = error
            process.standardInput = input
            let listener = SubscriptionListener(subscriptionID: id, process: process, output: output, error: error)
            output.fileHandleForReading.readabilityHandler = { handle in
                if handle.availableData.isEmpty { handle.readabilityHandler = nil }
            }
            error.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    return
                }
                Task { @MainActor [weak self] in self?.consumeListenerStderr(data, id: id) }
            }
            process.terminationHandler = { [weak self, weak process] _ in
                Task { @MainActor [weak self, weak process] in
                    guard let self, let process else { return }
                    self.listenerDidTerminate(id, process: process)
                }
            }
            listeners[id] = listener
            do {
                try process.run()
            } catch {
                listeners.removeValue(forKey: id)
                throw error
            }
            let secret = try JSONSerialization.data(withJSONObject: ["token": credential])
            input.fileHandleForWriting.write(secret)
            try? input.fileHandleForWriting.close()
            listenerStatus[id] = "正在连接…"
        } catch {
            guard listenerGenerations[id, default: 0] == generation else { return }
            listenerStatus[id] = "不可用：\(error.localizedDescription)"
            ClientLog.record("error", "listener_start_failed", detail: error.localizedDescription)
            scheduleListenerRestart(id)
        }
    }

    private func listenerCanStart(_ id: UUID, generation: Int) -> Bool {
        guard listenerGenerations[id, default: 0] == generation,
              listeners[id] == nil,
              !recoveryPausedSubscriptionIDs.contains(id),
              let subscription = state.subscriptions.first(where: { $0.id == id }) else { return false }
        return subscription.enabled && subscription.uncertainMessageID == nil
    }

    func stopListener(_ id: UUID) {
        listenerGenerations[id, default: 0] += 1
        clearRecoveredBridgeError(id, state: "stopped")
        guard let listener = listeners[id] else {
            listenerStatus[id] = "已暂停"
            return
        }
        guard !listener.expectedStop else { return }
        listener.expectedStop = true
        listener.output.fileHandleForReading.readabilityHandler = nil
        listener.error.fileHandleForReading.readabilityHandler = nil
        if listener.process.isRunning { listener.process.terminate() }
        listenerStatus[id] = "已暂停"
    }

    func setAllListening(_ enabled: Bool) {
        var blocked = 0
        for index in state.subscriptions.indices {
            if enabled && state.subscriptions[index].uncertainMessageID != nil {
                blocked += 1
                continue
            }
            state.subscriptions[index].enabled = enabled
        }
        if !enabled {
            for id in Set(listeners.keys).union(startingListeners) { stopListener(id) }
        }
        persistState()
        if enabled {
            for subscription in state.subscriptions where subscription.enabled {
                Task { await startListener(subscription.id) }
            }
            if blocked > 0 {
                lastError = "\(blocked) 条订阅因投递结果未知保持暂停，请先重试或跳过"
            }
        }
    }

    private func restartListenerIfNeeded(_ id: UUID) {
        guard let subscription = state.subscriptions.first(where: { $0.id == id }),
              !recoveryPausedSubscriptionIDs.contains(id),
              subscription.enabled, subscription.uncertainMessageID == nil else { return }
        if listeners[id] == nil && !startingListeners.contains(id) { Task { await startListener(id) } }
        else { stopListener(id) }
    }

    private func scheduleListenerRestart(_ id: UUID) {
        guard state.subscriptions.first(where: { $0.id == id })?.enabled == true,
              !recoveryPausedSubscriptionIDs.contains(id) else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            guard let self,
                  self.state.subscriptions.first(where: { $0.id == id })?.enabled == true,
                  !self.recoveryPausedSubscriptionIDs.contains(id),
                  self.listeners[id] == nil else { return }
            await self.startListener(id)
        }
    }

    private func listenerDidTerminate(_ id: UUID, process: Process) {
        guard let listener = listeners[id], listener.process === process else { return }
        listeners.removeValue(forKey: id)
        listener.output.fileHandleForReading.readabilityHandler = nil
        listener.error.fileHandleForReading.readabilityHandler = nil
        if let last = MessageLedger.loadDeliveries(id).last,
           last.state == .attempting || last.state == .unknown,
           let messageID = Int64(last.messageID),
           let index = state.subscriptions.firstIndex(where: { $0.id == id }) {
            state.subscriptions[index].enabled = false
            state.subscriptions[index].uncertainMessageID = messageID
            state.subscriptions[index].uncertainDetail = last.detail ?? "Host 投递没有可靠终态，请人工核对"
            persistState()
            listenerStatus[id] = "结果未知，已暂停"
            return
        }
        if listener.expectedStop {
            if let subscription = state.subscriptions.first(where: { $0.id == id }),
               subscription.enabled, subscription.uncertainMessageID == nil,
               !recoveryPausedSubscriptionIDs.contains(id) {
                listenerStatus[id] = "正在安全重启…"
                Task { await startListener(id) }
            } else {
                listenerStatus[id] = "已暂停"
            }
            return
        }
        let enabled = state.subscriptions.first(where: { $0.id == id })?.enabled == true
        if enabled {
            listenerStatus[id] = "已断开，等待重连"
            ClientLog.record("warning", "listener_terminated")
            scheduleListenerRestart(id)
        } else if listenerStatus[id] == nil {
            listenerStatus[id] = "已停止"
        }
    }

    private func clearRecoveredBridgeError(_ id: UUID, state: String) {
        guard bridgeRecoveryClearsError(kind: bridgeErrorKinds[id], state: state) else { return }
        let displayed = presentedBridgeError
        bridgeConnectionEscalations.removeValue(forKey: id)
        bridgeErrorKinds.removeValue(forKey: id)
        bridgeErrorMessages.removeValue(forKey: id)
        guard lastError == displayed else {
            if bridgeErrorMessages.isEmpty { presentedBridgeError = nil }
            return
        }
        presentedBridgeError = bridgeErrorMessages.values.first
        lastError = presentedBridgeError ?? ""
    }

    private func scheduleBridgeConnectionEscalation(_ id: UUID) {
        guard bridgeConnectionEscalations[id] == nil else { return }
        let token = UUID()
        bridgeConnectionEscalations[id] = token
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 60_000_000_000)
            guard let self,
                  self.bridgeConnectionEscalations[id] == token,
                  self.bridgeErrorKinds[id] == "connection",
                  let message = self.bridgeErrorMessages[id] else { return }
            self.presentedBridgeError = message
            self.lastError = message
        }
    }

    private func consumeListenerStderr(_ data: Data, id: UUID) {
        guard let listener = listeners[id] else { return }
        listener.remainder += String(decoding: data, as: UTF8.self)
        while let newline = listener.remainder.firstIndex(of: "\n") {
            let line = String(listener.remainder[..<newline])
            listener.remainder.removeSubrange(...newline)
            guard line.hasPrefix("@pijoo "),
                  let raw = line.dropFirst("@pijoo ".count).data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
                  let state = event["state"] as? String else { continue }
            clearRecoveredBridgeError(id, state: state)
            switch state {
            case "joined", "connecting": listenerStatus[id] = "正在连接…"
            case "connected":
                listenerStatus[id] = "正在接收"
                if let taskID = self.state.subscriptions.first(where: { $0.id == id })?.taskID {
                    let previous = hostConversationStates[taskID]
                    updateHostConversationState(HostConversationRuntimeState(
                        connected: true,
                        workspace: previous?.workspace,
                        permission: previous?.permission ?? "unknown"
                    ), taskID: taskID)
                }
                if let diagnostic = event["diagnostic"] as? String, !diagnostic.isEmpty {
                    ClientLog.record("info", "listener_connected", detail: clientLogField(diagnostic))
                }
            case "reconnecting":
                listenerStatus[id] = "正在重连…"
                if let diagnostic = event["diagnostic"] as? String, !diagnostic.isEmpty {
                    let level = event["reason"] as? String == "railway_request_limit" ? "info" : "warning"
                    ClientLog.record(level, "listener_reconnecting", detail: clientLogField(diagnostic))
                }
            case "delivered": listenerStatus[id] = "已转发到会话 #\(event["messageId"] ?? "")"
            case "filtered": listenerStatus[id] = "已过滤自消息"
            case "error":
                let detail = (event["error"] as? String) ?? (event["kind"] as? String) ?? "未知错误"
                let kind = (event["kind"] as? String) ?? "unknown"
                if isDisconnectedHostError(detail),
                   let taskID = self.state.subscriptions.first(where: { $0.id == id })?.taskID {
                    updateHostConversationState(HostConversationRuntimeState(
                        connected: false,
                        workspace: nil,
                        permission: "unknown"
                    ), taskID: taskID, automaticallyReconnect: true)
                    listenerStatus[id] = "会话未连接"
                    ClientLog.record("info", "listener_waiting_for_host_conversation")
                    continue
                }
                listenerStatus[id] = "异常：\(detail)"
                let diagnostic = (event["diagnostic"] as? String).map { " \(clientLogField($0))" } ?? ""
                ClientLog.record("error", "listener_error", detail: "kind=\(kind) \(detail)\(diagnostic)")
                if bridgeErrorShouldReplace(current: bridgeErrorKinds[id], incoming: kind) {
                    let message = "订阅异常：\(detail)"
                    bridgeErrorKinds[id] = kind
                    bridgeErrorMessages[id] = message
                    if bridgeErrorAffectsGlobalHealthImmediately(kind) {
                        bridgeConnectionEscalations.removeValue(forKey: id)
                        presentedBridgeError = message
                        lastError = message
                    } else {
                        scheduleBridgeConnectionEscalation(id)
                    }
                }
                if (event["status"] as? NSNumber)?.intValue == 401,
                   let channelID = self.state.subscriptions.first(where: { $0.id == id })?.channelID {
                    markChannelAuthorizationLost(channelID, detail: detail)
                }
            case "stopped": listenerStatus[id] = "已停止"
            default: break
            }
        }
    }

    private func recordSidecarEvent(
        _ request: LocalSendRequest,
        expectedState: MessageDeliveryState
    ) throws -> String {
        guard expectedState == .received,
              let subscriptionID = request.subscriptionID.flatMap(UUID.init(uuidString:)),
              let subscriptionIndex = state.subscriptions.firstIndex(where: { $0.id == subscriptionID }) else {
            throw AppFailure("sidecar received event does not match its subscription")
        }
        let subscription = state.subscriptions[subscriptionIndex]
        guard let task = state.tasks.first(where: { $0.id == subscription.taskID }),
              task.provider == request.sourceContext.provider,
              task.conversationID.caseInsensitiveCompare(request.sourceContext.conversationId) == .orderedSame,
              let profile = state.channels.first(where: { $0.id == subscription.channelID }),
              profile.channel == request.channel,
              let event = request.event,
              let id = event.id, let from = event.from, let to = event.to,
              let text = event.text, let at = event.at,
              let senderMemberID = event.senderMemberID, !senderMemberID.isEmpty,
              let senderEndpointID = event.senderEndpointID, !senderEndpointID.isEmpty else {
            throw AppFailure("sidecar received event does not match its subscription")
        }
        let key = String(id)
        let latestDelivery = MessageLedger.loadDeliveries(subscriptionID).last {
            $0.channelID == profile.id && $0.messageID == key
        }
        let decision = receivedDeliveryDecision(latestDelivery?.state)
        if decision == .alreadyProcessed {
            let cursor = advancedDeliveryCursor(
                state.subscriptions[subscriptionIndex].lastDeliveredMessageID,
                through: id
            )
            if cursor != state.subscriptions[subscriptionIndex].lastDeliveredMessageID {
                state.subscriptions[subscriptionIndex].lastDeliveredMessageID = cursor
                try persistStateOrThrow()
            }
            return decision.rawValue
        }
        if decision == .unresolved { return decision.rawValue }
        let senderName = event.senderName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let record = ChannelMessageRecord(
            channelID: profile.id,
            messageID: key,
            direction: senderMemberID == profile.memberID ? .outbound : .inbound,
            from: senderName.flatMap { $0.isEmpty ? nil : $0 } ?? from,
            to: to,
            text: text,
            at: at,
            state: .received,
            senderMemberID: senderMemberID,
            senderEndpointID: senderEndpointID,
            source: event.source,
            mention: event.mention
        )
        try MessageLedger.append(record)
        upsertMessage(record, persist: false)
        try MessageLedger.appendDelivery(SubscriptionDeliveryRecord(
            subscriptionID: subscriptionID,
            channelID: profile.id,
            messageID: key,
            state: .received,
            detail: nil,
            updatedAt: Date().timeIntervalSince1970
        ))
        if recoveryPausedSubscriptionIDs.contains(subscriptionID) {
            refreshRecoveryPendingMessageCount()
            return ReceivedDeliveryDecision.unresolved.rawValue
        }
        return decision.rawValue
    }

    private func recordSidecarOutcome(_ request: LocalSendRequest) throws {
        guard let subscriptionID = request.subscriptionID.flatMap(UUID.init(uuidString:)),
              let subscriptionIndex = state.subscriptions.firstIndex(where: { $0.id == subscriptionID }),
              let task = state.tasks.first(where: { $0.id == state.subscriptions[subscriptionIndex].taskID }),
              task.provider == request.sourceContext.provider,
              task.conversationID.caseInsensitiveCompare(request.sourceContext.conversationId) == .orderedSame,
              let profile = state.channels.first(where: { $0.id == state.subscriptions[subscriptionIndex].channelID }),
              profile.channel == request.channel,
              let event = request.event, let id = event.id, let outcome = event.state,
              [.attempting, .filtered, .delivered, .failed, .unknown].contains(outcome) else {
            throw AppFailure("sidecar outcome does not match its subscription")
        }
        let key = String(id)
        let records = profile.id == selectedChannelID ? messages : MessageLedger.load(profile.id)
        guard records.contains(where: {
            $0.channelID == profile.id && $0.messageID == key
        }) else { throw AppFailure("message must be recorded before its delivery outcome") }
        try MessageLedger.appendDelivery(SubscriptionDeliveryRecord(
            subscriptionID: subscriptionID,
            channelID: profile.id,
            messageID: key,
            state: outcome,
            detail: event.error,
            updatedAt: Date().timeIntervalSince1970
        ))
        if outcome == .delivered || outcome == .filtered {
            state.subscriptions[subscriptionIndex].lastDeliveredMessageID = advancedDeliveryCursor(
                state.subscriptions[subscriptionIndex].lastDeliveredMessageID,
                through: id
            )
            state.subscriptions[subscriptionIndex].lastDeliveredAt = Date().timeIntervalSince1970
            state.subscriptions[subscriptionIndex].uncertainMessageID = nil
            state.subscriptions[subscriptionIndex].uncertainDetail = nil
            if outcome == .filtered { listenerStatus[subscriptionID] = "正在接收" }
        } else if outcome == .unknown {
            state.subscriptions[subscriptionIndex].enabled = false
            state.subscriptions[subscriptionIndex].uncertainMessageID = id
            state.subscriptions[subscriptionIndex].uncertainDetail = event.error
            listenerStatus[subscriptionID] = "转发结果未知，已暂停"
        } else if outcome == .failed, let error = event.error {
            listenerStatus[subscriptionID] = "转发失败：\(error)"
        } else if outcome == .attempting {
            listenerStatus[subscriptionID] = "正在转发 #\(id)"
        }
        try persistStateOrThrow()
    }

    func resolveUncertainDelivery(_ subscriptionID: UUID, retry: Bool) {
        guard let index = state.subscriptions.firstIndex(where: { $0.id == subscriptionID }),
              let messageID = state.subscriptions[index].uncertainMessageID else { return }
        do {
            try MessageLedger.appendDelivery(SubscriptionDeliveryRecord(
                subscriptionID: subscriptionID,
                channelID: state.subscriptions[index].channelID,
                messageID: String(messageID),
                state: retry ? .received : .skipped,
                detail: retry ? "用户确认目标会话未出现，允许重试" : "用户确认目标会话已出现，跳过重放",
                updatedAt: Date().timeIntervalSince1970
            ))
            if !retry {
                state.subscriptions[index].lastDeliveredMessageID = advancedDeliveryCursor(
                    state.subscriptions[index].lastDeliveredMessageID,
                    through: messageID
                )
            }
            state.subscriptions[index].uncertainMessageID = nil
            state.subscriptions[index].uncertainDetail = nil
            state.subscriptions[index].enabled = true
            try persistStateOrThrow()
            Task { await startListener(subscriptionID) }
        } catch {
            fail(error)
        }
    }
}

extension AppModel {
    func startChannelFeed(_ channelID: UUID) {
        guard feedTasks[channelID] == nil, state.channels.contains(where: { $0.id == channelID }) else { return }
        channelStatus[channelID] = "正在连接…"
        feedTasks[channelID] = Task { @MainActor [weak self] in
            await self?.runChannelFeed(channelID)
        }
    }

    func reconnectChannel(_ channelID: UUID) {
        guard feedTasks[channelID] == nil else { return }
        startChannelFeed(channelID)
    }

    private func runChannelFeed(_ channelID: UUID) async {
        var backoff: UInt64 = 1_000_000_000
        while !Task.isCancelled,
              let profile = state.channels.first(where: { $0.id == channelID }) {
            var connectedAt: Date?
            do {
                guard let credential = try KeychainStore.get(service: keychainService, account: profile.credentialAccount),
                      !credential.isEmpty else { throw AppFailure("Keychain 中没有频道成员凭证") }
                let endpoint = endpointCallsign(profile, kind: "f")
                let join = try await requestJSON(
                    url: try channelBaseURL(profile).appendingPathComponent("join"),
                    method: "POST",
                    bearer: credential,
                    body: ["callsign": endpoint, "name": state.defaultCallsign]
                )
                guard let session = join["session_id"] as? String, !session.isEmpty,
                      let authenticatedMemberID = join["member_id"] as? String, !authenticatedMemberID.isEmpty,
                      (join["endpoint_id"] as? String)?.isEmpty == false else {
                    throw AppFailure("频道加入响应缺少 session/member/endpoint")
                }
                let reconciledProfile = try reconcileChannelMemberIdentity(
                    profile,
                    authenticatedMemberID: authenticatedMemberID
                )
                try? await syncChannelHistory(reconciledProfile)
                let base = try channelBaseURL(reconciledProfile)
                connectedAt = Date()
                channelStatus[channelID] = "已连接"
                ClientLog.record(
                    "info",
                    "channel_feed_connected",
                    detail: "stage=connected transport=long_poll channel_id=\(channelID.uuidString.lowercased())"
                )
                backoff = 1_000_000_000
                while !Task.isCancelled {
                    let cursor = MessageLedger.load(profile.id).compactMap { Int64($0.messageID) }.max()
                    let response = try await requestJSON(
                        url: channelListenURL(base: base, cursor: cursor),
                        method: "GET",
                        bearer: credential,
                        headers: ["X-Session-Id": session]
                    )
                    for message in (response["messages"] as? [[String: Any]]) ?? [] {
                        handleFeedMessage(message, profile: reconciledProfile)
                    }
                }
            } catch let error as ChannelAuthorizationFailure {
                markChannelAuthorizationLost(channelID, detail: error.localizedDescription)
                feedTasks.removeValue(forKey: channelID)
                return
            } catch {
                if Task.isCancelled { return }
                let connectedMs = connectedAt.map { max(0, Int(Date().timeIntervalSince($0) * 1_000)) }
                let reason = "connection_error"
                let nsError = error as NSError
                let underlyingError = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
                let detail = [
                    "reason=\(reason)",
                    "stage=\(connectedAt == nil ? "handshake" : "listen")",
                    connectedMs.map { "connected_ms=\($0)" },
                    "error_domain=\(clientLogField(nsError.domain))",
                    "error_code=\(nsError.code)",
                    underlyingError.map { "cause_domain=\(clientLogField($0.domain))" },
                    underlyingError.map { "cause_code=\($0.code)" },
                ].compactMap { $0 }.joined(separator: " ")
                channelStatus[channelID] = "正在重连：\(error.localizedDescription)"
                ClientLog.record(
                    "warning",
                    "channel_feed_reconnecting",
                    detail: detail
                )
            }
            try? await Task.sleep(nanoseconds: backoff)
            backoff = min(30_000_000_000, backoff * 3)
        }
        feedTasks.removeValue(forKey: channelID)
    }

    private func markChannelAuthorizationLost(_ channelID: UUID, detail: String) {
        channelStatus[channelID] = "成员权限已撤销：\(detail)"
        feedTasks.removeValue(forKey: channelID)?.cancel()
        let ids = state.subscriptions.filter { $0.channelID == channelID }.map(\.id)
        for index in state.subscriptions.indices where state.subscriptions[index].channelID == channelID {
            state.subscriptions[index].enabled = false
        }
        for id in ids { stopListener(id) }
        persistState()
    }

    private func handleFeedMessage(_ json: [String: Any], profile: ChannelProfile) {
        guard let record = messageRecord(json, channelID: profile.id, state: .received) else { return }
        let existing = profile.id == selectedChannelID ? messages : MessageLedger.load(profile.id)
        if existing.contains(where: { $0.id == record.id }) { return }
        var stored = record
        if record.senderMemberID == profile.memberID {
            stored.direction = .outbound
            stored.state = .accepted
        }
        upsertMessage(stored)
        refreshRecoveryPendingMessageCount()
    }
}

extension AppModel {
    func refreshAccount() async {
        do {
            let info = try await requestJSON(
                url: URL(string: "\(defaultOrigin)/api/v1/info")!,
                method: "GET"
            )
            accountFeatureAvailable = (info["features"] as? [String])?.contains("github-account-login") == true
            guard accountFeatureAvailable else {
                accountSession = nil
                accountStatus = "当前服务端尚未启用账号登录"
                return
            }
            guard let credential = try KeychainStore.get(service: keychainService, account: accountSessionKey),
                  !credential.isEmpty else {
                accountSession = nil
                accountStatus = "未登录"
                return
            }
            do {
                let json = try await requestJSON(
                    url: URL(string: "\(defaultOrigin)/v1/session")!,
                    method: "GET",
                    bearer: credential
                )
                accountSession = try accountSessionValue(json)
                accountStatus = "已登录"
            } catch is ChannelAuthorizationFailure {
                try? KeychainStore.delete(service: keychainService, account: accountSessionKey)
                accountSession = nil
                accountStatus = "登录已失效，请重新登录"
            }
        } catch {
            accountStatus = "暂时无法连接账号服务"
        }
    }

    func loginWithGitHub() {
        guard accountFeatureAvailable, !accountBusy else { return }
        do {
            let verifier = try accountRandomValue()
            let state = try accountRandomValue()
            var components = URLComponents(string: "\(defaultOrigin)/v1/auth/github/start")!
            components.queryItems = [
                URLQueryItem(name: "code_challenge", value: accountPKCEChallenge(verifier)),
                URLQueryItem(name: "client_state", value: state),
                URLQueryItem(name: "device_name", value: Host.current().localizedName ?? "Mac"),
            ]
            guard let url = components.url else { throw AppFailure("登录地址无效") }
            accountBusy = true
            accountStatus = "等待 GitHub 授权…"
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: "pijoo") { [weak self] callbackURL, error in
                Task { @MainActor [weak self] in
                    await self?.finishAccountLogin(callbackURL, error: error, verifier: verifier, state: state)
                }
            }
            session.presentationContextProvider = accountAuthenticationContext
            session.prefersEphemeralWebBrowserSession = false
            accountAuthenticationSession = session
            guard session.start() else { throw AppFailure("无法打开 GitHub 登录") }
        } catch {
            accountBusy = false
            accountStatus = "登录失败"
            fail(error)
        }
    }

    func logoutAccount() async {
        guard !accountBusy else { return }
        do {
            accountBusy = true
            defer { accountBusy = false }
            guard let credential = try KeychainStore.get(service: keychainService, account: accountSessionKey),
                  !credential.isEmpty else {
                accountSession = nil
                accountStatus = "未登录"
                return
            }
            _ = try await requestJSON(
                url: URL(string: "\(defaultOrigin)/v1/session/logout")!,
                method: "POST",
                bearer: credential
            )
            try KeychainStore.delete(service: keychainService, account: accountSessionKey)
            accountSession = nil
            accountStatus = "未登录"
        } catch {
            accountStatus = "退出失败，登录仍然有效"
            fail(error)
        }
    }

    private func finishAccountLogin(_ callbackURL: URL?, error: Error?, verifier: String, state: String) async {
        defer {
            accountBusy = false
            accountAuthenticationSession = nil
        }
        if let error {
            if (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin {
                accountStatus = "已取消登录"
            } else {
                accountStatus = "登录失败"
                fail(error)
            }
            return
        }
        do {
            guard let callbackURL else { throw AppFailure("GitHub 未返回登录结果") }
            let exchangeCode = try accountExchangeCode(from: callbackURL, expectedState: state)
            let json = try await requestJSON(
                url: URL(string: "\(defaultOrigin)/v1/auth/device/exchange")!,
                method: "POST",
                body: ["exchange_code": exchangeCode, "code_verifier": verifier]
            )
            guard let credential = json["session_credential"] as? String, credential.count == 43 else {
                throw AppFailure("服务端未返回有效会话")
            }
            let session = try accountSessionValue(json)
            try KeychainStore.set(credential, service: keychainService, account: accountSessionKey)
            accountSession = session
            accountStatus = "已登录"
        } catch is CancellationError {
            accountStatus = "已取消登录"
        } catch {
            accountStatus = "登录失败"
            fail(error)
        }
    }

    private func accountSessionValue(_ json: [String: Any]) throws -> PijooAccountSession {
        guard let accountID = json["account_id"] as? String, !accountID.isEmpty,
              let deviceID = json["device_id"] as? String, !deviceID.isEmpty,
              let displayName = json["display_name"] as? String, !displayName.isEmpty,
              let expiresAt = json["expires_at"] as? String, !expiresAt.isEmpty else {
            throw AppFailure("服务端返回的账号信息无效")
        }
        return PijooAccountSession(
            accountID: accountID,
            deviceID: deviceID,
            displayName: displayName,
            expiresAt: expiresAt
        )
    }

    private func ensureCodexIntegrationReadyForBinding() -> Bool {
        refreshCodexIntegrationStatus()
        guard codexIntegrationReady else {
            showNotice(title: codexIntegrationBlockingTitle, message: codexIntegrationBlockingMessage)
            return false
        }
        return true
    }

    func refreshCodexIntegrationStatus() {
        let raw = (try? String(contentsOf: AppPaths.codexConfig, encoding: .utf8)) ?? ""
        let mcp = raw.contains(managedConfigStart) && raw.contains(AppPaths.state.path)
        let skill = PijooSkillInstaller.isInstalled()
        codexIntegrationConfigured = mcp && skill
        codexIntegrationNeedsRestart = requiresCodexRestart(
            configured: codexIntegrationConfigured,
            appVersion: currentVersion,
            loadedMCPVersion: loadedCodexMCPVersion
        )
        switch (mcp, skill) {
        case (true, true) where codexIntegrationNeedsRestart:
            codexIntegrationStatus = loadedCodexMCPVersion.map {
                "已配置，ChatGPT 仍在使用 MCP \($0)"
            } ?? "已配置，等待 ChatGPT 加载 MCP \(currentVersion)"
        case (true, true): codexIntegrationStatus = "MCP \(currentVersion) 已加载，Skill 已配置"
        case (true, false): codexIntegrationStatus = "MCP 已配置，Skill 待修复"
        case (false, true): codexIntegrationStatus = "Skill 已配置，MCP 待修复"
        case (false, false): codexIntegrationStatus = "未启用"
        }
    }

    private func showCodexRestartNoticeIfNeeded() {
        guard codexIntegrationNeedsRestart,
              UserDefaults.standard.string(forKey: shownCodexRestartVersionKey) != currentVersion else { return }
        UserDefaults.standard.set(currentVersion, forKey: shownCodexRestartVersionKey)
        DispatchQueue.main.async { [weak self] in
            guard let self, self.codexIntegrationNeedsRestart else { return }
            self.showNotice(
                title: "需要重启 ChatGPT",
                message: "请完全退出并重新打开 ChatGPT，加载 Pijoo MCP \(self.currentVersion)。此提示会在新 MCP 连接后自动消失。"
            )
        }
    }

    private func recordLoadedCodexMCPVersion(_ version: String) {
        loadedCodexMCPVersion = version
        UserDefaults.standard.set(version, forKey: loadedCodexMCPVersionKey)
        refreshCodexIntegrationStatus()
    }

    func enableCodexIntegration() {
        defer { refreshCodexIntegrationStatus() }
        do {
            guard AppPaths.appIsInstalled else { throw AppFailure("请先把 Pijoo.app 移到 Applications 后再启用 Codex 集成") }
            persistState()
            try FileManager.default.createDirectory(at: AppPaths.codexDirectory, withIntermediateDirectories: true)
            let block = CodexConfigEditor.managedBlock(sidecar: Sidecar.executable.path, binding: AppPaths.state.path)
            try CodexIntegrationInstaller.install(
                configURL: AppPaths.codexConfig,
                block: block,
                allowSkillRetargetFromBundleIdentifier: AppPaths.isDevelopmentBuild
                    ? Bundle.main.bundleIdentifier
                    : nil
            )
            loadedCodexMCPVersion = nil
            UserDefaults.standard.removeObject(forKey: loadedCodexMCPVersionKey)
            UserDefaults.standard.set(currentVersion, forKey: shownCodexRestartVersionKey)
            showNotice(title: "Codex 集成已启用", message: "请完全退出并重新打开 ChatGPT，让所有 task 加载 Pijoo 工具与 Skill。")
        } catch {
            fail(error)
        }
    }

    func removeCodexIntegration() {
        defer { refreshCodexIntegrationStatus() }
        do {
            try CodexIntegrationInstaller.remove(configURL: AppPaths.codexConfig)
            loadedCodexMCPVersion = nil
            UserDefaults.standard.removeObject(forKey: loadedCodexMCPVersionKey)
            UserDefaults.standard.removeObject(forKey: shownCodexRestartVersionKey)
        } catch {
            fail(error)
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            guard AppPaths.appIsInstalled else { throw AppFailure("请先把 App 移到 Applications") }
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            launchAtLogin = SMAppService.mainApp.status == .enabled
        } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            fail(error)
        }
    }

    func clearSelectedHistory() {
        guard let profile = selectedChannel else { return }
        try? MessageLedger.remove(profile.id)
        for subscription in state.subscriptions where subscription.channelID == profile.id {
            try? MessageLedger.removeDeliveries(subscription.id)
        }
        messages = []
    }

    func setAutomaticUpdateChecks(_ enabled: Bool) {
        automaticUpdateChecks = enabled
        UserDefaults.standard.set(enabled, forKey: automaticUpdateChecksKey)
        configureAutomaticUpdateChecks()
    }

    private func configureAutomaticUpdateChecks() {
        updateTimer?.invalidate()
        updateTimer = nil
        guard automaticUpdateChecks else { return }
        Task { await checkBetaUpdate(interactive: false) }
        updateTimer = Timer.scheduledTimer(withTimeInterval: 24 * 60 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.checkBetaUpdate(interactive: false) }
        }
    }

    func checkBetaUpdate(interactive: Bool = true) async {
        if let pending = UpdateCoordinator.pendingVersion() {
            updateStatus = "已下载 " + pending + "，重启后安装"
            if interactive { showNotice(title: "Pijoo", message: "更新 " + pending + " 已下载，重启 App 后自动安装。") }
            return
        }
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            var request = URLRequest(url: githubReleasesURL)
            request.setValue("Pijoo/\(currentVersion)", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw AppFailure("GitHub Release 查询失败") }
            let releases = try JSONDecoder().decode([GitHubRelease].self, from: data)
            guard let current = ReleaseVersion(currentVersion) else { throw AppFailure("当前版本号无效") }
            let available = releases.filter { !$0.draft && $0.prerelease && $0.version.map { current < $0 } == true }
                .sorted { ($0.version ?? current) > ($1.version ?? current) }
            guard let release = available.first, let version = release.version else {
                updateStatus = "已是最新 Beta"
                if interactive { showNotice(title: "Pijoo", message: "当前已是最新 Beta。") }
                return
            }
            guard let dmg = release.arm64DMG else {
                updateStatus = "\(version) 缺少 arm64 更新包"
                if interactive { NSWorkspace.shared.open(release.htmlURL) }
                return
            }
            if interactive {
                let alert = NSAlert()
                alert.messageText = "发现 Pijoo Beta 更新"
                alert.informativeText = "当前 \(current)，最新 \(version)。下载后只需重启 App 即可完成更新。"
                alert.addButton(withTitle: "下载更新")
                alert.addButton(withTitle: "取消")
                guard alert.runModal() == .alertFirstButtonReturn else { return }
            }
            updateStatus = "正在下载 \(version)…"
            let (temporaryURL, downloadResponse) = try await URLSession.shared.download(from: dmg)
            guard (downloadResponse as? HTTPURLResponse)?.statusCode == 200 else { throw AppFailure("更新包下载失败") }
            try UpdateCoordinator.saveDownloadedDMG(temporaryURL, version: version.description)
            updateStatus = "已下载 \(version)，重启后安装"
            if interactive { showNotice(title: "更新已下载", message: "重启 Pijoo 后将自动安装 \(version)。") }
        } catch {
            updateStatus = "检查失败"
            if interactive { fail(error) }
        }
    }

    func removeAllV2Data() {
        let alert = NSAlert()
        alert.messageText = "移除 0.3 Beta 本机配置？"
        alert.informativeText = "将停止监听并删除 0.3 频道凭证、订阅和本地消息。旧 0.2 数据不会被修改。"
        alert.addButton(withTitle: "移除")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        for id in Set(listeners.keys).union(startingListeners) { stopListener(id) }
        for task in feedTasks.values { task.cancel() }
        feedTasks.removeAll()
        for profile in state.channels {
            try? KeychainStore.delete(service: keychainService, account: profile.credentialAccount)
            try? MessageLedger.remove(profile.id)
        }
        for subscription in state.subscriptions { try? MessageLedger.removeDeliveries(subscription.id) }
        state = AppStateV2(defaultCallsign: generatedLocalNickname())
        draftNickname = state.defaultCallsign
        selectedChannelID = nil
        messages = []
        members = []
        invitations = []
        listenerStatus = [:]
        hostConversationStates = [:]
        automaticallyReconnectingTaskIDs.removeAll()
        channelStatus = [:]
        try? FileManager.default.removeItem(at: AppPaths.state)
        removeCodexIntegration()
    }

    func quit() {
        shutdown()
        NSApplication.shared.terminate(nil)
    }

    func shutdown() {
        ClientLog.record("info", "app_shutdown")
        for id in Set(listeners.keys).union(startingListeners) { stopListener(id) }
        for task in feedTasks.values { task.cancel() }
        feedTasks.removeAll()
        localSendServer?.stop()
        localSendServer = nil
    }

    fileprivate func fail(_ error: Error) {
        guard !isCancellationError(error) else { return }
        ClientLog.record("error", "operation_failed", detail: error.localizedDescription)
        showNotice(title: "Pijoo", message: error.localizedDescription)
    }

    func exportClientLog() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        panel.nameFieldStringValue = "Pijoo-client-\(formatter.string(from: Date())).log"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            ClientLog.record("info", "client_log_exported")
            try ClientLog.export(to: destination)
            showNotice(title: "客户端日志已导出", message: destination.path)
        } catch {
            fail(AppFailure("导出客户端日志失败：\(error.localizedDescription)"))
        }
    }

    fileprivate func showNotice(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        alert.runModal()
    }
}

extension AppModel {
    func saveNickname() async {
        do {
            let nickname = try normalizedDisplayName(draftNickname, label: "昵称")
            state.defaultCallsign = nickname
            draftNickname = nickname
            persistState()
            var failed = 0
            for profile in state.channels {
                do {
                    _ = try await authorizedJSON(
                        profile,
                        suffix: "members/me",
                        method: "PATCH",
                        body: ["name": nickname]
                    )
                } catch {
                    failed += 1
                }
            }
            if failed > 0 {
                showNotice(title: "昵称已保存", message: "\(failed) 个频道暂未同步，将在下次连接时自动使用新昵称。")
            }
            await refreshMembers()
        } catch {
            fail(error)
        }
    }
}
extension AppModel {
    func createChannel() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            let nickname = try normalizedDisplayName(state.defaultCallsign, label: "昵称")
            let channelName = try normalizedDisplayName(draftChannelName, label: "频道名称")
            let url = URL(string: "\(defaultOrigin)/api/channels")!
            let json = try await requestJSON(
                url: url,
                method: "POST",
                body: [
                    "api_version": 2,
                    "retention": "none",
                    "trust_mode": "untrusted",
                    "name": nickname,
                    "channel_name": channelName,
                ]
            )
            guard let channel = json["channel_id"] as? String,
                  let credential = (json["member_credential"] as? String) ?? (json["join_token"] as? String) else {
                throw AppFailure("服务端未返回频道成员凭证")
            }
            let memberID = (json["member_id"] as? String) ?? "owner"
            let profileID = UUID()
            let account = "channel:\(profileID.uuidString):credential"
            try KeychainStore.set(credential, service: keychainService, account: account)
            let profile = ChannelProfile(
                id: profileID,
                origin: defaultOrigin,
                channel: channel,
                displayName: (json["channel_name"] as? String) ?? channelName,
                callsign: internalCallsign(memberID),
                memberID: memberID,
                role: (json["role"] as? String) ?? "owner",
                credentialAccount: account,
                lastViewedMessageID: nil
            )
            state.channels.append(profile)
            draftChannelName = ""
            selectedChannelID = profile.id
            persistState()
            startChannelFeed(profile.id)
            refreshSelectedChannel()
            lastError = ""
        } catch {
            fail(error)
        }
    }

    func joinInvitation() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            let nickname = try normalizedDisplayName(state.defaultCallsign, label: "昵称")
            let invitation = try InvitationCodec.decode(invitationInput)
            guard !alreadyJoinedChannel(state.channels, invitation: invitation) else {
                throw AppFailure("本机已加入该频道，不能重复加入")
            }
            guard let encoded = invitation.channel.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
                  let url = URL(string: "\(invitation.origin)/api/channels/\(encoded)/invites/redeem") else {
                throw AppFailure("邀请地址无效")
            }
            let json = try await requestJSON(
                url: url,
                method: "POST",
                body: ["invite_token": invitation.inviteToken, "name": nickname]
            )
            guard let credential = json["member_credential"] as? String,
                  let memberID = json["member_id"] as? String else {
                throw AppFailure("邀请兑换失败：服务端未返回成员凭证")
            }
            let profileID = UUID()
            let account = "channel:\(profileID.uuidString):credential"
            try KeychainStore.set(credential, service: keychainService, account: account)
            let profile = ChannelProfile(
                id: profileID,
                origin: invitation.origin,
                channel: invitation.channel,
                displayName: (json["channel_name"] as? String) ?? invitation.channel,
                callsign: internalCallsign(memberID),
                memberID: memberID,
                role: (json["role"] as? String) ?? "member",
                credentialAccount: account,
                lastViewedMessageID: nil
            )
            state.channels.append(profile)
            invitationInput = ""
            selectedChannelID = profile.id
            persistState()
            startChannelFeed(profile.id)
            refreshSelectedChannel()
            lastError = ""
        } catch {
            fail(error)
        }
    }

    func createInvitation(label: String, maxUses: Int, validHours: Int) async -> Bool {
        guard !busy, let profile = selectedChannel, profile.role == "owner" else { return false }
        let normalizedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedLabel.utf16.count <= 64, (1...100).contains(maxUses), (1...720).contains(validHours) else {
            fail(AppFailure("邀请备注最多 64 个字符，可加入人数为 1–100，有效期为 1–720 小时"))
            return false
        }
        busy = true
        defer { busy = false }
        do {
            let json = try await authorizedJSON(
                profile,
                suffix: "invites",
                method: "POST",
                body: [
                    "label": normalizedLabel,
                    "max_uses": maxUses,
                    "expires_in_seconds": validHours * 60 * 60,
                ]
            )
            guard let token = json["invite_token"] as? String else {
                throw AppFailure("服务端未返回邀请凭证")
            }
            let code = try InvitationCodec.encode(ChannelInvitation(
                version: 2,
                origin: profile.origin,
                channel: profile.channel,
                inviteToken: token
            ))
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(code, forType: .string)
            await refreshInvitations()
            showNotice(title: "邀请已创建并复制", message: "对方粘贴 ac2: 邀请口令即可加入；服务端不会保存或再次展示明文口令。")
            return true
        } catch {
            fail(error)
            return false
        }
    }

    func refreshInvitations() async {
        guard let profile = selectedChannel, profile.role == "owner" else {
            invitations = []
            return
        }
        do {
            let json = try await authorizedJSON(profile, suffix: "invites", method: "GET")
            guard selectedChannelID == profile.id else { return }
            guard let raw = json["invitations"], JSONSerialization.isValidJSONObject(raw) else {
                invitations = []
                return
            }
            invitations = try JSONDecoder().decode(
                [ChannelInvite].self,
                from: JSONSerialization.data(withJSONObject: raw)
            )
        } catch {
            guard !isCancellationError(error), !Task.isCancelled else { return }
            guard selectedChannelID == profile.id else { return }
            lastError = "刷新邀请失败：\(error.localizedDescription)"
        }
    }

    func revokeInvitation(_ invitation: ChannelInvite) async {
        guard let profile = selectedChannel, profile.role == "owner", invitation.status == "active" else { return }
        let alert = NSAlert()
        alert.messageText = "撤销邀请？"
        alert.informativeText = "撤销只阻止后续加入，已经通过此邀请加入的成员不会被移除。"
        alert.addButton(withTitle: "撤销")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            _ = try await authorizedJSON(profile, suffix: "invites/\(invitation.inviteID)", method: "DELETE")
            await refreshInvitations()
        } catch {
            fail(error)
        }
    }

    func removeSelectedChannel() {
        guard let profile = selectedChannel else { return }
        let alert = NSAlert()
        alert.messageText = "从本机移除 \(profile.displayName)？"
        alert.informativeText = "将停止该频道向全部会话的消息转发，并删除本机成员凭证与消息历史。"
        alert.addButton(withTitle: "移除")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        feedTasks.removeValue(forKey: profile.id)?.cancel()
        channelStatus.removeValue(forKey: profile.id)
        for subscription in state.subscriptions where subscription.channelID == profile.id {
            stopListener(subscription.id)
            try? MessageLedger.removeDeliveries(subscription.id)
        }
        try? KeychainStore.delete(service: keychainService, account: profile.credentialAccount)
        try? MessageLedger.remove(profile.id)
        let removedTaskIDs = Set(state.subscriptions.filter { $0.channelID == profile.id }.map(\.taskID))
        state.subscriptions.removeAll { $0.channelID == profile.id }
        state.channels.removeAll { $0.id == profile.id }
        state.tasks.removeAll { task in
            removedTaskIDs.contains(task.id) && !state.subscriptions.contains { $0.taskID == task.id }
        }
        for taskID in removedTaskIDs where !state.tasks.contains(where: { $0.id == taskID }) {
            hostConversationStates.removeValue(forKey: taskID)
            automaticallyReconnectingTaskIDs.remove(taskID)
        }
        selectedChannelID = state.channels.first?.id
        persistState()
        refreshSelectedChannel()
    }

    func renameSelectedChannel() {
        guard let selectedChannelID,
              let index = state.channels.firstIndex(where: { $0.id == selectedChannelID }) else { return }
        let profile = state.channels[index]
        let field = NSTextField(string: profile.displayName == profile.channel ? "" : profile.displayName)
        field.placeholderString = profile.channel
        field.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
        let alert = NSAlert()
        alert.messageText = "修改频道昵称"
        alert.informativeText = "频道 ID：\(profile.channel)；留空恢复服务端频道名称。"
        alert.accessoryView = field
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let nickname = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard nickname.count <= 64 else {
            showNotice(title: "Pijoo", message: "频道昵称不能超过 64 个字符")
            return
        }
        state.channels[index].displayName = channelDisplayName(nickname, original: profile.channel)
        persistState()
    }

    private func syncChannelHistory(_ profile: ChannelProfile) async throws {
        let json = try await authorizedJSON(profile, suffix: "history?limit=100", method: "GET")
        let entries = (json["history"] as? [[String: Any]]) ?? []
        var knownIDs = Set(MessageLedger.load(profile.id).map(\.id))
        for entry in entries {
            guard var record = messageRecord(entry, channelID: profile.id, state: .received) else { continue }
            let alreadyPersisted = !knownIDs.insert(record.id).inserted
            if alreadyPersisted,
               (profile.id != selectedChannelID || messages.contains(where: { $0.id == record.id })) { continue }
            if record.senderMemberID == profile.memberID {
                record.direction = .outbound
                record.state = .accepted
            }
            upsertMessage(record, persist: !alreadyPersisted)
        }
        refreshRecoveryPendingMessageCount()
    }

    func reconcileChannelFeedsAndHistory() async {
        refreshCodexIntegrationStatus()
        for profile in state.channels {
            startChannelFeed(profile.id)
            do {
                try await syncChannelHistory(profile)
            } catch {
                guard !isCancellationError(error), !Task.isCancelled else { return }
                ClientLog.record("warning", "channel_history_reconcile_failed", detail: "channel=\(profile.channel) error=\(error.localizedDescription)")
            }
        }
    }

    func prepareForSystemSleep() {
        sleepStartedAt = Date()
        recoveryPausedSubscriptionIDs = Set(state.subscriptions.filter(\.enabled).map(\.id))
        for id in recoveryPausedSubscriptionIDs {
            stopListener(id)
            listenerStatus[id] = "系统休眠，已暂停"
        }
    }

    private func refreshRecoveryPendingMessageCount() {
        var pending: Set<String> = []
        for subscription in state.subscriptions where recoveryPausedSubscriptionIDs.contains(subscription.id) {
            let records = pendingRecoveryMessages(
                after: subscription.lastDeliveredMessageID,
                records: MessageLedger.load(subscription.channelID)
            )
            for record in records { pending.insert("\(subscription.id.uuidString):\(record.id)") }
        }
        recoveryPendingMessageCount = pending.count
    }

    func resumeAfterSystemWake() async {
        let sleptFor = sleepStartedAt.map { Date().timeIntervalSince($0) } ?? 0
        sleepStartedAt = nil
        await reconcileChannelFeedsAndHistory()
        guard sleptFor >= 60 else {
            approveRecoveryDelivery()
            return
        }

        for subscription in state.subscriptions where recoveryPausedSubscriptionIDs.contains(subscription.id) {
            listenerStatus[subscription.id] = "休眠恢复，等待确认"
        }
        refreshRecoveryPendingMessageCount()
        guard recoveryPendingMessageCount > 0 else {
            approveRecoveryDelivery()
            return
        }

        let alert = NSAlert()
        alert.messageText = "休眠期间收到新消息"
        alert.informativeText = "检测到 \(recoveryPendingMessageCount) 条待检查消息。只有点击“发送到会话”后，符合订阅规则的消息才会创建 AI turn。"
        alert.addButton(withTitle: "发送到会话")
        alert.addButton(withTitle: "暂不发送")
        if alert.runModal() == .alertFirstButtonReturn { approveRecoveryDelivery() }
    }

    func approveRecoveryDelivery() {
        let ids = recoveryPausedSubscriptionIDs
        recoveryPausedSubscriptionIDs.removeAll()
        recoveryPendingMessageCount = 0
        for id in ids where state.subscriptions.first(where: { $0.id == id })?.enabled == true {
            Task { await startListener(id) }
        }
    }

    func refreshHistory() async {
        guard let profile = selectedChannel else { return }
        do {
            try await syncChannelHistory(profile)
            guard selectedChannelID == profile.id else { return }
            lastError = ""
        } catch {
            guard !isCancellationError(error), !Task.isCancelled else { return }
            guard selectedChannelID == profile.id else { return }
            lastError = "刷新消息失败：\(error.localizedDescription)"
        }
    }

    func refreshMembers() async {
        guard let profile = selectedChannel else { return }
        do {
            let json = try await authorizedJSON(profile, suffix: "members", method: "GET")
            guard selectedChannelID == profile.id else { return }
            guard let raw = json["members"], JSONSerialization.isValidJSONObject(raw) else {
                members = []
                return
            }
            let data = try JSONSerialization.data(withJSONObject: raw)
            members = try JSONDecoder().decode([ChannelMember].self, from: data)
        } catch {
            guard !isCancellationError(error), !Task.isCancelled else { return }
            guard selectedChannelID == profile.id else { return }
            lastError = "刷新成员失败：\(error.localizedDescription)"
        }
    }

    func removeMember(_ member: ChannelMember, ban: Bool) async {
        guard let profile = selectedChannel, profile.role == "owner", member.memberID != profile.memberID else { return }
        let alert = NSAlert()
        alert.messageText = ban ? "封禁成员 \(member.name)？" : "移除成员 \(member.name)？"
        alert.informativeText = ban
            ? "该成员的现有凭证、Session 和消息流会立即失效；对方仍可持新邀请创建新成员。"
            : "该成员的现有凭证、Session 和消息流会立即失效。"
        alert.addButton(withTitle: ban ? "封禁" : "移除")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            let suffix = ban ? "members/\(member.memberID)/ban" : "members/\(member.memberID)"
            _ = try await authorizedJSON(profile, suffix: suffix, method: ban ? "POST" : "DELETE")
            await refreshMembers()
        } catch {
            fail(error)
        }
    }

    func unbanMember(_ member: ChannelMember) async {
        guard let profile = selectedChannel, profile.role == "owner", member.status == "banned" else { return }
        do {
            _ = try await authorizedJSON(profile, suffix: "members/\(member.memberID)/unban", method: "POST")
            await refreshMembers()
        } catch {
            fail(error)
        }
    }

    func sendComposerMessage() async {
        guard !busy, let profile = selectedChannel else { return }
        let text = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let mentions = composerMentions
        let mentionSnapshot = composerMentionSnapshot
        let pending = ChannelMessageRecord(
            channelID: profile.id,
            messageID: "local-\(UUID().uuidString.lowercased())",
            direction: .outbound,
            from: state.defaultCallsign,
            to: "all",
            text: text,
            at: Date().timeIntervalSince1970 * 1000,
            state: .pending,
            source: MessageSourceReference(provider: "pijoo", label: "Pijoo App"),
            mention: mentionSnapshot
        )
        upsertMessage(pending, persist: false)
        busy = true
        defer { busy = false }
        do {
            let result = try await sendChannelMessage(
                text,
                profile: profile,
                endpoint: endpointCallsign(profile, kind: "app"),
                source: MessageSourceReference(provider: "pijoo", label: "Pijoo App"),
                mentions: mentions
            )
            composerText = ""
            clearComposerMentions()
            messages.removeAll { $0.id == pending.id }
            upsertMessage(ChannelMessageRecord(
                channelID: profile.id,
                messageID: result.id,
                direction: .outbound,
                from: state.defaultCallsign,
                to: "all",
                text: text,
                at: Date().timeIntervalSince1970 * 1000,
                state: .accepted,
                senderMemberID: result.memberID,
                senderEndpointID: result.endpointID,
                source: MessageSourceReference(provider: "pijoo", label: "Pijoo App"),
                mention: result.mention
            ))
        } catch {
            var final = pending
            if case ChannelSendFailure.unknown = error { final.state = .unknown }
            else { final.state = .failed }
            upsertMessage(final)
            fail(error)
        }
    }

    private func sendChannelMessage(
        _ message: String,
        profile: ChannelProfile,
        endpoint: String,
        source: MessageSourceReference,
        mentions: [String] = []
    ) async throws -> (id: String, callsign: String, memberID: String, endpointID: String, mention: MessageMention?) {
        guard !message.isEmpty, message.utf16.count <= maxChannelMessageLength else {
            throw ChannelSendFailure.definitive("消息须为 1–\(maxChannelMessageLength) 个字符")
        }
        let credential: String
        do {
            guard let value = try KeychainStore.get(service: keychainService, account: profile.credentialAccount), !value.isEmpty else {
                throw AppFailure("Keychain 中没有频道成员凭证")
            }
            credential = value
        } catch {
            throw ChannelSendFailure.definitive(error.localizedDescription)
        }
        let base = try channelBaseURL(profile)
        let join: [String: Any]
        do {
            join = try await requestJSON(
                url: base.appendingPathComponent("join"),
                method: "POST",
                bearer: credential,
                body: ["callsign": endpoint, "name": state.defaultCallsign]
            )
        } catch {
            throw ChannelSendFailure.definitive("频道加入失败：\(error.localizedDescription)")
        }
        guard let session = join["session_id"] as? String, !session.isEmpty,
              let memberID = join["member_id"] as? String, !memberID.isEmpty,
              let endpointID = join["endpoint_id"] as? String, !endpointID.isEmpty else {
            throw ChannelSendFailure.definitive("频道加入响应缺少 session/member/endpoint")
        }
        do {
            _ = try reconcileChannelMemberIdentity(profile, authenticatedMemberID: memberID)
        } catch {
            throw ChannelSendFailure.definitive("频道身份同步失败：\(error.localizedDescription)")
        }
        do {
            var sourceJSON: [String: Any] = ["provider": source.provider]
            if let conversationID = source.conversationID { sourceJSON["conversation_id"] = conversationID }
            if let label = source.label { sourceJSON["label"] = label }
            var body: [String: Any] = ["to": "all", "message": message, "source": sourceJSON]
            if !mentions.isEmpty { body["mentions"] = mentions }
            let json = try await requestJSON(
                url: base.appendingPathComponent("send"),
                method: "POST",
                bearer: credential,
                headers: ["X-Session-Id": session],
                body: body
            )
            guard json["ok"] as? Bool == true else {
                throw ChannelSendFailure.unknown("频道发送结果未知：服务端未返回有效回执")
            }
            let mention = messageMention(json["mention"])
            let confirmedMentions = mention?.kind == "all" ? ["all"] : mention?.members?.map(\.memberID) ?? []
            guard confirmedMentions == mentions else {
                throw ChannelSendFailure.unknown("频道已接收消息，但没有确认完整的 @ 成员")
            }
            if let id = json["id"] as? String { return (id, endpoint, memberID, endpointID, mention) }
            if let id = json["id"] as? NSNumber { return (id.stringValue, endpoint, memberID, endpointID, mention) }
            throw ChannelSendFailure.unknown("频道发送结果未知：回执缺少消息 ID")
        } catch let error as ChannelSendFailure {
            throw error
        } catch {
            throw ChannelSendFailure.unknown("频道发送结果未知：\(error.localizedDescription)")
        }
    }

    private func authorizedJSON(
        _ profile: ChannelProfile,
        suffix: String,
        method: String,
        body: [String: Any]? = nil
    ) async throws -> [String: Any] {
        guard let credential = try KeychainStore.get(service: keychainService, account: profile.credentialAccount),
              !credential.isEmpty else { throw AppFailure("Keychain 中没有频道成员凭证") }
        let base = try channelBaseURL(profile)
        let components = suffix.split(separator: "?", maxSplits: 1).map(String.init)
        var url = base
        for segment in components[0].split(separator: "/") { url.appendPathComponent(String(segment)) }
        if components.count == 2 {
            var urlComponents = URLComponents(url: url, resolvingAgainstBaseURL: false)
            urlComponents?.percentEncodedQuery = components[1]
            if let resolved = urlComponents?.url { url = resolved }
        }
        return try await requestJSON(url: url, method: method, bearer: credential, body: body)
    }

    private func requestJSON(
        url: URL,
        method: String,
        bearer: String? = nil,
        headers: [String: String] = [:],
        body: [String: Any]? = nil
    ) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let bearer { request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard (200..<300).contains(status) else {
            let message = (object?["error"] as? String) ?? "频道服务请求失败（HTTP \(status)）"
            if status == 401 || object?["code"] as? String == "member_revoked" {
                throw ChannelAuthorizationFailure(message: message)
            }
            throw AppFailure(message)
        }
        return object ?? [:]
    }

    private func channelBaseURL(_ profile: ChannelProfile) throws -> URL {
        let encoded = profile.channel.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? profile.channel
        guard let url = URL(string: "\(profile.origin)/api/channels/\(encoded)") else {
            throw AppFailure("频道地址无效")
        }
        return url
    }

    private func normalizedDisplayName(_ raw: String, label: String) throws -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf16.count <= 64 else {
            throw AppFailure("\(label)须为 1–64 个字符")
        }
        return value
    }

    private func internalCallsign(_ memberID: String) -> String {
        "agent-\(memberID.lowercased().filter { $0.isLetter || $0.isNumber }.prefix(10))"
    }

    private func memberEndpointPrefix(_ profile: ChannelProfile) -> String {
        let member = profile.memberID.lowercased().filter { $0.isLetter || $0.isNumber }.prefix(12)
        return "m\(member)-"
    }

    private func endpointCallsign(_ profile: ChannelProfile, conversationID: String? = nil, kind: String) -> String {
        let base = profile.callsign.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }.prefix(6)
        if let conversationID, let task = compactTaskKey(conversationID) {
            return String("\(base.prefix(4))-\(kind.prefix(1))\(task)".prefix(32))
        }
        let task = ""
        return String("\(memberEndpointPrefix(profile))\(base)-\(kind)\(task)".prefix(32))
    }

    private func messageMention(_ value: Any?) -> MessageMention? {
        guard let value, JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value) else { return nil }
        return try? JSONDecoder().decode(MessageMention.self, from: data)
    }

    private func messageRecord(
        _ json: [String: Any],
        channelID: UUID,
        state: MessageDeliveryState
    ) -> ChannelMessageRecord? {
        let id: String
        if let value = json["id"] as? NSNumber { id = value.stringValue }
        else if let value = json["id"] as? String { id = value }
        else { return nil }
        let at: Double
        if let value = json["at"] as? NSNumber { at = value.doubleValue }
        else { at = Date().timeIntervalSince1970 * 1000 }
        let source = (json["source"] as? [String: Any]).flatMap { value -> MessageSourceReference? in
            guard let provider = value["provider"] as? String else { return nil }
            return MessageSourceReference(
                provider: provider,
                conversationID: value["conversation_id"] as? String,
                label: value["label"] as? String
            )
        }
        return ChannelMessageRecord(
            channelID: channelID,
            messageID: id,
            direction: .inbound,
            from: (json["sender_name"] as? String) ?? (json["from"] as? String) ?? "unknown",
            to: (json["to"] as? String) ?? "all",
            text: (json["text"] as? String) ?? "",
            at: at,
            state: state,
            senderMemberID: json["sender_member_id"] as? String,
            senderEndpointID: json["sender_endpoint_id"] as? String,
            source: source,
            mention: messageMention(json["mention"])
        )
    }

    private func upsertMessage(_ record: ChannelMessageRecord, persist: Bool = true) {
        if record.channelID == selectedChannelID {
            messages = upsertedMessages(record, into: messages)
        }
        if persist { try? MessageLedger.append(record) }
        ClientLog.record(
            "info",
            "message_upsert",
            detail: "channel_id=\(record.channelID.uuidString.lowercased()) message_id=\(clientLogField(record.messageID)) selected=\(record.channelID == selectedChannelID) direction=\(record.direction.rawValue) state=\(record.state.rawValue)"
        )
        if record.channelID == selectedChannelID {
            markSelectedChannelRead()
        } else {
            objectWillChange.send()
        }
    }
}
