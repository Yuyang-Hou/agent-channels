import AppKit
import Combine
import CryptoKit
import Darwin
import Foundation
import Security
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

let defaultOrigin = "https://rogerthat-production-fff6.up.railway.app"
let keychainService = "dev.pijoo.channel"
let accountSessionKey = "account:session"
let managedConfigStart = "# >>> Pijoo managed MCP >>>"
let managedConfigEnd = "# <<< Pijoo managed MCP <<<"
let githubReleasesURL = URL(string: "https://api.github.com/repos/Yuyang-Hou/pijoo/releases?per_page=100")!
let automaticUpdateChecksKey = "automaticUpdateChecks"
let loadedCodexMCPVersionKey = "loadedCodexMCPVersion"
let shownCodexRestartVersionKey = "shownCodexRestartVersion"
let localSendProtocolVersion = 2
let maxChannelMessageLength = 8192
let maxLocalSendFrameBytes = 64 * 1024
let defaultChannelInstructions = "友好、自然、简洁地参与当前频道；不确定时坦诚说明。"
let defaultMessageTemplate = """
> **↗ Pijoo · 外部频道消息**
>
> **频道** `{channel_name}` · **来自** `{sender_name}` · **成员** `{sender_member_id}` · **提醒** {mentions} · `#{message_id}`
>
> {message_text}
"""
let defaultSentMessageTemplate = """
> **↗ Pijoo · 已发送到频道**
>
> **频道** `{channel_name}` · **提醒** {mentions} · `#{message_id}`
>
> {message_text}
"""

func compactTaskKey(_ raw: String) -> String? {
    guard let uuid = UUID(uuidString: raw) else { return nil }
    let bytes = Array(SHA256.hash(data: Data(uuid.uuidString.lowercased().utf8)).prefix(16))
    let alphabet = Array("abcdefghijklmnopqrstuvwxyz234567".utf8)
    var buffer: UInt64 = 0
    var bits = 0
    var encoded: [UInt8] = []
    for byte in bytes {
        buffer = (buffer << 8) | UInt64(byte)
        bits += 8
        while bits >= 5 {
            bits -= 5
            encoded.append(alphabet[Int((buffer >> UInt64(bits)) & 31)])
        }
        buffer = bits == 0 ? 0 : buffer & ((1 << UInt64(bits)) - 1)
    }
    if bits > 0 { encoded.append(alphabet[Int((buffer << UInt64(5 - bits)) & 31)]) }
    return String(decoding: encoded, as: UTF8.self)
}

func bridgeRecoveryClearsError(kind: String?, state: String) -> Bool {
    (state == "joined" && ["join", "session", "rejoin"].contains(kind)) ||
        (state == "connected" && kind == "connection") ||
        (state == "delivered" && (kind == "connection" || kind == "delivery")) ||
        (state == "stopped" && kind == "connection")
}

func isPendingBridgeDelivery(_ kind: String?) -> Bool {
    kind == "delivery" || kind == "delivery_outcome_unknown"
}

func bridgeErrorShouldReplace(current: String?, incoming: String?) -> Bool {
    !isPendingBridgeDelivery(current) || isPendingBridgeDelivery(incoming)
}

func bridgeErrorAffectsGlobalHealthImmediately(_ kind: String?) -> Bool {
    kind != "connection"
}

func isDisconnectedHostError(_ detail: String) -> Bool {
    let normalized = detail.lowercased()
    return normalized.contains("needs rebind") ||
        normalized.contains("no-client-found") ||
        normalized.contains("could not connect to chatgpt desktop ipc") ||
        normalized.contains("chatgpt desktop ipc closed")
}

func clientLogField(_ value: String) -> String {
    String(value.replacingOccurrences(of: "\t", with: " ")
        .replacingOccurrences(of: "\r", with: " ")
        .replacingOccurrences(of: "\n", with: " ")
        .prefix(200))
}

func isCancellationError(_ error: Error) -> Bool {
    if error is CancellationError { return true }
    let nsError = error as NSError
    return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
}

func requiresCodexRestart(configured: Bool, appVersion: String, loadedMCPVersion: String?) -> Bool {
    configured && loadedMCPVersion != appVersion
}

func generatedLocalNickname(id: UUID = UUID()) -> String {
    "Pijoo用户-\(id.uuidString.replacingOccurrences(of: "-", with: "").prefix(6).uppercased())"
}

struct PijooAccountSession: Equatable {
    let accountID: String
    let deviceID: String
    let displayName: String
    let expiresAt: String
}

func accountRandomValue() throws -> String {
    var bytes = [UInt8](repeating: 0, count: 32)
    guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
        throw AppFailure("无法生成安全登录凭证")
    }
    return Data(bytes).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

func accountPKCEChallenge(_ verifier: String) -> String {
    Data(SHA256.hash(data: Data(verifier.utf8))).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

func accountExchangeCode(from callbackURL: URL, expectedState: String) throws -> String {
    guard let values = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
          values.scheme == "pijoo", values.host == "oauth", values.path == "/callback" else {
        throw AppFailure("登录回调地址无效")
    }
    var parameters: [String: String] = [:]
    for item in values.queryItems ?? [] {
        guard parameters[item.name] == nil else { throw AppFailure("登录回调参数无效") }
        parameters[item.name] = item.value ?? ""
    }
    guard parameters["state"] == expectedState else { throw AppFailure("登录状态校验失败") }
    if parameters["error"] == "login_cancelled" { throw CancellationError() }
    guard let code = parameters["code"], code.count == 43,
          code.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else {
        throw AppFailure("登录授权结果无效")
    }
    return code
}

enum CodexIntegrationReadiness: Equatable {
    case notConfigured
    case awaitingRestart
    case versionMismatch
    case ready
}

func codexIntegrationReadiness(configured: Bool, appVersion: String, loadedMCPVersion: String?) -> CodexIntegrationReadiness {
    guard configured else { return .notConfigured }
    guard let loadedMCPVersion else { return .awaitingRestart }
    return loadedMCPVersion == appVersion ? .ready : .versionMismatch
}

struct ChannelProfile: Codable, Equatable, Identifiable {
    let id: UUID
    var origin: String
    var channel: String
    var displayName: String
    var callsign: String
    var memberID: String
    var role: String
    var credentialAccount: String
    var lastViewedMessageID: Int64?
}

struct AccountChannelSnapshot: Equatable {
    let channel: String
    let displayName: String
    let membershipID: String
    let role: String
    let memberName: String
}

func channelCallsign(_ membershipID: String) -> String {
    "agent-\(membershipID.lowercased().filter { $0.isLetter || $0.isNumber }.prefix(10))"
}

func mergedAccountChannels(
    _ existing: [ChannelProfile],
    snapshots: [AccountChannelSnapshot],
    origin: String,
    credentialAccount: String,
    makeID: () -> UUID = UUID.init
) -> [ChannelProfile] {
    snapshots.map { snapshot in
        if var channel = existing.first(where: { $0.origin == origin && $0.channel == snapshot.channel }) {
            channel.displayName = snapshot.displayName
            channel.memberID = snapshot.membershipID
            channel.role = snapshot.role
            channel.credentialAccount = credentialAccount
            return channel
        }
        return ChannelProfile(
            id: makeID(),
            origin: origin,
            channel: snapshot.channel,
            displayName: snapshot.displayName,
            callsign: channelCallsign(snapshot.membershipID),
            memberID: snapshot.membershipID,
            role: snapshot.role,
            credentialAccount: credentialAccount,
            lastViewedMessageID: nil
        )
    }
}

func reconciledChannelProfile(
    _ profile: ChannelProfile,
    authenticatedMemberID: String
) throws -> ChannelProfile {
    guard !authenticatedMemberID.isEmpty else { throw AppFailure("服务端未返回可信成员身份") }
    var reconciled = profile
    reconciled.memberID = authenticatedMemberID
    return reconciled
}

struct TaskBinding: Codable, Equatable, Identifiable {
    let id: UUID
    var provider: String
    var conversationID: String
}

struct HostConversationSummary: Codable, Equatable, Identifiable {
    var provider: String
    var conversationID: String
    var title: String
    var updatedAt: Double
    var workspace: String?

    var id: String { "\(provider):\(conversationID)" }
    var searchStateLabel: String {
        "权限未知" + (workspace.map { " · 上次目录：\($0)" } ?? " · 目录未知")
    }

    enum CodingKeys: String, CodingKey {
        case provider, title, workspace
        case conversationID = "conversation_id"
        case updatedAt = "updated_at"
    }
}

enum HostPermissionChoice: String, CaseIterable, Identifiable {
    case requestApproval = "request-approval"
    case approveForMe = "approve-for-me"
    case fullAccess = "full-access"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .requestApproval: "请求批准"
        case .approveForMe: "仅风险操作请求批准"
        case .fullAccess: "完全访问权限"
        }
    }
}

struct HostConversationRuntimeState: Decodable, Equatable {
    let connected: Bool
    let workspace: String?
    let permission: String

    var label: String {
        guard connected else { return "权限未知 · 目录未知" }
        let permissionLabel = HostPermissionChoice(rawValue: permission)?.title ?? "权限未知"
        return "\(permissionLabel)" + (workspace.map { " · \($0)" } ?? " · 目录未知")
    }
}

func disconnectedHostTaskIDs(
    tasks: [TaskBinding],
    subscriptions: [ChannelSubscription],
    states: [UUID: HostConversationRuntimeState]
) -> [UUID] {
    let enabledTaskIDs = Set(subscriptions.lazy.filter(\.enabled).map(\.taskID))
    return tasks.filter { enabledTaskIDs.contains($0.id) && states[$0.id]?.connected == false }.map(\.id)
}

struct HostConversationSearchResponse: Decodable {
    let ok: Bool
    let conversations: [HostConversationSummary]
}

struct HostConversationCreateResponse: Decodable {
    let ok: Bool
    let provider: String
    let conversationID: String

    enum CodingKeys: String, CodingKey {
        case ok, provider
        case conversationID = "conversation_id"
    }
}

enum HostProviderChoice: String, CaseIterable, Identifiable {
    case codex
    case claude

    var id: String { rawValue }
    var displayName: String { self == .codex ? "ChatGPT" : "Claude" }
    var bundleIdentifier: String { self == .codex ? "com.openai.codex" : "com.anthropic.claudefordesktop" }
    var isInstalled: Bool { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) != nil }
    var supportsForwarding: Bool { self == .codex }

    static var available: [Self] {
        allCases.filter { $0.isInstalled && $0.supportsForwarding }
    }
}

func hostDisplayName(_ provider: String) -> String {
    HostProviderChoice(rawValue: provider)?.displayName ?? provider
}

struct ChannelSubscription: Codable, Equatable, Identifiable {
    let id: UUID
    var channelID: UUID
    var taskID: UUID
    var enabled: Bool
    var template: String
    var sentMessageTemplate: String? = nil
    var receiveScope: ReceiveScope? = nil
    var defaultSend: Bool
    var lastDeliveredMessageID: Int64?
    var lastDeliveredAt: Double?
    var uncertainMessageID: Int64? = nil
    var uncertainDetail: String? = nil
}

enum ReceiveScope: String, Codable, CaseIterable, Identifiable {
    case allMessages = "all_messages"
    case mentionsOnly = "mentions_only"

    var id: String { rawValue }
    var title: String { self == .allMessages ? "回复所有消息" : "仅回复 @我的 AI" }
}

struct AppStateV2: Codable, Equatable {
    var version = 2
    var accountID: String? = nil
    var defaultCallsign = ""
    var channels: [ChannelProfile] = []
    var tasks: [TaskBinding] = []
    var subscriptions: [ChannelSubscription] = []
    var selectedChannelID: UUID?
}

struct ChannelRuntimeConfig: Codable, Equatable, Identifiable {
    var channelID: String
    var taskID: String? = nil
    var allowedHistoryTaskIDs: [String] = []
    var instructions = defaultChannelInstructions

    var id: String { channelID }

    enum CodingKeys: String, CodingKey {
        case instructions
        case channelID = "channel_id"
        case taskID = "task_id"
        case allowedHistoryTaskIDs = "allowed_history_task_ids"
    }
}

struct ChannelConfig: Codable, Equatable {
    var version = 1
    var channels: [ChannelRuntimeConfig] = []

    func runtime(channelID: String) -> ChannelRuntimeConfig? {
        channels.first { $0.channelID == channelID }
    }

    mutating func update(_ runtime: ChannelRuntimeConfig) {
        channels.removeAll { $0.channelID == runtime.channelID }
        channels.append(runtime)
        channels.sort { $0.channelID < $1.channelID }
    }

    mutating func setHistoryAccess(_ allowed: Bool, taskID rawTaskID: String, channelID: String) throws {
        guard let taskID = UUID(uuidString: rawTaskID)?.uuidString.lowercased() else {
            throw AppFailure("Codex task ID 无效")
        }
        var runtime = runtime(channelID: channelID) ?? ChannelRuntimeConfig(channelID: channelID)
        runtime.allowedHistoryTaskIDs.removeAll { $0.caseInsensitiveCompare(taskID) == .orderedSame }
        if allowed { runtime.allowedHistoryTaskIDs.append(taskID) }
        runtime.allowedHistoryTaskIDs.sort()
        update(runtime)
    }
}

func outboundSelection(
    taskID: UUID?,
    explicitChannelID: UUID?,
    channels: [ChannelProfile],
    subscriptions: [ChannelSubscription]
) throws -> (channelID: UUID, subscriptionID: UUID?) {
    if let explicitChannelID {
        guard channels.contains(where: { $0.id == explicitChannelID }) else {
            throw AppFailure("发送频道不存在")
        }
        let subscription = taskID.flatMap { taskID in
            subscriptions.first { $0.taskID == taskID && $0.channelID == explicitChannelID }
        }
        return (explicitChannelID, subscription?.id)
    }
    let candidates = subscriptions.filter { subscription in
        subscription.taskID == taskID && channels.contains { $0.id == subscription.channelID }
    }
    let defaults = candidates.filter(\.defaultSend)
    if defaults.count == 1, let subscription = defaults.first {
        return (subscription.channelID, subscription.id)
    }
    if defaults.isEmpty, candidates.count == 1, let subscription = candidates.first {
        return (subscription.channelID, subscription.id)
    }
    if !candidates.isEmpty {
        throw AppFailure("当前会话连接了多个频道，请指定 channel 或设置唯一默认回复频道")
    }
    guard let channel = channels.count == 1 ? channels.first : nil else {
        throw AppFailure(channels.isEmpty ? "本机没有可发送的频道" : "本机有多个频道，请指定 channel")
    }
    return (channel.id, nil)
}

enum MessageDirection: String, Codable { case inbound, outbound }
enum MessageAuthorKind: String, Codable { case human, channelAI = "channel_ai" }
enum MessageDeliveryState: String, Codable {
    case pending, received, attempting, filtered, delivered, skipped, accepted, failed, unknown
}

struct MentionedMember: Codable, Equatable {
    var memberID: String
    var memberName: String

    enum CodingKeys: String, CodingKey {
        case memberID = "member_id"
        case memberName = "member_name"
    }
}

struct MessageMention: Codable, Equatable {
    var kind: String
    var members: [MentionedMember]? = nil
    var ais: [MentionedMember]? = nil

    var displayText: String {
        if kind == "all" { return "@所有人" }
        return ((members ?? []).map { "@\($0.memberName)" }
            + (ais ?? []).map { "@\($0.memberName)的 AI" }).joined(separator: "、")
    }
}

struct MessageSourceReference: Codable, Equatable {
    var provider: String
    var conversationID: String? = nil
    var label: String? = nil

    enum CodingKeys: String, CodingKey {
        case provider, label
        case conversationID = "conversation_id"
    }
}

struct ChannelMessageRecord: Codable, Equatable, Identifiable {
    var channelID: UUID
    var messageID: String
    var direction: MessageDirection
    var from: String
    var to: String
    var text: String
    var at: Double
    var state: MessageDeliveryState
    var senderMemberID: String? = nil
    var senderEndpointID: String? = nil
    var authorKind: MessageAuthorKind = .human
    var source: MessageSourceReference? = nil
    var mention: MessageMention? = nil

    var id: String { "\(channelID.uuidString):\(messageID)" }
}

func upsertedMessages(_ record: ChannelMessageRecord, into records: [ChannelMessageRecord]) -> [ChannelMessageRecord] {
    var updated = records
    if let index = updated.firstIndex(where: { $0.id == record.id }) {
        updated[index] = record
    } else {
        updated.append(record)
        updated.sort { ($0.at, $0.messageID) < ($1.at, $1.messageID) }
        if updated.count > 500 { updated.removeFirst(updated.count - 500) }
    }
    return updated
}

func channelListenURL(base: URL, cursor: Int64?) -> URL {
    var components = URLComponents(url: base.appendingPathComponent("listen"), resolvingAgainstBaseURL: false)
    components?.queryItems = [
        URLQueryItem(name: "timeout", value: "30"),
        cursor.map { URLQueryItem(name: "since", value: String($0)) },
    ].compactMap { $0 }
    return components?.url ?? base.appendingPathComponent("listen")
}

func channelRequestURL(base: URL, suffix: String) -> URL {
    let components = suffix.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
    var url = base
    if let path = components.first {
        for segment in path.split(separator: "/") { url.appendPathComponent(String(segment)) }
    }
    if components.count == 2 {
        var urlComponents = URLComponents(url: url, resolvingAgainstBaseURL: false)
        urlComponents?.percentEncodedQuery = String(components[1])
        if let resolved = urlComponents?.url { url = resolved }
    }
    return url
}

func pendingRecoveryMessages(after cursor: Int64?, records: [ChannelMessageRecord]) -> [ChannelMessageRecord] {
    records.filter { (Int64($0.messageID) ?? 0) > (cursor ?? 0) }
}

struct SubscriptionDeliveryRecord: Codable, Equatable, Identifiable {
    var subscriptionID: UUID
    var channelID: UUID
    var messageID: String
    var state: MessageDeliveryState
    var detail: String?
    var updatedAt: Double

    var id: String { "\(subscriptionID.uuidString):\(channelID.uuidString):\(messageID)" }
}

struct LocalMessageProvenance: Encodable {
    let found: Bool
    let origin: String?
    let channel: String?
    let channelName: String?
    let messageID: String?
    let senderName: String?
    let senderMemberID: String?
    let senderEndpointID: String?
    let sourceKind: String?
    let sourceProvider: String?
    let sourceConversationID: String?
    let sourceLabel: String?
    let receivedAt: Double?

    enum CodingKeys: String, CodingKey {
        case found, origin, channel
        case channelName = "channel_name"
        case messageID = "message_id"
        case senderName = "sender_name"
        case senderMemberID = "sender_member_id"
        case senderEndpointID = "sender_endpoint_id"
        case sourceKind = "source_kind"
        case sourceProvider = "source_provider"
        case sourceConversationID = "source_conversation_id"
        case sourceLabel = "source_label"
        case receivedAt = "received_at"
    }

    static let notFound = LocalMessageProvenance(
        found: false,
        origin: nil,
        channel: nil,
        channelName: nil,
        messageID: nil,
        senderName: nil,
        senderMemberID: nil,
        senderEndpointID: nil,
        sourceKind: nil,
        sourceProvider: nil,
        sourceConversationID: nil,
        sourceLabel: nil,
        receivedAt: nil
    )
}

enum ReceivedDeliveryDecision: String {
    case record = "recorded"
    case alreadyProcessed = "already_processed"
    case unresolved
}

func receivedDeliveryDecision(_ state: MessageDeliveryState?) -> ReceivedDeliveryDecision {
    guard let state else { return .record }
    switch state {
    case .delivered, .filtered, .skipped: return .alreadyProcessed
    case .attempting, .unknown: return .unresolved
    default: return .record
    }
}

func advancedDeliveryCursor(_ current: Int64?, through messageID: Int64) -> Int64 {
    max(current ?? messageID, messageID)
}

func continuesMessageGroup(
    previous: ChannelMessageRecord?,
    current: ChannelMessageRecord
) -> Bool {
    guard let previous else { return false }
    let interval = current.at - previous.at
    let sameAuthor = current.authorKind == previous.authorKind && (current.authorKind == .channelAI
        ? current.senderMemberID == previous.senderMemberID
            && current.senderEndpointID != nil
            && current.senderEndpointID == previous.senderEndpointID
        : current.senderMemberID == previous.senderMemberID && current.from == previous.from)
    return sameAuthor && current.direction == previous.direction
        && interval >= 0 && interval <= 5 * 60 * 1000
}

func channelMessageAuthorName(_ message: ChannelMessageRecord) -> String {
    message.authorKind == .channelAI ? "\(message.from.isEmpty ? "频道成员" : message.from) 的 AI" : message.from
}

let pendingSendStatusDelayMilliseconds = 1_000.0

func shouldShowPendingSendStatus(startedAt: Double, now: Double) -> Bool {
    now - startedAt >= pendingSendStatusDelayMilliseconds
}

func recoverSubscriptionDeliveryState(
    _ subscription: inout ChannelSubscription,
    deliveries: [SubscriptionDeliveryRecord]
) {
    let safeCursor = deliveries.filter { [.delivered, .filtered, .skipped].contains($0.state) }
        .compactMap { Int64($0.messageID) }.max()
    if let safeCursor, safeCursor > (subscription.lastDeliveredMessageID ?? 0) {
        subscription.lastDeliveredMessageID = safeCursor
    }
    if let unresolved = subscription.uncertainMessageID,
       let last = deliveries.last,
       Int64(last.messageID) == unresolved,
       (last.state == .skipped || (last.state == .received && last.detail?.contains("用户确认") == true)) {
        subscription.uncertainMessageID = nil
        subscription.uncertainDetail = nil
        subscription.enabled = true
    }
    guard let last = deliveries.last,
          last.state == .attempting || last.state == .unknown,
          let messageID = Int64(last.messageID) else { return }
    subscription.enabled = false
    subscription.uncertainMessageID = messageID
    subscription.uncertainDetail = last.detail ?? "上次 Host 投递没有可靠终态，请人工核对"
}

func latestDeliveredChannelMessage(
    taskID: UUID,
    subscriptions: [ChannelSubscription],
    deliveries: (UUID) -> [SubscriptionDeliveryRecord],
    messages: (UUID) -> [ChannelMessageRecord]
) -> ChannelMessageRecord? {
    let candidates = subscriptions.filter { $0.taskID == taskID }.flatMap { subscription in
        deliveries(subscription.id).filter { $0.state == .delivered }.map { (subscription.channelID, $0) }
    }.sorted { $0.1.updatedAt > $1.1.updatedAt }
    for (channelID, delivery) in candidates {
        if let message = messages(channelID).first(where: { $0.messageID == delivery.messageID }) {
            return message
        }
    }
    return nil
}

struct ChannelMember: Codable, Equatable, Identifiable {
    let memberID: String
    let name: String
    let role: String
    let status: String
    let online: Bool?
    let aiConnected: Bool?

    var id: String { memberID }

    enum CodingKeys: String, CodingKey {
        case memberID = "member_id"
        case name, role, status, online
        case aiConnected = "ai_connected"
    }
}

struct ChannelInvite: Codable, Equatable, Identifiable {
    let inviteID: String
    let label: String
    let maxUses: Int
    let useCount: Int
    let expiresAt: Int64
    let status: String

    var id: String { inviteID }

    enum CodingKeys: String, CodingKey {
        case inviteID = "invite_id"
        case label
        case maxUses = "max_uses"
        case useCount = "use_count"
        case expiresAt = "expires_at"
        case status
    }
}

struct ChannelInvitation: Codable, Equatable {
    let version: Int
    let origin: String
    let channel: String
    let inviteToken: String
}

enum InvitationCodec {
    static func encode(_ invitation: ChannelInvitation) throws -> String {
        let data = try JSONEncoder().encode(invitation)
        return "ac2:" + data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func decode(_ raw: String) throws -> ChannelInvitation {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.hasPrefix("ac2:") {
            return try decodeWebURL(trimmed)
        }
        var encoded = String(trimmed.dropFirst(4))
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let data = Data(base64Encoded: encoded) else {
            throw AppFailure("邀请口令已损坏")
        }
        return try validated(JSONDecoder().decode(ChannelInvitation.self, from: data))
    }

    static func webURL(_ invitation: ChannelInvitation) throws -> String {
        let invitation = try validated(invitation)
        guard var components = URLComponents(string: invitation.origin) else {
            throw AppFailure("邀请地址无效")
        }
        let basePath = components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path
        components.path = "\(basePath)/join/\(invitation.channel)"
        components.query = nil
        components.fragment = "invite=\(invitation.inviteToken)"
        guard let value = components.url?.absoluteString else {
            throw AppFailure("无法生成邀请链接")
        }
        return value
    }

    private static func decodeWebURL(_ raw: String) throws -> ChannelInvitation {
        guard var components = URLComponents(string: raw),
              components.scheme == "https" || components.scheme == "http",
              let joinRange = components.path.range(of: "/join/", options: .backwards),
              let fragment = components.fragment else {
            throw AppFailure("邀请格式不正确，请粘贴完整邀请链接或 ac2: 口令")
        }
        let channel = String(components.path[joinRange.upperBound...]).removingPercentEncoding ?? ""
        let token = URLComponents(string: "https://pijoo.invalid/?\(fragment)")?
            .queryItems?.first(where: { $0.name == "invite" })?.value ?? ""
        components.path = String(components.path[..<joinRange.lowerBound])
        components.query = nil
        components.fragment = nil
        guard let origin = components.url?.absoluteString else {
            throw AppFailure("邀请地址无效")
        }
        return try validated(ChannelInvitation(version: 2, origin: origin, channel: channel, inviteToken: token))
    }

    private static func validated(_ invitation: ChannelInvitation) throws -> ChannelInvitation {
        guard invitation.version == 2,
              let url = URL(string: invitation.origin),
              url.scheme == "https" || url.scheme == "http",
              !invitation.channel.isEmpty,
              !invitation.inviteToken.isEmpty else {
            throw AppFailure("邀请口令内容无效")
        }
        return invitation
    }
}

func alreadyJoinedChannel(
    _ channels: [ChannelProfile],
    invitation: ChannelInvitation
) -> Bool {
    channels.contains { $0.origin == invitation.origin && $0.channel == invitation.channel }
}

enum CodexConfigEditor {
    static func reading(_ url: URL) throws -> String? {
        var info = stat()
        if lstat(url.path, &info) != 0 {
            if errno == ENOENT { return nil }
            throw AppFailure("无法检查 Codex 配置：\(String(cString: strerror(errno)))")
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    static func writing(_ value: String, to url: URL) throws {
        var info = stat()
        let destination = lstat(url.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFLNK
            ? url.resolvingSymlinksInPath()
            : url
        try value.write(to: destination, atomically: true, encoding: .utf8)
    }

    static func managedBlock(sidecar: String, binding: String) -> String {
        [
            managedConfigStart,
            "[mcp_servers.pijoo]",
            "command = \(tomlString(sidecar))",
            "args = [\(tomlString("channel-mcp")), \(tomlString("--config")), \(tomlString(binding))]",
            managedConfigEnd,
        ].joined(separator: "\n")
    }

    static func installing(block: String, into existing: String) throws -> String {
        let startRanges = existing.ranges(of: managedConfigStart)
        let endRanges = existing.ranges(of: managedConfigEnd)
        if startRanges.isEmpty && endRanges.isEmpty {
            if existing.range(of: #"(?m)^\s*\[mcp_servers\.pijoo\]\s*$"#, options: .regularExpression) != nil {
                throw AppFailure("~/.codex/config.toml 已有非 Pijoo 管理的同名 MCP，请先手动处理")
            }
            let prefix = existing.isEmpty ? "" : existing.trimmingCharacters(in: .newlines) + "\n\n"
            return prefix + block + "\n"
        }
        guard startRanges.count == 1, endRanges.count == 1,
              startRanges[0].lowerBound < endRanges[0].lowerBound else {
            throw AppFailure("Pijoo 配置标记不完整，未修改 ~/.codex/config.toml")
        }
        let replacementRange = startRanges[0].lowerBound..<endRanges[0].upperBound
        return existing.replacingCharacters(in: replacementRange, with: block)
    }

    static func removingManagedBlock(from existing: String) throws -> String {
        let startRanges = existing.ranges(of: managedConfigStart)
        let endRanges = existing.ranges(of: managedConfigEnd)
        if startRanges.isEmpty && endRanges.isEmpty { return existing }
        guard startRanges.count == 1, endRanges.count == 1,
              startRanges[0].lowerBound < endRanges[0].lowerBound else {
            throw AppFailure("Pijoo 配置标记不完整，未修改 ~/.codex/config.toml")
        }
        var output = existing.replacingCharacters(
            in: startRanges[0].lowerBound..<endRanges[0].upperBound,
            with: ""
        )
        while output.contains("\n\n\n") {
            output = output.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }
        return output.trimmingCharacters(in: .newlines) + (output.isEmpty ? "" : "\n")
    }

    private static func tomlString(_ value: String) -> String {
        var escaped = ""
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x08: escaped += "\\b"
            case 0x09: escaped += "\\t"
            case 0x0A: escaped += "\\n"
            case 0x0C: escaped += "\\f"
            case 0x0D: escaped += "\\r"
            case 0x22: escaped += "\\\""
            case 0x5C: escaped += "\\\\"
            case 0x00...0x1F, 0x7F:
                escaped += String(format: "\\u%04X", scalar.value)
            default: escaped.unicodeScalars.append(scalar)
            }
        }
        return "\"\(escaped)\""
    }
}

extension String {
    func ranges(of needle: String) -> [Range<String.Index>] {
        var result: [Range<String.Index>] = []
        var search = startIndex..<endIndex
        while let range = range(of: needle, range: search) {
            result.append(range)
            search = range.upperBound..<endIndex
        }
        return result
    }
}

struct AppFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

let messageTemplateVariables = Set([
    "{channel_name}", "{sender_name}", "{sender_member_id}", "{message_source}", "{message_text}", "{message_id}", "{mentions}",
])

func validateMessageTemplate(_ raw: String, defaultTemplate: String) throws -> String {
    let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if value.isEmpty { return defaultTemplate }
    guard value.count <= 2_000 else { throw AppFailure("消息模板不能超过 2000 字符") }
    let expression = try NSRegularExpression(pattern: #"\{[^{}]+\}"#)
    let range = NSRange(value.startIndex..., in: value)
    for match in expression.matches(in: value, range: range) {
        guard let tokenRange = Range(match.range, in: value),
              messageTemplateVariables.contains(String(value[tokenRange])) else {
            throw AppFailure("模板只支持 {channel_name}、{sender_name}、{sender_member_id}、{message_source}、{message_text}、{message_id}、{mentions}")
        }
    }
    return value
}

func renderMessageTemplate(
    _ template: String,
    channelName: String,
    senderName: String,
    senderMemberID: String = "member-id",
    messageSource: String,
    messageText: String,
    messageID: String,
    mentions: String = "无"
) -> String {
    func normalized(_ value: String) -> String {
        value.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }
    func safeInline(_ value: String) -> String {
        normalized(value).replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "`", with: "ˋ")
    }
    let source = normalized(template)
    let values = [
        "{channel_name}": safeInline(channelName),
        "{sender_name}": safeInline(senderName),
        "{sender_member_id}": safeInline(senderMemberID),
        "{message_source}": safeInline(messageSource),
        "{message_text}": normalized(messageText),
        "{message_id}": messageID,
        "{mentions}": safeInline(mentions),
    ]
    let expression = try! NSRegularExpression(
        pattern: #"\{(?:channel_name|sender_name|sender_member_id|message_source|message_text|message_id|mentions)\}"#
    )
    let quotePrefix = try! NSRegularExpression(pattern: #"^(?:[ \t]*>[ \t]?)+$"#)
    let sourceString = source as NSString
    let rendered = NSMutableString(string: source)
    for match in expression.matches(in: source, range: NSRange(location: 0, length: sourceString.length)).reversed() {
        let token = sourceString.substring(with: match.range)
        let lineStart = sourceString.range(of: "\n", options: .backwards, range: NSRange(location: 0, length: match.range.location))
        let prefixStart = lineStart.location == NSNotFound ? 0 : NSMaxRange(lineStart)
        let prefixRange = NSRange(location: prefixStart, length: match.range.location - prefixStart)
        let prefix = sourceString.substring(with: prefixRange)
        let continuation = quotePrefix.firstMatch(
            in: prefix,
            range: NSRange(location: 0, length: (prefix as NSString).length)
        ) == nil ? "" : prefix
        rendered.replaceCharacters(
            in: match.range,
            with: values[token, default: token].replacingOccurrences(of: "\n", with: "\n\(continuation)")
        )
    }
    return rendered as String
}
