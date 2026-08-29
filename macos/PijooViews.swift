import AppKit
import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct V2MenuPanel: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    private var statusColor: Color {
        if !model.lastError.isEmpty { return .red }
        if model.enabledSubscriptionCount == 0 { return .secondary }
        if model.disconnectedConversationCount > 0 { return .orange }
        return model.runningListenerCount == model.enabledSubscriptionCount ? .green : .orange
    }

    private func openMainWindow() {
        openWindow(id: "main")
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            guard let window = NSApp.windows.first(where: {
                $0.level == .normal && $0.canBecomeMain
            }) else { return }
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                BrandIcon(fallback: model.menuIcon, size: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Pijoo").font(.headline)
                    HStack(spacing: 5) {
                        Circle().fill(statusColor).frame(width: 7, height: 7)
                        Text(model.disconnectedConversationCount > 0
                            ? "\(model.state.channels.count) 个频道 · \(model.disconnectedConversationCount) 个会话未连接"
                            : "\(model.state.channels.count) 个频道 · \(model.runningListenerCount)/\(model.enabledSubscriptionCount) 个监听")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
            }
            if !model.lastError.isEmpty {
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text(model.lastError).lineLimit(3)
                }
                .font(.caption)
                .foregroundStyle(.red)
                .padding(9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }
            Button(action: openMainWindow) {
                Label("打开 Pijoo", systemImage: "arrow.up.forward.app")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            Divider()
            HStack {
                if model.enabledSubscriptionCount > 0 {
                    Button { model.setAllListening(false) } label: {
                        Label("暂停监听", systemImage: "pause.fill")
                    }
                } else if !model.state.subscriptions.isEmpty {
                    Button { model.setAllListening(true) } label: {
                        Label("恢复监听", systemImage: "play.fill")
                    }
                }
                Spacer()
                Button("退出") { model.quit() }
            }
            .controlSize(.small)
        }
        .padding(14)
        .frame(width: 330)
    }
}

enum MainDestination: Hashable {
    case channel(UUID)
    case settings
}

struct MainWindowView: View {
    @ObservedObject var model: AppModel
    @AppStorage("legacyBetaNoticeDismissed") private var legacyBetaNoticeDismissed = false
    @State private var showingSettings = false

    private var destination: Binding<MainDestination?> {
        Binding(
            get: {
                if showingSettings { return .settings }
                return model.selectedChannelID.map(MainDestination.channel)
            },
            set: { value in
                switch value {
                case .channel(let id):
                    showingSettings = false
                    model.selectChannel(id)
                case .settings:
                    showingSettings = true
                case nil:
                    showingSettings = false
                    model.selectChannel(nil)
                }
            }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            if model.disconnectedConversationCount > 0 {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Label("\(model.disconnectedConversationCount) 个关联会话未连接", systemImage: "link.badge.plus")
                            .font(.callout.bold())
                        Text("频道消息暂时无法转发，正在后台自动连接。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.orange.opacity(0.12), ignoresSafeAreaEdges: [])
                Divider()
            }
            if model.recoveryPendingMessageCount > 0 {
                HStack {
                    Label("休眠恢复：\(model.recoveryPendingMessageCount) 条消息等待发送到 AI 会话", systemImage: "moon.zzz")
                    Spacer()
                    Button("发送到会话") { model.approveRecoveryDelivery() }
                        .buttonStyle(.borderedProminent)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.yellow.opacity(0.15))
                Divider()
            }
            channelWorkspace
        }
    }

    private var channelWorkspace: some View {
        NavigationSplitView {
            List(selection: destination) {
                Section {
                    ForEach(model.state.channels) { channel in
                        HStack {
                            Circle()
                                .fill(model.channelStatus[channel.id] == "已连接" ? .green : .secondary.opacity(0.4))
                                .frame(width: 7, height: 7)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(model.channelTitle(channel)).lineLimit(1)
                                Text(channel.role == "owner" ? "所有者" : "成员")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if model.channelHasDisconnectedConversation(channel.id) {
                                Circle()
                                    .fill(.red)
                                    .frame(width: 8, height: 8)
                                    .accessibilityLabel("此频道有会话未连接")
                            }
                            let unread = model.unreadCount(channel.id)
                            if unread > 0 {
                                Text("\(unread)")
                                    .font(.caption2.bold())
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(.blue, in: Capsule())
                                    .foregroundStyle(.white)
                            }
                        }
                        .tag(MainDestination.channel(channel.id))
                    }
                } header: {
                    HStack {
                        Text("对话")
                        Spacer()
                        Button {
                            showingSettings = false
                            model.showAddChannel = true
                        } label: {
                            Image(systemName: "plus")
                                .padding(3)
                        }
                        .buttonStyle(.borderless)
                        .disabled(model.accountSession == nil)
                        .help("添加对话")
                        .accessibilityLabel("添加对话")
                    }
                    .accessibilityElement(children: .contain)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Button {
                    destination.wrappedValue = .settings
                } label: {
                    Label("设置", systemImage: "gearshape")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .contentShape(Rectangle())
                        .overlay(alignment: .trailing) {
                            if model.codexIntegrationNeedsRestart {
                                Circle()
                                    .fill(.orange)
                                    .frame(width: 8, height: 8)
                                    .padding(.trailing, 10)
                                    .accessibilityLabel("设置中有需要处理的提示")
                            }
                        }
                }
                .buttonStyle(.plain)
                .foregroundStyle(showingSettings ? .white : .primary)
                .background(showingSettings ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 6))
                .padding(8)
            }
            .navigationTitle("Pijoo")
        } detail: {
            if showingSettings {
                PijooSettingsView(model: model)
            } else if model.accountSession == nil {
                EmptyStateView(
                    title: "登录后恢复对话",
                    systemImage: "person.crop.circle.badge.checkmark",
                    detail: "使用 GitHub 登录后，只会显示这个账号加入的对话。"
                ) {
                    Button("前往设置登录") { showingSettings = true }
                        .buttonStyle(.borderedProminent)
                }
            } else if let channel = model.selectedChannel {
                ChannelDetailView(model: model, channel: channel)
            } else {
                EmptyStateView(
                    title: "还没有频道",
                    systemImage: "bubble.left.and.bubble.right",
                    detail: "创建一个频道后即可与 AI 对话或邀请成员。"
                ) {
                    Button("创建频道") { model.showAddChannel = true }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .sheet(isPresented: $model.showAddChannel) {
            AddChannelSheet(model: model)
        }
        .safeAreaInset(edge: .top) {
            if model.oldBetaDataDetected && !legacyBetaNoticeDismissed {
                HStack {
                    Image(systemName: "info.circle")
                    Text("检测到 0.2 Beta 数据。0.3 不会读取、迁移、覆盖或删除它，请重新配置频道。")
                    Spacer()
                    Button {
                        legacyBetaNoticeDismissed = true
                    } label: {
                        Image(systemName: "xmark")
                            .accessibilityLabel("关闭提示")
                    }
                    .buttonStyle(.plain)
                }
                .font(.caption)
                .padding(8)
                .background(.yellow.opacity(0.15))
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await model.refreshHostConversationStates() }
        }
    }
}

enum AddChannelMode: Hashable {
    case create
    case join
}

struct AddChannelSheet: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var mode = AddChannelMode.create

    private var actionDisabled: Bool {
        model.busy
            || model.accountSession == nil
            || model.state.defaultCallsign.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || (mode == .create && model.draftChannelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            || (mode == .join && model.invitationInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private var actionTitle: String {
        switch mode {
        case .create: return "创建频道"
        case .join: return "加入频道"
        }
    }

    private func submit() {
        guard !actionDisabled else { return }
        let count = model.state.channels.count
        Task {
            if mode == .create {
                await model.createChannel()
            } else {
                await model.joinInvitation()
            }
            if model.state.channels.count > count { dismiss() }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Text("添加对话").font(.title2.bold())
                Text(model.accountSession == nil
                    ? "请先在设置中使用 GitHub 登录。"
                    : "创建新频道，或使用邀请口令加入已有频道。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Picker("添加方式", selection: $mode) {
                Text("创建频道").tag(AddChannelMode.create)
                Text("加入频道").tag(AddChannelMode.join)
            }
            .pickerStyle(.segmented)

            if mode == .create {
                VStack(alignment: .leading, spacing: 8) {
                    Text("频道名称").font(.headline)
                    TextField("例如 产品协作", text: $model.draftChannelName)
                        .onSubmit(submit)
                    Text("创建后可以复制一次性邀请口令给其他成员。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("邀请口令").font(.headline)
                    HStack {
                        SecureField("邀请链接或 ac2: 口令", text: $model.invitationInput)
                            .onSubmit(submit)
                        Button {
                            if let value = NSPasteboard.general.string(forType: .string) {
                                model.invitationInput = value
                            }
                        } label: {
                            Label("粘贴", systemImage: "doc.on.clipboard")
                        }
                    }
                    Text("邀请已包含频道信息；加入后你会获得独立的成员身份。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Label(
                model.state.defaultCallsign.isEmpty
                    ? "请先在设置中填写我的昵称"
                    : "将使用昵称「\(model.state.defaultCallsign)」",
                systemImage: "person.crop.circle"
            )
            .font(.caption)
            .foregroundStyle(model.state.defaultCallsign.isEmpty ? Color.red : Color.secondary)

            Divider()

            HStack {
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if model.busy {
                    ProgressView().controlSize(.small)
                }
                Button(actionTitle, action: submit)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(actionDisabled)
            }
        }
        .padding(24)
        .frame(width: 460)
    }
}

struct CreateInvitationSheet: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var label = ""
    @State private var maxUses = 1
    @State private var validHours = 24

    private var invalid: Bool {
        model.busy || label.trimmingCharacters(in: .whitespacesAndNewlines).utf16.count > 64
            || !(1...100).contains(maxUses) || !(1...720).contains(validHours)
    }

    private func submit() {
        guard !invalid else { return }
        Task {
            if await model.createInvitation(label: label, maxUses: maxUses, validHours: validHours) {
                dismiss()
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Text("创建邀请").font(.title2.bold())
                Text("配置创建时固定；需要变更时撤销旧邀请并重新创建。")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Form {
                TextField("备注（可选）", text: $label)
                TextField("可加入人数", value: $maxUses, format: .number)
                TextField("有效小时数", value: $validHours, format: .number)
            }
            .formStyle(.grouped)
            Text("范围：1–100 人、1–720 小时。邀请链接只会复制一次。")
                .font(.caption).foregroundStyle(.secondary)
            Label("加入者可以向当前频道及其已连接会话发消息，但不会获得本机文件或工具权限。", systemImage: "lock.shield")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            HStack {
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
                Button("创建并复制", action: submit)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(invalid)
            }
        }
        .padding(24)
        .frame(width: 460)
    }
}

struct ChannelContextSheet: View {
    @ObservedObject var model: AppModel
    let channelID: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var instructions: String
    @State private var memory: String

    init(model: AppModel, channelID: UUID) {
        self.model = model
        self.channelID = channelID
        _instructions = State(initialValue: model.channelRuntime(channelID)?.instructions ?? defaultChannelInstructions)
        _memory = State(initialValue: model.channelMemory(channelID))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("频道 AI").font(.title2.bold())
            Text("指令和记忆仅应用于当前频道；固定安全规则不可修改。")
                .font(.caption).foregroundStyle(.secondary)
            Text("频道指令").font(.caption.bold())
            TextEditor(text: $instructions).frame(height: 130)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            Text("频道记忆").font(.caption.bold())
            TextEditor(text: $memory).frame(height: 180)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            Text("记忆是频道上下文，不是成员身份或权限。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("保存") {
                    model.saveChannelContext(channelID, instructions: instructions, memory: memory)
                    if model.lastError.isEmpty { dismiss() }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || instructions.count > 4_000 || memory.count > 8_000)
            }
        }
        .padding(24)
        .frame(width: 560)
    }
}
enum ChannelDetailTab: Hashable {
    case messages
    case members
    case subscriptions
}

struct ChannelDetailView: View {
    @ObservedObject var model: AppModel
    let channel: ChannelProfile
    @State private var selectedTab = ChannelDetailTab.messages
    @State private var showCreateInvitation = false
    @State private var showChannelContext = false

    @ViewBuilder
    private func tabButton(_ title: String, tab: ChannelDetailTab, showsAttention: Bool = false) -> some View {
        Button {
            selectedTab = tab
        } label: {
            HStack(spacing: 5) {
                Text(title)
                if showsAttention {
                    Circle()
                        .fill(.red)
                        .frame(width: 7, height: 7)
                        .accessibilityLabel("有会话未连接")
                }
            }
                .fontWeight(selectedTab == tab ? .semibold : .regular)
                .foregroundStyle(selectedTab == tab ? Color.primary : Color.secondary)
                .padding(.horizontal, 2)
                .frame(height: 42)
                .overlay(alignment: .bottom) {
                    if selectedTab == tab {
                        Rectangle().fill(Color.accentColor).frame(height: 2)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.channelTitle(channel))
                        .font(.title2.bold())
                    Text("频道 · \(channel.channel) · \(model.channelStatus[channel.id] ?? "未连接")")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if channel.role == "owner" {
                    Button("邀请成员…") { showCreateInvitation = true }
                }
                if model.channelStatus[channel.id]?.contains("权限已撤销") == true {
                    Button("重新连接") { model.reconnectChannel(channel.id) }
                }
                Menu {
                    if channel.role == "owner" {
                        Button("编辑频道 AI…") { showChannelContext = true }
                        Divider()
                    }
                    Button("刷新") {
                        Task {
                            await model.refreshHistory()
                            await model.refreshMembers()
                            await model.refreshInvitations()
                        }
                    }
                    if selectedTab == .messages {
                        Button("清空本机历史", role: .destructive) { model.clearSelectedHistory() }
                            .disabled(model.messages.isEmpty)
                    }
                    Divider()
                    Button("退出频道", role: .destructive) {
                        Task { await model.leaveSelectedChannel() }
                    }
                    .disabled(channel.role == "owner" || model.busy)
                    .help(channel.role == "owner" ? "请先转移频道所有权" : "退出后需要新邀请才能重新加入")
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            HStack(spacing: 24) {
                tabButton("消息", tab: .messages)
                tabButton("成员", tab: .members)
                tabButton(
                    "AI",
                    tab: .subscriptions,
                    showsAttention: model.channelHasDisconnectedConversation(channel.id)
                )
                Spacer()
            }
            .padding(.horizontal, 20)
            .overlay(alignment: .bottom) { Divider() }
            Group {
                switch selectedTab {
                case .messages:
                    ChannelMessagesView(model: model)
                case .members:
                    ChannelMembersView(model: model, channel: channel)
                case .subscriptions:
                    ChannelSubscriptionsView(model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .sheet(isPresented: $showCreateInvitation) {
            CreateInvitationSheet(model: model)
        }
        .sheet(isPresented: $showChannelContext) {
            ChannelContextSheet(model: model, channelID: channel.id)
        }
        .onChange(of: channel.id) { _ in selectedTab = .messages }
    }
}

struct ChannelMessagesView: View {
    @ObservedObject var model: AppModel

    private func isContinuation(at index: Int) -> Bool {
        continuesMessageGroup(
            previous: index > 0 ? model.messages[index - 1] : nil,
            current: model.messages[index]
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            if model.messages.isEmpty {
                EmptyStateView(
                    title: "暂无消息",
                    systemImage: "text.bubble",
                    detail: "发送消息后，频道 AI 会在这里回复。"
                ) { EmptyView() }
                    .frame(maxHeight: .infinity)
            } else {
                List {
                    ForEach(Array(model.messages.enumerated()), id: \.element.id) { index, message in
                        let continuation = isContinuation(at: index)
                        MessageRow(message: message, continuation: continuation)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(
                                top: continuation ? 2 : 8,
                                leading: 16,
                                bottom: continuation ? 2 : 8,
                                trailing: 16
                            ))
                    }
                }
                .listStyle(.plain)
            }
            Divider()
            HStack(alignment: .bottom) {
                Menu {
                    Button { model.toggleComposerMentionAll() } label: {
                        Label("@所有人", systemImage: model.composerMentionAll ? "checkmark" : "person.3")
                    }
                    Divider()
                    ForEach(model.activeMentionMembers) { member in
                        Button { model.toggleComposerMention(member.memberID) } label: {
                            Label(
                                member.name + (member.memberID == model.selectedChannel?.memberID ? "（我）" : ""),
                                systemImage: model.composerMentionMemberIDs.contains(member.memberID) ? "checkmark" : "person"
                            )
                        }
                    }
                } label: {
                    if model.composerMentionLabel.isEmpty { Image(systemName: "at") }
                    else { Label(model.composerMentionLabel, systemImage: "at") }
                }
                .fixedSize()
                TextField("发送消息", text: $model.composerText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await model.sendComposerMessage() } }
                Button("发送") { Task { await model.sendComposerMessage() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.busy || model.composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(12)
            .background(.bar)
        }
    }
}

struct MessageRow: View {
    let message: ChannelMessageRecord
    let continuation: Bool
    @State private var showPendingStatus = false

    private var stateDetail: (String, Color)? {
        switch message.state {
        case .failed: return ("发送失败", .red)
        case .unknown: return ("投递结果未知", .red)
        case .pending: return showPendingStatus ? ("发送中", .orange) : nil
        case .attempting: return ("正在投递", .orange)
        case .received, .filtered, .delivered, .skipped, .accepted: return nil
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if continuation {
                Color.clear.frame(width: 30, height: 1)
            } else {
                Group {
                    if message.authorKind == .channelAI {
                        Image(systemName: "sparkles")
                    } else {
                        Text(String(message.from.prefix(1)).uppercased()).font(.caption.bold())
                    }
                }
                .frame(width: 30, height: 30)
                .foregroundStyle(message.authorKind == .channelAI ? Color.green : message.direction == .outbound ? Color.blue : Color.secondary)
                .background(
                    message.authorKind == .channelAI ? Color.green.opacity(0.12)
                        : message.direction == .outbound ? Color.blue.opacity(0.12) : Color.secondary.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 8)
                )
            }
            VStack(alignment: .leading, spacing: 4) {
                if !continuation {
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 8) {
                            Text(message.authorKind == .channelAI ? "AI" : message.from).font(.subheadline.bold())
                            Text(DateFormatter.delivery.string(from: Date(timeIntervalSince1970: message.at / 1000)))
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        if let label = message.source?.label, !label.isEmpty {
                            Text(label).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                if let mention = message.mention {
                    Text(mention.displayText)
                        .font(.caption.bold())
                        .foregroundStyle(.blue)
                }
                Text(message.text)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if let stateDetail {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.circle.fill")
                        Text(stateDetail.0)
                    }
                    .font(.caption2)
                    .foregroundStyle(stateDetail.1)
                }
            }
        }
        .task(id: message.id) {
            guard message.state == .pending else { return }
            let elapsed = Date().timeIntervalSince1970 * 1000 - message.at
            let remaining = max(0, pendingSendStatusDelayMilliseconds - elapsed)
            if remaining > 0 {
                try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000))
            }
            guard !Task.isCancelled else { return }
            showPendingStatus = true
        }
        .contextMenu {
            if let source = message.source, let conversationID = source.conversationID {
                Text("\(source.provider) · \(conversationID)")
                Button("复制来源会话 ID") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(conversationID, forType: .string)
                }
            }
        }
    }
}

struct ChannelMembersView: View {
    @ObservedObject var model: AppModel
    let channel: ChannelProfile

    private func memberSummary(_ member: ChannelMember) -> String {
        let role = member.role == "owner" ? "所有者" : "成员"
        let status: String
        switch member.status {
        case "active": status = member.online == true ? "在线" : "离线"
        case "banned": status = "已封禁"
        default: status = member.status
        }
        return "\(role) · \(status) · \(member.memberID.prefix(8))…"
    }

    private func invitationSummary(_ invitation: ChannelInvite) -> String {
        let state: String
        switch invitation.status {
        case "active": state = "可用"
        case "exhausted": state = "已用尽"
        case "expired": state = "已过期"
        case "revoked": state = "已撤销"
        default: state = invitation.status
        }
        let expiry = DateFormatter.invitation.string(
            from: Date(timeIntervalSince1970: Double(invitation.expiresAt) / 1000)
        )
        return "\(state) · 已用 \(invitation.useCount)/\(invitation.maxUses) · \(expiry) 到期"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            List {
                if channel.role == "owner" {
                    Section("邀请") {
                        if model.invitations.isEmpty {
                            Text("暂无邀请")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        } else {
                            ForEach(model.invitations) { invitation in
                                HStack(spacing: 10) {
                                    Image(systemName: invitation.status == "active" ? "envelope.open" : "envelope")
                                        .foregroundStyle(invitation.status == "active" ? Color.green : Color.secondary)
                                        .frame(width: 24)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(invitation.label.isEmpty ? "未命名邀请" : invitation.label)
                                        Text(invitationSummary(invitation))
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if invitation.status == "active" {
                                        Button("撤销", role: .destructive) {
                                            Task { await model.revokeInvitation(invitation) }
                                        }
                                        .buttonStyle(.borderless)
                                    }
                                }
                                .padding(.vertical, 4)
                            }
                        }
                    }
                }
                Section("成员") {
                    ForEach(model.members) { member in
                        HStack(spacing: 10) {
                            Circle().fill(member.online == true ? .green : .secondary.opacity(0.35)).frame(width: 8, height: 8)
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(member.name.isEmpty ? member.memberID : member.name)
                                Text(memberSummary(member))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if channel.role == "owner", member.memberID != channel.memberID {
                                Menu {
                                    if member.status == "banned" {
                                        Button("解除封禁") { Task { await model.unbanMember(member) } }
                                    } else if member.status == "active" {
                                        Button("移除成员", role: .destructive) { Task { await model.removeMember(member, ban: false) } }
                                        Button("封禁成员", role: .destructive) { Task { await model.removeMember(member, ban: true) } }
                                    }
                                } label: {
                                    Image(systemName: "ellipsis.circle")
                                }
                                .menuStyle(.borderlessButton)
                                .fixedSize()
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .listStyle(.plain)
        }
        .task(id: channel.id) {
            await model.refreshMembers()
            await model.refreshInvitations()
        }
    }
}

struct ChannelSubscriptionsView: View {
    @ObservedObject var model: AppModel
    @State private var refreshingCodexIntegration = false
    @State private var showChannelContext = false

    private var channel: ChannelProfile? { model.selectedChannel }

    private func refreshCodexIntegration() {
        refreshingCodexIntegration = true
        model.refreshCodexIntegrationStatus()
        refreshingCodexIntegration = false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let channel, channel.role != "owner" {
                EmptyStateView(
                    title: "频道 AI 由所有者运行",
                    systemImage: "sparkles",
                    detail: "你的消息会与其他成员消息一样交给频道 AI。"
                ) { EmptyView() }
            } else if let channel {
                VStack(alignment: .leading, spacing: 12) {
                    if !model.codexIntegrationReady {
                        Label(model.codexIntegrationBlockingTitle, systemImage: "bolt.horizontal.circle")
                            .font(.headline)
                        Text(model.codexIntegrationBlockingMessage)
                            .font(.callout).foregroundStyle(.secondary)
                        Button {
                            if model.codexReadiness == .notConfigured { model.enableCodexIntegration() }
                            else { refreshCodexIntegration() }
                        } label: {
                            if refreshingCodexIntegration {
                                HStack(spacing: 6) {
                                    ProgressView().controlSize(.small)
                                    Text("正在检查…")
                                }
                            } else {
                                Text(model.codexReadiness == .notConfigured ? "配置 Codex 集成" : "重新检查")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(refreshingCodexIntegration)
                    } else {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Label(
                                    model.selectedSubscriptions.isEmpty ? "AI 未连接" : "AI 已连接",
                                    systemImage: "sparkles"
                                )
                                .font(.headline)
                                Text(model.selectedSubscriptions.first.flatMap { model.listenerStatus[$0.id] }
                                    ?? model.taskCreationStatus)
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("编辑指令与记忆…") { showChannelContext = true }
                            if model.selectedSubscriptions.isEmpty {
                                Button("重新连接 AI") { Task { await model.createTaskSubscription() } }
                                    .buttonStyle(.borderedProminent)
                                    .disabled(model.busy)
                            }
                        }

                        Divider()

                        Text("只读上下文").font(.headline)
                        Text("已有 Codex 任务只作为当前频道的只读参考，不会成为频道 AI。")
                            .font(.caption).foregroundStyle(.secondary)
                        HStack {
                            TextField("搜索 Codex 任务，或输入任务 ID / 链接", text: $model.draftTask)
                                .textFieldStyle(.roundedBorder)
                                .onSubmit { Task { await model.searchHostConversations() } }
                                .onChange(of: model.draftTask) { _ in
                                    model.conversationSearchResults = []
                                    model.conversationSearchStatus = ""
                                }
                            Button("搜索") { Task { await model.searchHostConversations() } }
                                .disabled(model.busy || model.draftTask.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            Button("授权读取") { Task { await model.addTaskSubscription() } }
                                .disabled(model.busy || model.draftTask.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                        if !model.conversationSearchResults.isEmpty {
                            List(model.conversationSearchResults) { conversation in
                                Button {
                                    Task { await model.bindHostConversation(conversation) }
                                } label: {
                                    HStack {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(conversation.title).lineLimit(1)
                                            Text(conversation.conversationID)
                                                .font(.caption2.monospaced()).foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        Text(model.hasChannelHistoryAccess(conversation.conversationID, channelID: channel.id)
                                            ? "已授权" : "授权读取")
                                            .font(.caption)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                            .frame(height: min(CGFloat(model.conversationSearchResults.count) * 54, 220))
                        } else if !model.conversationSearchStatus.isEmpty {
                            Text(model.conversationSearchStatus).font(.caption).foregroundStyle(.secondary)
                        }

                        if let runtime = model.channelRuntime(channel.id), !runtime.allowedHistoryTaskIDs.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(runtime.allowedHistoryTaskIDs, id: \.self) { taskID in
                                    HStack {
                                        Text(taskID).font(.caption.monospaced()).lineLimit(1)
                                        Spacer()
                                        Button("撤销") {
                                            model.setChannelHistoryAccess(false, taskID: taskID, channelID: channel.id)
                                        }
                                        .buttonStyle(.borderless)
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(16)
            } else {
                EmptyStateView(title: "未选择频道", systemImage: "bubble.left", detail: "") { EmptyView() }
            }
        }
        .sheet(isPresented: $showChannelContext) {
            if let channel { ChannelContextSheet(model: model, channelID: channel.id) }
        }
    }
}
struct EmptyStateView<Actions: View>: View {
    let title: String
    let systemImage: String
    let detail: String
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage).font(.system(size: 36)).foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(detail).foregroundStyle(.secondary).multilineTextAlignment(.center)
            actions()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct PijooSettingsView: View {
    @ObservedObject var model: AppModel
    @State private var refreshingCodexIntegration = false
    var initialSetup = false

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(initialSetup ? "开始使用 Pijoo" : "设置").font(.title2.bold())
                if initialSetup {
                    Text("请先设置名字并启用 AI 集成，完成后即可创建频道。")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            Divider()
            Form {
                Section("Pijoo 账号") {
                    if let account = model.accountSession {
                        LabeledContent("GitHub") {
                            Text(account.displayName).fontWeight(.medium)
                        }
                        HStack {
                            Text(model.accountStatus).foregroundStyle(.secondary)
                            Spacer()
                            Button("退出登录", role: .destructive) {
                                Task { await model.logoutAccount() }
                            }
                            .disabled(model.accountBusy)
                        }
                    } else {
                        HStack {
                            Text(model.accountStatus).foregroundStyle(.secondary)
                            Spacer()
                            if model.accountBusy { ProgressView().controlSize(.small) }
                            if model.accountFeatureAvailable {
                                Button("使用 GitHub 登录") { model.loginWithGitHub() }
                                    .buttonStyle(.borderedProminent)
                                    .disabled(model.accountBusy)
                            } else {
                                Button("重新检查") { Task { await model.refreshAccount() } }
                                    .disabled(model.accountBusy)
                            }
                        }
                    }
                    Text("登录后会恢复你加入的频道；频道消息会经过服务端中继，AI 运行数据和工作目录不会上传。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("身份") {
                    HStack {
                        TextField("我的昵称", text: $model.draftNickname)
                        Button("保存") { Task { await model.saveNickname() } }
                    }
                    Text("这个昵称会用于你加入的所有频道和发出的消息。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("AI 集成") {
                    LabeledContent("ChatGPT Codex") {
                        HStack(spacing: 6) {
                            Text(model.codexIntegrationStatus)
                            Button {
                                refreshCodexIntegration()
                            } label: {
                                if refreshingCodexIntegration {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Image(systemName: "arrow.clockwise")
                                }
                            }
                            .buttonStyle(.borderless)
                            .help("刷新")
                            .accessibilityLabel(refreshingCodexIntegration ? "正在刷新" : "刷新")
                            .disabled(refreshingCodexIntegration)
                        }
                    }
                    if model.codexIntegrationNeedsRestart {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Label("需要完全重启 ChatGPT", systemImage: "arrow.clockwise.circle.fill")
                                    .font(.subheadline.bold())
                                    .foregroundStyle(.orange)
                                Spacer()
                                Button {
                                    refreshCodexIntegration()
                                } label: {
                                    HStack(spacing: 4) {
                                        if refreshingCodexIntegration {
                                            ProgressView().controlSize(.small)
                                        }
                                        Text("刷新")
                                    }
                                }
                                .disabled(refreshingCodexIntegration)
                            }
                            Text(model.loadedCodexMCPVersion.map {
                                "ChatGPT 仍在使用 MCP \($0)，当前 App 为 \(model.currentVersion)。重启后会自动确认。"
                            } ?? "尚未检测到 MCP \(model.currentVersion)。重启后会自动确认。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(8)
                        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                    }
                    HStack {
                        Button("启用或修复 Codex 集成") { model.enableCodexIntegration() }
                        if !initialSetup {
                            Button("移除 Codex 集成", role: .destructive) { model.removeCodexIntegration() }
                        }
                    }
                    Text("MCP 提供当前会话的频道动作，Skill 负责识别外部消息和协作规则；账号 Session 只保存在 App Keychain。首次配置 MCP 后需完全重启 ChatGPT。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !initialSetup {
                    Section("App") {
                        Toggle("登录时启动", isOn: Binding(
                            get: { model.launchAtLogin },
                            set: { model.setLaunchAtLogin($0) }
                        ))
                        Toggle("自动检查并下载 Beta 更新", isOn: Binding(
                            get: { model.automaticUpdateChecks },
                            set: { model.setAutomaticUpdateChecks($0) }
                        ))
                        HStack {
                            Text("版本 \(model.currentVersion)")
                            Spacer()
                            Text(model.updateStatus).foregroundStyle(.secondary)
                            Button("检查并下载 Beta 更新…") { Task { await model.checkBetaUpdate() } }
                        }
                    }
                    Section("本机数据") {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("客户端日志")
                                Text("最多保留约 2 MB；不记录频道正文、邀请口令或成员凭证。")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("导出客户端日志…") { model.exportClientLog() }
                        }
                        if model.oldBetaDataDetected {
                            Text("检测到旧 0.2 数据；0.3 保持隔离且不会迁移或删除。")
                                .foregroundStyle(.orange)
                        }
                        Button("移除全部 0.3 Beta 本机配置…", role: .destructive) { model.removeAllV2Data() }
                    }
                }
            }
            .formStyle(.grouped)
            .padding()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func refreshCodexIntegration() {
        refreshingCodexIntegration = true
        model.refreshCodexIntegrationStatus()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            refreshingCodexIntegration = false
        }
    }
}
