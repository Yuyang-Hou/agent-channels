import AppKit
import CryptoKit
import Darwin
import Foundation
import Security
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

private let defaultOrigin = "https://rogerthat-production-fff6.up.railway.app"
private let keychainService = "com.agentchannels.channel"
private let managedConfigStart = "# >>> Agent Channels managed MCP >>>"
private let managedConfigEnd = "# <<< Agent Channels managed MCP <<<"
private let githubReleasesURL = URL(string: "https://api.github.com/repos/Yuyang-Hou/agent-channels/releases?per_page=100")!
private let automaticUpdateChecksKey = "automaticUpdateChecks"
private let loadedCodexMCPVersionKey = "loadedCodexMCPVersion"
private let shownCodexRestartVersionKey = "shownCodexRestartVersion"
private let localSendProtocolVersion = 2
private let maxChannelMessageLength = 8192
private let maxLocalSendFrameBytes = 64 * 1024
private let defaultMessageTemplate = """
> **↗ Agent Channels · 外部频道消息**
>
> **频道** `{channel_name}` · **来自** `{sender_name}` · `#{message_id}`
>
> {message_text}
"""
private let defaultSentMessageTemplate = """
> **↗ Agent Channels · 已发送到频道**
>
> **频道** `{channel_name}` · `#{message_id}`
>
> {message_text}
"""

private func compactTaskKey(_ raw: String) -> String? {
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

private func bridgeRecoveryClearsError(kind: String?, state: String) -> Bool {
    (state == "joined" && ["join", "session", "rejoin"].contains(kind)) ||
        (state == "connected" && kind == "connection") ||
        (state == "delivered" && (kind == "connection" || kind == "delivery"))
}

private func isPendingBridgeDelivery(_ kind: String?) -> Bool {
    kind == "delivery" || kind == "delivery_outcome_unknown"
}

private func bridgeErrorShouldReplace(current: String?, incoming: String?) -> Bool {
    !isPendingBridgeDelivery(current) || isPendingBridgeDelivery(incoming)
}

private func isCancellationError(_ error: Error) -> Bool {
    if error is CancellationError { return true }
    let nsError = error as NSError
    return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
}

private func requiresCodexRestart(configured: Bool, appVersion: String, loadedMCPVersion: String?) -> Bool {
    configured && loadedMCPVersion != appVersion
}

enum SelfMessagePolicy: String, Codable, CaseIterable, Identifiable {
    case excludeMember = "exclude_member"
    case includeOtherEndpoints = "include_other_endpoints"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .excludeMember: return "忽略本成员所有端点发送的消息"
        case .includeOtherEndpoints: return "接收本成员其他端点的消息"
        }
    }
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

private func reconciledChannelProfile(
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

    var id: String { "\(provider):\(conversationID)" }

    enum CodingKeys: String, CodingKey {
        case provider, title
        case conversationID = "conversation_id"
        case updatedAt = "updated_at"
    }
}

private struct HostConversationSearchResponse: Decodable {
    let ok: Bool
    let conversations: [HostConversationSummary]
}

private func hostDisplayName(_ provider: String) -> String {
    provider == "codex" ? "ChatGPT Codex" : provider
}

struct ChannelSubscription: Codable, Equatable, Identifiable {
    let id: UUID
    var channelID: UUID
    var taskID: UUID
    var enabled: Bool
    var template: String
    var sentMessageTemplate: String? = nil
    var selfMessagePolicy: SelfMessagePolicy
    var defaultSend: Bool
    var lastDeliveredMessageID: Int64?
    var lastDeliveredAt: Double?
    var uncertainMessageID: Int64? = nil
    var uncertainDetail: String? = nil
}

struct AppStateV2: Codable, Equatable {
    var version = 2
    var defaultCallsign = ""
    var channels: [ChannelProfile] = []
    var tasks: [TaskBinding] = []
    var subscriptions: [ChannelSubscription] = []
    var selectedChannelID: UUID?
}

enum MessageDirection: String, Codable { case inbound, outbound }
enum MessageDeliveryState: String, Codable {
    case pending, received, attempting, filtered, delivered, skipped, accepted, failed, unknown
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
    var source: MessageSourceReference? = nil

    var id: String { "\(channelID.uuidString):\(messageID)" }
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

private struct LocalMessageProvenance: Encodable {
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

private enum ReceivedDeliveryDecision: String {
    case record = "recorded"
    case alreadyProcessed = "already_processed"
    case unresolved
}

private func receivedDeliveryDecision(_ state: MessageDeliveryState?) -> ReceivedDeliveryDecision {
    guard let state else { return .record }
    switch state {
    case .delivered, .filtered, .skipped: return .alreadyProcessed
    case .attempting, .unknown: return .unresolved
    default: return .record
    }
}

private func advancedDeliveryCursor(_ current: Int64?, through messageID: Int64) -> Int64 {
    max(current ?? messageID, messageID)
}

private func continuesMessageGroup(
    previous: ChannelMessageRecord?,
    current: ChannelMessageRecord
) -> Bool {
    guard let previous else { return false }
    let interval = current.at - previous.at
    return current.from == previous.from && current.direction == previous.direction
        && interval >= 0 && interval <= 5 * 60 * 1000
}

private let pendingSendStatusDelayMilliseconds = 1_000.0

private func shouldShowPendingSendStatus(startedAt: Double, now: Double) -> Bool {
    now - startedAt >= pendingSendStatusDelayMilliseconds
}

private func channelDisplayName(_ nickname: String, original: String) -> String {
    let value = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
    return value.isEmpty ? original : value
}

private func recoverSubscriptionDeliveryState(
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

private func latestDeliveredChannelMessage(
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

    var id: String { memberID }

    enum CodingKeys: String, CodingKey {
        case memberID = "member_id"
        case name, role, status, online
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
        guard trimmed.hasPrefix("ac2:") else {
            throw AppFailure("邀请口令格式不正确，应以 ac2: 开头")
        }
        var encoded = String(trimmed.dropFirst(4))
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let data = Data(base64Encoded: encoded) else {
            throw AppFailure("邀请口令已损坏")
        }
        let invitation = try JSONDecoder().decode(ChannelInvitation.self, from: data)
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

private func alreadyJoinedChannel(
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
            "[mcp_servers.agent_channels]",
            "command = \(tomlString(sidecar))",
            "args = [\(tomlString("channel-mcp")), \(tomlString("--config")), \(tomlString(binding))]",
            managedConfigEnd,
        ].joined(separator: "\n")
    }

    static func installing(block: String, into existing: String) throws -> String {
        let startRanges = existing.ranges(of: managedConfigStart)
        let endRanges = existing.ranges(of: managedConfigEnd)
        if startRanges.isEmpty && endRanges.isEmpty {
            if existing.range(of: #"(?m)^\s*\[mcp_servers\.agent_channels\]\s*$"#, options: .regularExpression) != nil {
                throw AppFailure("~/.codex/config.toml 已有非 Agent Channels 管理的同名 MCP，请先手动处理")
            }
            let prefix = existing.isEmpty ? "" : existing.trimmingCharacters(in: .newlines) + "\n\n"
            return prefix + block + "\n"
        }
        guard startRanges.count == 1, endRanges.count == 1,
              startRanges[0].lowerBound < endRanges[0].lowerBound else {
            throw AppFailure("Agent Channels 配置标记不完整，未修改 ~/.codex/config.toml")
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
            throw AppFailure("Agent Channels 配置标记不完整，未修改 ~/.codex/config.toml")
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

private extension String {
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

private let messageTemplateVariables = Set([
    "{channel_name}", "{sender_name}", "{message_source}", "{message_text}", "{message_id}",
])

private func validateMessageTemplate(_ raw: String, defaultTemplate: String) throws -> String {
    let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if value.isEmpty { return defaultTemplate }
    guard value.count <= 2_000 else { throw AppFailure("消息模板不能超过 2000 字符") }
    let expression = try NSRegularExpression(pattern: #"\{[^{}]+\}"#)
    let range = NSRange(value.startIndex..., in: value)
    for match in expression.matches(in: value, range: range) {
        guard let tokenRange = Range(match.range, in: value),
              messageTemplateVariables.contains(String(value[tokenRange])) else {
            throw AppFailure("模板只支持 {channel_name}、{sender_name}、{message_source}、{message_text}、{message_id}")
        }
    }
    return value
}

private func renderMessageTemplate(
    _ template: String,
    channelName: String,
    senderName: String,
    messageSource: String,
    messageText: String,
    messageID: String
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
        "{message_source}": safeInline(messageSource),
        "{message_text}": normalized(messageText),
        "{message_id}": messageID,
    ]
    let expression = try! NSRegularExpression(
        pattern: #"\{(?:channel_name|sender_name|message_source|message_text|message_id)\}"#
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

enum AppPaths {
    static let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Agent Channels", isDirectory: true)
    static let state = support.appendingPathComponent("state-v2.json")
    static let legacyBinding = support.appendingPathComponent("binding.json")
    static let sendSocket = support.appendingPathComponent("send.sock")
    static let messages = support.appendingPathComponent("messages", isDirectory: true)
    static let logs = support.appendingPathComponent("logs", isDirectory: true)
    static let updates = support.appendingPathComponent("updates", isDirectory: true)
    static let pendingUpdateDMG = updates.appendingPathComponent("pending-update.dmg")
    static let pendingUpdate = updates.appendingPathComponent("pending-update.json")
    static let updateError = updates.appendingPathComponent("last-error.txt")
    static let codexDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".codex", isDirectory: true)
    static let codexConfig = codexDirectory.appendingPathComponent("config.toml")
    static let codexSkills = codexDirectory.appendingPathComponent("skills", isDirectory: true)
    static let agentChannelsSkill = codexSkills.appendingPathComponent("agent-channels", isDirectory: true)

    static var appIsInstalled: Bool {
        let app = Bundle.main.bundleURL.standardizedFileURL.path
        let userApplications = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications", isDirectory: true).path + "/"
        return app.hasPrefix("/Applications/") || app.hasPrefix(userApplications)
    }

    static func prepare() throws {
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: support.path)
        try FileManager.default.createDirectory(at: messages, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: messages.path)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: logs.path)
    }
}

enum ClientLog {
    private static let queue = DispatchQueue(label: "com.agentchannels.client-log")
    private static let maxBytes = 1_000_000

    static func record(
        _ level: String,
        _ event: String,
        detail: String? = nil,
        directory: URL = AppPaths.logs
    ) {
        let date = Date()
        queue.async {
            try? append(level: level, event: event, detail: detail, date: date, directory: directory)
        }
    }

    static func export(to destination: URL, directory: URL = AppPaths.logs) throws {
        try queue.sync {
            var data = Data()
            for url in [previousURL(directory), currentURL(directory)]
                where FileManager.default.fileExists(atPath: url.path) {
                data.append(try Data(contentsOf: url))
            }
            if data.isEmpty {
                data = Data("No Agent Channels client log entries.\n".utf8)
            }
            try data.write(to: destination, options: .atomic)
        }
    }

    private static func append(
        level: String,
        event: String,
        detail: String?,
        date: Date,
        directory: URL
    ) throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let cleanDetail = detail?
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
        let line = [
            ISO8601DateFormatter().string(from: date),
            level.uppercased(),
            event,
            cleanDetail,
        ].compactMap { $0 }.joined(separator: "\t") + "\n"
        let data = Data(line.utf8)
        let current = currentURL(directory)
        let existingBytes = ((try? FileManager.default.attributesOfItem(atPath: current.path)[.size]) as? NSNumber)?.intValue ?? 0
        if existingBytes + data.count > maxBytes {
            let previous = previousURL(directory)
            if FileManager.default.fileExists(atPath: previous.path) { try FileManager.default.removeItem(at: previous) }
            if FileManager.default.fileExists(atPath: current.path) { try FileManager.default.moveItem(at: current, to: previous) }
        }
        if !FileManager.default.fileExists(atPath: current.path) {
            _ = FileManager.default.createFile(atPath: current.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        let handle = try FileHandle(forWritingTo: current)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: current.path)
    }

    private static func currentURL(_ directory: URL) -> URL {
        directory.appendingPathComponent("client.log")
    }

    private static func previousURL(_ directory: URL) -> URL {
        directory.appendingPathComponent("client.previous.log")
    }
}

enum AgentChannelsSkillInstaller {
    static var bundledSkill: URL {
        Bundle.main.resourceURL!
            .appendingPathComponent("skills", isDirectory: true)
            .appendingPathComponent("agent-channels", isDirectory: true)
    }

    static func isInstalled(
        source: URL = bundledSkill,
        destination: URL = AppPaths.agentChannelsSkill
    ) -> Bool {
        FileManager.default.fileExists(atPath: source.appendingPathComponent("SKILL.md").path)
            && isManagedLink(source: source, destination: destination)
    }

    static func isManagedLink(
        source: URL = bundledSkill,
        destination: URL = AppPaths.agentChannelsSkill
    ) -> Bool {
        guard isSymbolicLink(destination),
              let target = try? resolvedLinkTarget(destination) else { return false }
        return target.standardizedFileURL == source.standardizedFileURL
    }

    static func install(
        source: URL = bundledSkill,
        destination: URL = AppPaths.agentChannelsSkill
    ) throws {
        guard FileManager.default.fileExists(atPath: source.appendingPathComponent("SKILL.md").path) else {
            throw AppFailure("App 安装包缺少 Agent Channels Skill，请重新安装")
        }
        if itemExists(destination) {
            guard isSymbolicLink(destination) else {
                throw AppFailure("~/.codex/skills/agent-channels 已存在且不由本 App 管理，请先手动处理")
            }
            guard try resolvedLinkTarget(destination).standardizedFileURL == source.standardizedFileURL else {
                throw AppFailure("~/.codex/skills/agent-channels 指向其他内容，未覆盖")
            }
            return
        }
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: source)
    }

    static func remove(
        source: URL = bundledSkill,
        destination: URL = AppPaths.agentChannelsSkill
    ) throws {
        try validateRemoval(source: source, destination: destination)
        guard itemExists(destination) else { return }
        try FileManager.default.removeItem(at: destination)
    }

    static func validateRemoval(
        source: URL = bundledSkill,
        destination: URL = AppPaths.agentChannelsSkill
    ) throws {
        guard itemExists(destination) else { return }
        guard isSymbolicLink(destination),
              try resolvedLinkTarget(destination).standardizedFileURL == source.standardizedFileURL else {
            throw AppFailure("未移除不由本 App 管理的 Agent Channels Skill")
        }
    }

    private static func itemExists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }

    private static func isSymbolicLink(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFLNK
    }

    private static func resolvedLinkTarget(_ destination: URL) throws -> URL {
        let raw = try FileManager.default.destinationOfSymbolicLink(atPath: destination.path)
        return raw.hasPrefix("/")
            ? URL(fileURLWithPath: raw)
            : destination.deletingLastPathComponent().appendingPathComponent(raw)
    }
}

enum CodexIntegrationInstaller {
    static func install(
        configURL: URL,
        block: String,
        skillSource: URL = AgentChannelsSkillInstaller.bundledSkill,
        skillDestination: URL = AppPaths.agentChannelsSkill
    ) throws {
        let existing = try CodexConfigEditor.reading(configURL) ?? ""
        let updated = try CodexConfigEditor.installing(block: block, into: existing)
        let skillLinkAlreadyExisted = AgentChannelsSkillInstaller.isManagedLink(
            source: skillSource,
            destination: skillDestination
        )
        do {
            try AgentChannelsSkillInstaller.install(source: skillSource, destination: skillDestination)
            if updated != existing { try CodexConfigEditor.writing(updated, to: configURL) }
        } catch {
            if !skillLinkAlreadyExisted {
                try? AgentChannelsSkillInstaller.remove(source: skillSource, destination: skillDestination)
            }
            throw error
        }
    }

    static func remove(
        configURL: URL,
        skillSource: URL = AgentChannelsSkillInstaller.bundledSkill,
        skillDestination: URL = AppPaths.agentChannelsSkill
    ) throws {
        try AgentChannelsSkillInstaller.validateRemoval(source: skillSource, destination: skillDestination)
        let existing = try CodexConfigEditor.reading(configURL)
        let updated = try existing.map { try CodexConfigEditor.removingManagedBlock(from: $0) }
        let configChanged = existing != updated
        if let updated, configChanged { try CodexConfigEditor.writing(updated, to: configURL) }
        do {
            try AgentChannelsSkillInstaller.remove(source: skillSource, destination: skillDestination)
        } catch {
            if let existing, configChanged { try? CodexConfigEditor.writing(existing, to: configURL) }
            throw error
        }
    }
}

private struct LocalSource: Codable {
    let provider: String
    let conversationId: String
}

private struct LocalSettingsPatch: Codable {
    let template: String?
    let sentMessageTemplate: String?
    let selfMessagePolicy: SelfMessagePolicy?
    let defaultSend: Bool?

    enum CodingKeys: String, CodingKey {
        case template
        case sentMessageTemplate = "sent_message_template"
        case selfMessagePolicy = "self_message_policy"
        case defaultSend = "default_send"
    }
}

private struct LocalSidecarEvent: Codable {
    let id: Int64?
    let from: String?
    let to: String?
    let text: String?
    let at: Double?
    let state: MessageDeliveryState?
    let error: String?

    let senderMemberID: String?
    let senderEndpointID: String?
    let senderName: String?
    let source: MessageSourceReference?

    enum CodingKeys: String, CodingKey {
        case id, from, to, text, at, state, error, source
        case senderMemberID = "sender_member_id"
        case senderEndpointID = "sender_endpoint_id"
        case senderName = "sender_name"
    }
}

private struct LocalSendRequest: Decodable {
    let version: Int
    let operation: String
    let source: LocalSource?
    let clientVersion: String?
    let channel: String?
    let message: String?
    let settings: LocalSettingsPatch?
    let subscriptionID: String?
    let event: LocalSidecarEvent?

    enum CodingKeys: String, CodingKey {
        case version, operation, source, channel, message, settings, event
        case clientVersion = "client_version"
        case subscriptionID = "subscription_id"
    }

    var sourceContext: LocalSource { source! }

    static func decode(_ data: Data) throws -> LocalSendRequest {
        let request = try JSONDecoder().decode(LocalSendRequest.self, from: data)
        guard request.version == localSendProtocolVersion else {
            throw AppFailure("本机发送协议版本不兼容")
        }
        let operations = [
            "mcp_ready", "list_channels", "inspect_message_source", "send", "subscribe", "unsubscribe", "get_settings", "update_settings",
            "record_received", "record_outcome",
        ]
        guard operations.contains(request.operation) else {
            throw AppFailure("不支持的本机操作")
        }
        if request.operation == "mcp_ready" {
            guard let clientVersion = request.clientVersion,
                  !clientVersion.isEmpty,
                  clientVersion.count <= 64,
                  !clientVersion.contains(where: \.isWhitespace) else {
                throw AppFailure("client_version is invalid")
            }
            return request
        }
        guard let source = request.source,
              source.provider == "codex",
              UUID(uuidString: source.conversationId) != nil else {
            throw AppFailure("当前 AI 会话上下文无效或尚未支持")
        }
        if request.operation == "send" {
            guard let message = request.message, !message.isEmpty else {
                throw AppFailure("message must be a non-empty string")
            }
            guard message.utf16.count <= maxChannelMessageLength else {
                throw AppFailure("message exceeds \(maxChannelMessageLength) characters")
            }
        }
        if ["subscribe", "unsubscribe", "get_settings", "update_settings"].contains(request.operation),
           request.channel?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            throw AppFailure("channel is required")
        }
        if ["record_received", "record_outcome"].contains(request.operation) {
            guard request.channel?.isEmpty == false,
                  let subscriptionID = request.subscriptionID,
                  UUID(uuidString: subscriptionID) != nil,
                  request.event != nil else {
                throw AppFailure("invalid sidecar ledger request")
            }
        }
        return request
    }
}

private struct LocalChannelSummary: Encodable {
    let channel: String
    let name: String
    let role: String
    let subscribed: Bool
    let defaultSend: Bool

    enum CodingKeys: String, CodingKey {
        case channel, name, role, subscribed
        case defaultSend = "default_send"
    }
}

private struct LocalSubscriptionSummary: Encodable {
    let channel: String
    let receiveEnabled: Bool
    let template: String
    let sentMessageTemplate: String
    let selfMessagePolicy: SelfMessagePolicy
    let defaultSend: Bool

    enum CodingKeys: String, CodingKey {
        case channel, template
        case sentMessageTemplate = "sent_message_template"
        case receiveEnabled = "receive_enabled"
        case selfMessagePolicy = "self_message_policy"
        case defaultSend = "default_send"
    }
}

private struct LocalOperationResult: Encodable {
    let id: String?
    let callsign: String?
    let channel: String?
    let channels: [LocalChannelSummary]?
    let settings: LocalSubscriptionSummary?
    let provenance: LocalMessageProvenance?
    let message: String?

    init(
        id: String? = nil,
        callsign: String? = nil,
        channel: String? = nil,
        channels: [LocalChannelSummary]? = nil,
        settings: LocalSubscriptionSummary? = nil,
        provenance: LocalMessageProvenance? = nil,
        message: String? = nil
    ) {
        self.id = id
        self.callsign = callsign
        self.channel = channel
        self.channels = channels
        self.settings = settings
        self.provenance = provenance
        self.message = message
    }

    static func send(id: String, callsign: String, channel: String, message: String) -> LocalOperationResult {
        LocalOperationResult(id: id, callsign: callsign, channel: channel, message: message)
    }
}

private struct LocalSendResponse: Encodable {
    let version = localSendProtocolVersion
    let ok: Bool
    let result: LocalOperationResult?
    let outcome: String?
    let error: String?

    static func success(_ result: LocalOperationResult) -> LocalSendResponse {
        LocalSendResponse(ok: true, result: result, outcome: nil, error: nil)
    }

    static func failure(_ error: String, outcome: String = "definitive") -> LocalSendResponse {
        LocalSendResponse(ok: false, result: nil, outcome: outcome, error: error)
    }
}

private enum ChannelSendFailure: LocalizedError {
    case definitive(String)
    case unknown(String)

    var errorDescription: String? {
        switch self {
        case .definitive(let message), .unknown(let message): return message
        }
    }
}

private struct ChannelAuthorizationFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private final class LocalSendServer {
    typealias Handler = @MainActor (LocalSendRequest) async -> LocalSendResponse

    private let socketURL: URL
    private let handler: Handler
    private let queue = DispatchQueue(label: "com.agentchannels.local-send", qos: .utility)
    private var source: DispatchSourceRead?
    private var ownsSocket = false

    init(socketURL: URL, handler: @escaping Handler) {
        self.socketURL = socketURL
        self.handler = handler
    }

    func start() throws {
        guard source == nil else { return }
        try removeStaleSocket()

        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw posixFailure("无法创建本机发送 socket") }
        do {
            var address = try socketAddress()
            let bound = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard bound == 0 else { throw posixFailure("无法绑定本机发送 socket") }
            ownsSocket = true
            guard Darwin.chmod(socketURL.path, S_IRUSR | S_IWUSR) == 0 else {
                throw posixFailure("无法保护本机发送 socket")
            }
            guard Darwin.listen(descriptor, 8) == 0 else { throw posixFailure("无法监听本机发送 socket") }

            let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
            source.setEventHandler { [weak self] in self?.accept(descriptor) }
            source.setCancelHandler { Darwin.close(descriptor) }
            self.source = source
            source.resume()
        } catch {
            Darwin.close(descriptor)
            if ownsSocket { _ = unlink(socketURL.path) }
            ownsSocket = false
            throw error
        }
    }

    func stop() {
        source?.cancel()
        source = nil
        if ownsSocket { _ = unlink(socketURL.path) }
        ownsSocket = false
    }

    deinit { stop() }

    private func accept(_ descriptor: Int32) {
        let client = Darwin.accept(descriptor, nil, nil)
        guard client >= 0 else { return }
        var peerUID: uid_t = 0
        var peerGID: gid_t = 0
        guard getpeereid(client, &peerUID, &peerGID) == 0, peerUID == geteuid() else {
            Darwin.close(client)
            return
        }
        var enabled: Int32 = 1
        _ = withUnsafePointer(to: &enabled) {
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, $0, socklen_t(MemoryLayout<Int32>.size))
        }
        var timeout = timeval(tv_sec: 30, tv_usec: 0)
        _ = withUnsafePointer(to: &timeout) {
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, $0, socklen_t(MemoryLayout<timeval>.size))
        }
        queue.async { [weak self] in self?.readRequest(from: client) }
    }

    private func readRequest(from client: Int32) {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while data.count <= maxLocalSendFrameBytes, data.firstIndex(of: 0x0A) == nil {
            let count = buffer.withUnsafeMutableBytes {
                Darwin.recv(client, $0.baseAddress, $0.count, 0)
            }
            guard count > 0 else { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        guard let newline = data.firstIndex(of: 0x0A), newline <= maxLocalSendFrameBytes else {
            return Self.write(LocalSendResponse.failure("invalid local send request"), to: client)
        }
        let request: LocalSendRequest
        do {
            request = try LocalSendRequest.decode(data.subdata(in: data.startIndex..<newline))
        } catch {
            return Self.write(LocalSendResponse.failure(error.localizedDescription), to: client)
        }
        Task { @MainActor [weak self] in
            guard let self else {
                Darwin.close(client)
                return
            }
            let response = await handler(request)
            queue.async { Self.write(response, to: client) }
        }
    }

    private static func write(_ response: LocalSendResponse, to client: Int32) {
        defer { Darwin.close(client) }
        guard var payload = try? JSONEncoder().encode(response) else { return }
        payload.append(0x0A)
        payload.withUnsafeBytes { bytes in
            var sent = 0
            while sent < bytes.count {
                let count = Darwin.send(client, bytes.baseAddress?.advanced(by: sent), bytes.count - sent, MSG_NOSIGNAL)
                if count <= 0 { return }
                sent += count
            }
        }
    }

    private func removeStaleSocket() throws {
        var info = stat()
        guard lstat(socketURL.path, &info) == 0 else {
            if errno == ENOENT { return }
            throw posixFailure("无法检查本机发送 socket")
        }
        guard info.st_uid == geteuid(), info.st_mode & S_IFMT == S_IFSOCK else {
            throw AppFailure("本机发送 socket 路径被非 socket 文件占用")
        }
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw posixFailure("无法探测本机发送 socket") }
        defer { Darwin.close(descriptor) }
        var address = try socketAddress()
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if result == 0 { throw AppFailure("Agent Channels 已在运行") }
        guard errno == ECONNREFUSED else { throw posixFailure("无法探测本机发送 socket") }
        guard unlink(socketURL.path) == 0 else { throw posixFailure("无法清理旧的本机发送 socket") }
    }

    private func socketAddress() throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let path = Array(socketURL.path.utf8) + [0]
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard path.count <= capacity else { throw AppFailure("本机发送 socket 路径过长") }
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            destination.copyBytes(from: path)
        }
        return address
    }

    private func posixFailure(_ prefix: String) -> AppFailure {
        AppFailure("\(prefix)：\(String(cString: strerror(errno)))")
    }
}

struct ReleaseVersion: Comparable, CustomStringConvertible {
    let major: Int
    let minor: Int
    let patch: Int
    let beta: Int?

    init?(_ raw: String) {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.hasPrefix("v") { value.removeFirst() }
        let parts = value.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let core = parts[0].split(separator: ".", omittingEmptySubsequences: false)
        guard core.count == 3,
              let major = Int(core[0]), let minor = Int(core[1]), let patch = Int(core[2]),
              major >= 0, minor >= 0, patch >= 0 else { return nil }
        var beta: Int?
        if parts.count == 2 {
            let prerelease = parts[1].split(separator: ".", omittingEmptySubsequences: false)
            guard prerelease.count == 2, prerelease[0] == "beta",
                  let number = Int(prerelease[1]), number >= 0 else { return nil }
            beta = number
        }
        self.major = major
        self.minor = minor
        self.patch = patch
        self.beta = beta
    }

    static func < (lhs: ReleaseVersion, rhs: ReleaseVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }
        switch (lhs.beta, rhs.beta) {
        case (.some(let left), .some(let right)): return left < right
        case (.some, .none): return true
        case (.none, .some): return false
        case (.none, .none): return false
        }
    }

    var description: String {
        let core = "\(major).\(minor).\(patch)"
        return beta.map { "\(core)-beta.\($0)" } ?? core
    }
}

enum ReleaseChannel: Equatable {
    case stable
    case beta

    var title: String { self == .stable ? "正式版" : "Beta" }
}

struct GitHubReleaseAsset: Decodable {
    let name: String
    let browserDownloadURL: URL

    enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadURL = "browser_download_url"
    }
}

struct GitHubRelease: Decodable {
    let tagName: String
    let htmlURL: URL
    let draft: Bool
    let prerelease: Bool
    let assets: [GitHubReleaseAsset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
        case draft, prerelease, assets
    }

    var version: ReleaseVersion? { ReleaseVersion(tagName) }
    var arm64DMG: URL? {
        assets.first {
            let name = $0.name.lowercased()
            return name.hasSuffix(".dmg") && name.contains("arm64")
        }?.browserDownloadURL
    }
}

private struct PendingUpdate: Codable {
    let version: String
}

private enum UpdateCoordinator {
    static func pendingVersion() -> String? {
        guard FileManager.default.fileExists(atPath: AppPaths.pendingUpdateDMG.path),
              let data = try? Data(contentsOf: AppPaths.pendingUpdate),
              let pending = try? JSONDecoder().decode(PendingUpdate.self, from: data) else { return nil }
        return pending.version
    }

    static func saveDownloadedDMG(_ temporaryURL: URL, version: String) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: AppPaths.updates, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? manager.removeItem(at: AppPaths.pendingUpdateDMG)
        try manager.moveItem(at: temporaryURL, to: AppPaths.pendingUpdateDMG)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: AppPaths.pendingUpdateDMG.path)
        try JSONEncoder().encode(PendingUpdate(version: version)).write(to: AppPaths.pendingUpdate, options: .atomic)
    }

    static func launchInstallerIfNeeded(currentVersion: String) throws -> Bool {
        guard let pending = pendingVersion(), let current = ReleaseVersion(currentVersion),
              let available = ReleaseVersion(pending) else { return false }
        guard current < available else {
            try? FileManager.default.removeItem(at: AppPaths.pendingUpdate)
            try? FileManager.default.removeItem(at: AppPaths.pendingUpdateDMG)
            return false
        }
        guard AppPaths.appIsInstalled else { throw AppFailure("更新已下载；请先把 App 移到 Applications") }
        let helper = Bundle.main.executableURL!.deletingLastPathComponent().appendingPathComponent("agent-channels-updater")
        guard FileManager.default.isExecutableFile(atPath: helper.path) else { throw AppFailure("更新助手缺失") }
        let process = Process()
        process.executableURL = helper
        process.arguments = [
            String(getpid()), AppPaths.pendingUpdateDMG.path, Bundle.main.bundleURL.path,
            pending, AppPaths.pendingUpdate.path, AppPaths.updateError.path,
        ]
        try process.run()
        DispatchQueue.main.async { NSApplication.shared.terminate(nil) }
        return true
    }

    static func consumeInstallError() -> String? {
        guard let message = try? String(contentsOf: AppPaths.updateError, encoding: .utf8) else { return nil }
        try? FileManager.default.removeItem(at: AppPaths.updateError)
        return message
    }
}

enum BrandAssets {
    static let menuBarImage: NSImage? = {
        guard let url = Bundle.main.url(forResource: "AgentChannelsMenuBar", withExtension: "svg"),
              let image = NSImage(contentsOf: url) else { return nil }
        image.isTemplate = true
        image.size = NSSize(width: 18, height: 18)
        return image
    }()
}

enum KeychainStore {
    static func set(_ value: String, service: String, account: String) throws {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else { throw keychainError(updateStatus) }
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw keychainError(addStatus) }
    }

    static func get(service: String, account: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else {
            throw keychainError(status)
        }
        return value
    }

    static func delete(service: String, account: String) throws {
        let status = SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ] as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw keychainError(status) }
    }

    private static func keychainError(_ status: OSStatus) -> AppFailure {
        let detail = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
        return AppFailure("Keychain 操作失败：\(detail)")
    }
}

struct SidecarResult {
    let status: Int32
    let stdout: String
    let stderr: String
}

enum Sidecar {
    static var executable: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/rogerthat-sidecar")
    }

    static func run(_ arguments: [String], stdin: Data? = nil) async throws -> SidecarResult {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            let output = Pipe()
            let error = Pipe()
            let input = Pipe()
            process.executableURL = executable
            process.arguments = arguments
            process.standardOutput = output
            process.standardError = error
            process.standardInput = input
            do {
                try process.run()
            } catch {
                throw AppFailure("无法启动内嵌 Bridge：\(error.localizedDescription)")
            }
            if let stdin { input.fileHandleForWriting.write(stdin) }
            try? input.fileHandleForWriting.close()
            process.waitUntilExit()
            let out = output.fileHandleForReading.readDataToEndOfFile()
            let err = error.fileHandleForReading.readDataToEndOfFile()
            return SidecarResult(
                status: process.terminationStatus,
                stdout: String(decoding: out, as: UTF8.self),
                stderr: String(decoding: err, as: UTF8.self)
            )
        }.value
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
            showNotice(title: "Agent Channels", message: "频道昵称不能超过 64 个字符")
            return
        }
        state.channels[index].displayName = channelDisplayName(nickname, original: profile.channel)
        persistState()
    }

    func refreshHistory() async {
        guard let profile = selectedChannel else { return }
        do {
            let json = try await authorizedJSON(profile, suffix: "history?limit=100", method: "GET")
            guard selectedChannelID == profile.id else { return }
            let entries = (json["history"] as? [[String: Any]]) ?? []
            for entry in entries {
                guard var record = messageRecord(entry, channelID: profile.id, state: .received) else { continue }
                if record.senderMemberID == profile.memberID {
                    record.direction = .outbound
                    record.state = .accepted
                }
                if messages.contains(where: { $0.id == record.id }) { continue }
                upsertMessage(record)
            }
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
        alert.informativeText = "该成员的现有凭证、Session 和消息流会立即失效。"
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
        let pending = ChannelMessageRecord(
            channelID: profile.id,
            messageID: "local-\(UUID().uuidString.lowercased())",
            direction: .outbound,
            from: state.defaultCallsign,
            to: "all",
            text: text,
            at: Date().timeIntervalSince1970 * 1000,
            state: .pending,
            source: MessageSourceReference(provider: "agent-channels", label: "Agent Channels App")
        )
        upsertMessage(pending, persist: false)
        busy = true
        defer { busy = false }
        do {
            let result = try await sendChannelMessage(
                text,
                profile: profile,
                endpoint: endpointCallsign(profile, kind: "app"),
                source: MessageSourceReference(provider: "agent-channels", label: "Agent Channels App")
            )
            composerText = ""
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
                source: MessageSourceReference(provider: "agent-channels", label: "Agent Channels App")
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
        source: MessageSourceReference
    ) async throws -> (id: String, callsign: String, memberID: String, endpointID: String) {
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
            let json = try await requestJSON(
                url: base.appendingPathComponent("send"),
                method: "POST",
                bearer: credential,
                headers: ["X-Session-Id": session],
                body: ["to": "all", "message": message, "source": sourceJSON]
            )
            guard json["ok"] as? Bool == true else {
                throw ChannelSendFailure.unknown("频道发送结果未知：服务端未返回有效回执")
            }
            if let id = json["id"] as? String { return (id, endpoint, memberID, endpointID) }
            if let id = json["id"] as? NSNumber { return (id.stringValue, endpoint, memberID, endpointID) }
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
            source: source
        )
    }

    private func upsertMessage(_ record: ChannelMessageRecord, persist: Bool = true) {
        if record.channelID == selectedChannelID {
            if let index = messages.firstIndex(where: { $0.id == record.id }) {
                messages[index] = record
            } else {
                messages.append(record)
                messages.sort { ($0.at, $0.messageID) < ($1.at, $1.messageID) }
                if messages.count > 500 { messages.removeFirst(messages.count - 500) }
            }
        }
        if persist { try? MessageLedger.append(record) }
        if record.channelID == selectedChannelID { markSelectedChannelRead() }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

private extension DateFormatter {
    static let delivery: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "MM-dd HH:mm:ss"
        return formatter
    }()

    static let invitation: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()
}

struct StatusRow: View {
    let name: String
    let value: String

    private var color: Color {
        if value.contains("已连接") || value.contains("可用") || value.contains("已绑定") || value.contains("已配置") { return .green }
        if value.contains("异常") || value.contains("不可用") || value.contains("需重新") { return .red }
        return .secondary
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(name).foregroundStyle(.secondary).frame(width: 58, alignment: .leading)
            Circle().fill(color).frame(width: 7, height: 7)
            Text(value).lineLimit(1)
            Spacer(minLength: 0)
        }
        .font(.system(size: 12))
    }
}

struct BrandIcon: View {
    let fallback: String
    let size: CGFloat

    var body: some View {
        if fallback.contains("exclamationmark") || BrandAssets.menuBarImage == nil {
            Image(systemName: fallback).font(.system(size: size))
        } else if let image = BrandAssets.menuBarImage {
            Image(nsImage: image)
                .renderingMode(.template)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
        }
    }
}


private final class SubscriptionListener {
    let subscriptionID: UUID
    let process: Process
    let output: Pipe
    let error: Pipe
    var remainder = ""
    var expectedStop = false

    init(subscriptionID: UUID, process: Process, output: Pipe, error: Pipe) {
        self.subscriptionID = subscriptionID
        self.process = process
        self.output = output
        self.error = error
    }
}

private enum MessageLedger {
    static func append(_ record: ChannelMessageRecord) throws {
        try AppPaths.prepare()
        let url = fileURL(record.channelID)
        var data = try JSONEncoder().encode(record)
        data.append(0x0A)
        if !FileManager.default.fileExists(atPath: url.path) {
            _ = FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        try handle.synchronize()
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func load(_ channelID: UUID) -> [ChannelMessageRecord] {
        let url = fileURL(channelID)
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var latest: [String: ChannelMessageRecord] = [:]
        for line in raw.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let record = try? JSONDecoder().decode(ChannelMessageRecord.self, from: data) else { continue }
            latest[record.id] = record
        }
        return latest.values.sorted { ($0.at, $0.messageID) < ($1.at, $1.messageID) }.suffix(500)
    }

    static func remove(_ channelID: UUID) throws {
        let url = fileURL(channelID)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }

    static func appendDelivery(_ record: SubscriptionDeliveryRecord) throws {
        try AppPaths.prepare()
        let url = deliveryFileURL(record.subscriptionID)
        var data = try JSONEncoder().encode(record)
        data.append(0x0A)
        if !FileManager.default.fileExists(atPath: url.path) {
            _ = FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        try handle.synchronize()
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func loadDeliveries(_ subscriptionID: UUID) -> [SubscriptionDeliveryRecord] {
        let url = deliveryFileURL(subscriptionID)
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var latest: [String: SubscriptionDeliveryRecord] = [:]
        for line in raw.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let record = try? JSONDecoder().decode(SubscriptionDeliveryRecord.self, from: data) else { continue }
            latest[record.id] = record
        }
        return latest.values.sorted { $0.updatedAt < $1.updatedAt }
    }

    static func removeDeliveries(_ subscriptionID: UUID) throws {
        let url = deliveryFileURL(subscriptionID)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }

    private static func fileURL(_ channelID: UUID) -> URL {
        AppPaths.messages.appendingPathComponent("\(channelID.uuidString).jsonl")
    }

    private static func deliveryFileURL(_ subscriptionID: UUID) -> URL {
        AppPaths.messages.appendingPathComponent("delivery-\(subscriptionID.uuidString).jsonl")
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
    @Published var codexIntegrationNeedsRestart = false
    @Published var loadedCodexMCPVersion = UserDefaults.standard.string(forKey: loadedCodexMCPVersionKey)
    @Published var updateStatus = "未检查"
    @Published var automaticUpdateChecks = UserDefaults.standard.bool(forKey: automaticUpdateChecksKey)
    @Published var draftNickname = ""
    @Published var draftChannelName = ""
    @Published var invitationInput = ""
    @Published var draftTask = ""
    @Published var conversationSearchResults: [HostConversationSummary] = []
    @Published var conversationSearchStatus = ""
    @Published var composerText = ""
    @Published var showAddChannel = false
    @Published var oldBetaDataDetected = FileManager.default.fileExists(atPath: AppPaths.legacyBinding.path)

    private var listeners: [UUID: SubscriptionListener] = [:]
    private var startingListeners: Set<UUID> = []
    private var listenerGenerations: [UUID: Int] = [:]
    private var bridgeErrorKinds: [UUID: String] = [:]
    private var bridgeErrorMessages: [UUID: String] = [:]
    private var presentedBridgeError: String?
    private var feedTasks: [UUID: Task<Void, Never>] = [:]
    private var localSendServer: LocalSendServer?
    private var updateTimer: Timer?

    private init() {
        try? AppPaths.prepare()
        var loaded = Self.loadState()
        Self.recoverDeliveryState(&loaded)
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
                guard let self else { return .failure("Agent Channels app is unavailable") }
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
        }
    }

    var currentVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "AgentChannelsReleaseVersion") as? String)
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

    var menuIcon: String { lastError.isEmpty ? "paperplane.circle" : "exclamationmark.triangle.fill" }
    var runningListenerCount: Int { listeners.count }
    var enabledSubscriptionCount: Int { state.subscriptions.filter(\.enabled).count }

    func selectChannel(_ id: UUID?) {
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
                await refreshHistory()
                await refreshMembers()
                await refreshInvitations()
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
                let channels = state.channels.map { profile in
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
                        message: "当前会话没有可追溯的已投递 Agent Channels 消息；这不证明其他消息一定是用户手动输入"
                    ))
                }
                let sourceKind: String
                switch record.source?.provider {
                case "agent-channels": sourceKind = "agent_channels_app"
                case "codex": sourceKind = "codex_mcp"
                default: sourceKind = "unknown"
                }
                return .success(LocalOperationResult(
                    provenance: LocalMessageProvenance(
                        found: true,
                        origin: "agent_channels",
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
                    message: "最近一条已投递消息来自 Agent Channels：\(profile.displayName) #\(record.messageID)，发送者 \(record.from)"
                ))
            case "send":
                guard let message = request.message else { throw AppFailure("message is required") }
                let (task, subscription, profile) = try outboundRoute(source: request.sourceContext, channel: request.channel)
                let endpoint = endpointCallsign(profile, conversationID: task.conversationID, kind: "t")
                do {
                    let receipt = try await sendChannelMessage(
                        message,
                        profile: profile,
                        endpoint: endpoint,
                        source: MessageSourceReference(
                            provider: task.provider,
                            conversationID: task.conversationID,
                            label: taskLabel(task.id)
                        )
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
                        source: MessageSourceReference(
                            provider: task.provider,
                            conversationID: task.conversationID,
                            label: taskLabel(task.id)
                        )
                    ))
                    let confirmation = renderMessageTemplate(
                        subscription.sentMessageTemplate ?? defaultSentMessageTemplate,
                        channelName: profile.displayName,
                        senderName: state.defaultCallsign,
                        messageSource: taskLabel(task.id),
                        messageText: message,
                        messageID: receipt.id
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
                        listenerStatus[subscription.id] = "发送结果未知"
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
        let query = draftTask.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            conversationSearchResults = []
            conversationSearchStatus = ""
            return
        }
        busy = true
        defer { busy = false }
        do {
            var arguments = ["host-conversations", "--host-provider", "codex", "--limit", "30"]
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

    func bindHostConversation(_ conversation: HostConversationSummary) async {
        draftTask = conversation.conversationID
        await addTaskSubscription()
    }

    func addTaskSubscription() async {
        guard let profile = selectedChannel else { return }
        busy = true
        defer { busy = false }
        do {
            let raw = draftTask.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty else { throw AppFailure("请输入 AI 会话 ID 或链接") }
            let result = try await Sidecar.run([
                "host-preflight",
                "--host-provider", "codex",
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
            _ = try await subscribe(
                source: LocalSource(provider: provider, conversationId: conversationID.lowercased()),
                profile: profile
            )
            draftTask = ""
            conversationSearchResults = []
            conversationSearchStatus = ""
            lastError = ""
        } catch {
            fail(error)
        }
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
        }
        persistState()
    }

    func taskLabel(_ taskID: UUID) -> String {
        guard let task = state.tasks.first(where: { $0.id == taskID }) else { return "未知会话" }
        return "\(hostDisplayName(task.provider)) · \(task.conversationID.prefix(8))…"
    }

    func openTask(_ taskID: UUID) {
        guard let task = state.tasks.first(where: { $0.id == taskID }) else {
            fail(AppFailure("AI 会话不存在"))
            return
        }
        guard task.provider == "codex",
              let url = URL(string: "codex://threads/\(task.conversationID)"),
              NSWorkspace.shared.open(url) else {
            fail(AppFailure("无法打开 \(hostDisplayName(task.provider)) 会话，请确认对应 AI 应用已安装且会话仍存在"))
            return
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
    ) throws -> (TaskBinding, ChannelSubscription, ChannelProfile) {
        guard let task = taskBinding(for: source) else { throw AppFailure("当前会话尚未连接 Agent Channels") }
        let candidates = state.subscriptions.filter { subscription in
            guard subscription.taskID == task.id,
                  state.channels.contains(where: { $0.id == subscription.channelID }) else { return false }
            if let channel, !channel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                guard let profile = try? resolveChannel(channel) else { return false }
                return subscription.channelID == profile.id
            }
            return true
        }
        let subscription: ChannelSubscription
        if channel?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            guard candidates.count == 1, let value = candidates.first else {
                throw AppFailure("当前会话未启用该频道的消息接收")
            }
            subscription = value
        } else {
            let defaults = candidates.filter(\.defaultSend)
            if defaults.count == 1, let value = defaults.first { subscription = value }
            else if defaults.isEmpty, candidates.count == 1, let value = candidates.first { subscription = value }
            else if candidates.isEmpty { throw AppFailure("当前会话没有可发送的频道") }
            else { throw AppFailure("当前会话连接了多个频道，请指定 channel 或设置唯一默认回复频道") }
        }
        guard let profile = state.channels.first(where: { $0.id == subscription.channelID }) else {
            throw AppFailure("订阅对应的频道不存在")
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
            ])
            guard listenerCanStart(id, generation: generation) else { return }
            guard preflight.status == 0 else {
                let detail = preflight.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                throw AppFailure(detail.isEmpty ? "AI 会话当前不可用" : detail)
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
              let subscription = state.subscriptions.first(where: { $0.id == id }) else { return false }
        return subscription.enabled && subscription.uncertainMessageID == nil
    }

    func stopListener(_ id: UUID) {
        listenerGenerations[id, default: 0] += 1
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
              subscription.enabled, subscription.uncertainMessageID == nil else { return }
        if listeners[id] == nil && !startingListeners.contains(id) { Task { await startListener(id) } }
        else { stopListener(id) }
    }

    private func scheduleListenerRestart(_ id: UUID) {
        guard state.subscriptions.first(where: { $0.id == id })?.enabled == true else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            guard let self,
                  self.state.subscriptions.first(where: { $0.id == id })?.enabled == true,
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
               subscription.enabled, subscription.uncertainMessageID == nil {
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
        bridgeErrorKinds.removeValue(forKey: id)
        bridgeErrorMessages.removeValue(forKey: id)
        guard lastError == displayed else {
            if bridgeErrorMessages.isEmpty { presentedBridgeError = nil }
            return
        }
        presentedBridgeError = bridgeErrorMessages.values.first
        lastError = presentedBridgeError ?? ""
    }

    private func consumeListenerStderr(_ data: Data, id: UUID) {
        guard let listener = listeners[id] else { return }
        listener.remainder += String(decoding: data, as: UTF8.self)
        while let newline = listener.remainder.firstIndex(of: "\n") {
            let line = String(listener.remainder[..<newline])
            listener.remainder.removeSubrange(...newline)
            guard line.hasPrefix("@agent-channels "),
                  let raw = line.dropFirst("@agent-channels ".count).data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
                  let state = event["state"] as? String else { continue }
            clearRecoveredBridgeError(id, state: state)
            switch state {
            case "joined", "connecting": listenerStatus[id] = "正在连接…"
            case "connected": listenerStatus[id] = "正在接收"
            case "reconnecting": listenerStatus[id] = "正在重连…"
            case "delivered": listenerStatus[id] = "已转发到会话 #\(event["messageId"] ?? "")"
            case "filtered": listenerStatus[id] = "已过滤自消息"
            case "error":
                let detail = (event["error"] as? String) ?? (event["kind"] as? String) ?? "未知错误"
                listenerStatus[id] = "异常：\(detail)"
                let kind = (event["kind"] as? String) ?? "unknown"
                ClientLog.record("error", "listener_error", detail: "kind=\(kind) \(detail)")
                if bridgeErrorShouldReplace(current: bridgeErrorKinds[id], incoming: kind) {
                    let message = "订阅异常：\(detail)"
                    bridgeErrorKinds[id] = kind
                    bridgeErrorMessages[id] = message
                    presentedBridgeError = message
                    lastError = message
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
            source: event.source
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
            if outcome == .filtered { listenerStatus[subscriptionID] = "已过滤自消息" }
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
                let base = try channelBaseURL(reconciledProfile)
                var request = URLRequest(url: base.appendingPathComponent("stream"))
                request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
                request.setValue(session, forHTTPHeaderField: "X-Session-Id")
                request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                let (bytes, response) = try await URLSession.shared.bytes(for: request)
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    if status == 401 { throw ChannelAuthorizationFailure(message: "频道成员权限已失效") }
                    throw AppFailure("频道消息流连接失败（HTTP \(status)）")
                }
                channelStatus[channelID] = "已连接"
                backoff = 1_000_000_000
                var event = ""
                var dataLines: [String] = []
                for try await line in bytes.lines {
                    if Task.isCancelled { return }
                    if line.isEmpty {
                        if event == "message", !dataLines.isEmpty {
                            handleFeedData(dataLines.joined(separator: "\n"), profile: reconciledProfile)
                        } else if event == "error", !dataLines.isEmpty {
                            let raw = dataLines.joined(separator: "\n")
                            let data = raw.data(using: .utf8)
                            let payload = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                            if payload?["code"] as? String == "member_revoked" {
                                throw ChannelAuthorizationFailure(message: (payload?["error"] as? String) ?? "频道成员权限已撤销")
                            }
                            throw AppFailure((payload?["error"] as? String) ?? "频道消息流异常")
                        }
                        event = ""
                        dataLines.removeAll(keepingCapacity: true)
                    } else if line.hasPrefix("event: ") {
                        event = String(line.dropFirst(7))
                    } else if line.hasPrefix("data: ") {
                        dataLines.append(String(line.dropFirst(6)))
                    }
                }
                throw AppFailure("频道消息流已关闭")
            } catch let error as ChannelAuthorizationFailure {
                markChannelAuthorizationLost(channelID, detail: error.localizedDescription)
                feedTasks.removeValue(forKey: channelID)
                return
            } catch {
                if Task.isCancelled { return }
                channelStatus[channelID] = "正在重连：\(error.localizedDescription)"
                ClientLog.record("warning", "channel_feed_reconnecting", detail: error.localizedDescription)
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

    private func handleFeedData(_ raw: String, profile: ChannelProfile) {
        guard let data = raw.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let record = messageRecord(json, channelID: profile.id, state: .received) else { return }
        let existing = profile.id == selectedChannelID ? messages : MessageLedger.load(profile.id)
        if existing.contains(where: { $0.id == record.id }) { return }
        var stored = record
        if record.senderMemberID == profile.memberID {
            stored.direction = .outbound
            stored.state = .accepted
        }
        upsertMessage(stored)
    }
}

extension AppModel {
    func refreshCodexIntegrationStatus() {
        let raw = (try? String(contentsOf: AppPaths.codexConfig, encoding: .utf8)) ?? ""
        let mcp = raw.contains(managedConfigStart) && raw.contains(AppPaths.state.path)
        let skill = AgentChannelsSkillInstaller.isInstalled()
        codexIntegrationNeedsRestart = requiresCodexRestart(
            configured: mcp && skill,
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
                message: "请完全退出并重新打开 ChatGPT，加载 Agent Channels MCP \(self.currentVersion)。此提示会在新 MCP 连接后自动消失。"
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
            guard AppPaths.appIsInstalled else { throw AppFailure("请先把 Agent Channels.app 移到 Applications 后再启用 Codex 集成") }
            persistState()
            try FileManager.default.createDirectory(at: AppPaths.codexDirectory, withIntermediateDirectories: true)
            let block = CodexConfigEditor.managedBlock(sidecar: Sidecar.executable.path, binding: AppPaths.state.path)
            try CodexIntegrationInstaller.install(configURL: AppPaths.codexConfig, block: block)
            loadedCodexMCPVersion = nil
            UserDefaults.standard.removeObject(forKey: loadedCodexMCPVersionKey)
            UserDefaults.standard.set(currentVersion, forKey: shownCodexRestartVersionKey)
            showNotice(title: "Codex 集成已启用", message: "请完全退出并重新打开 ChatGPT，让所有 task 加载 Agent Channels 工具与 Skill。")
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
            if interactive { showNotice(title: "Agent Channels", message: "更新 " + pending + " 已下载，重启 App 后自动安装。") }
            return
        }
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            var request = URLRequest(url: githubReleasesURL)
            request.setValue("Agent-Channels/\(currentVersion)", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw AppFailure("GitHub Release 查询失败") }
            let releases = try JSONDecoder().decode([GitHubRelease].self, from: data)
            guard let current = ReleaseVersion(currentVersion) else { throw AppFailure("当前版本号无效") }
            let available = releases.filter { !$0.draft && $0.prerelease && $0.version.map { current < $0 } == true }
                .sorted { ($0.version ?? current) > ($1.version ?? current) }
            guard let release = available.first, let version = release.version else {
                updateStatus = "已是最新 Beta"
                if interactive { showNotice(title: "Agent Channels", message: "当前已是最新 Beta。") }
                return
            }
            guard let dmg = release.arm64DMG else {
                updateStatus = "\(version) 缺少 arm64 更新包"
                if interactive { NSWorkspace.shared.open(release.htmlURL) }
                return
            }
            if interactive {
                let alert = NSAlert()
                alert.messageText = "发现 Agent Channels Beta 更新"
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
            if interactive { showNotice(title: "更新已下载", message: "重启 Agent Channels 后将自动安装 \(version)。") }
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
        state = AppStateV2()
        selectedChannelID = nil
        messages = []
        members = []
        invitations = []
        listenerStatus = [:]
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
        showNotice(title: "Agent Channels", message: error.localizedDescription)
    }

    func exportClientLog() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        panel.nameFieldStringValue = "Agent-Channels-client-\(formatter.string(from: Date())).log"
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

private struct V2MenuPanel: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    private var statusColor: Color {
        if !model.lastError.isEmpty { return .red }
        if model.enabledSubscriptionCount == 0 { return .secondary }
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
                    Text("Agent Channels").font(.headline)
                    HStack(spacing: 5) {
                        Circle().fill(statusColor).frame(width: 7, height: 7)
                        Text("\(model.state.channels.count) 个频道 · \(model.runningListenerCount)/\(model.enabledSubscriptionCount) 个监听")
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
                Label("打开 Agent Channels", systemImage: "arrow.up.forward.app")
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

private enum MainDestination: Hashable {
    case channel(UUID)
    case settings
}

private struct MainWindowView: View {
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
        NavigationSplitView {
            List(selection: destination) {
                Section("频道") {
                    ForEach(model.state.channels) { channel in
                        HStack {
                            Circle()
                                .fill(model.channelStatus[channel.id] == "已连接" ? .green : .secondary.opacity(0.4))
                                .frame(width: 7, height: 7)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(channel.displayName).lineLimit(1)
                                Text(channel.displayName == channel.channel
                                     ? (channel.role == "owner" ? "所有者" : "成员")
                                     : "\(channel.channel) · \(channel.role == "owner" ? "所有者" : "成员")")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
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
                }
                .buttonStyle(.plain)
                .foregroundStyle(showingSettings ? .white : .primary)
                .background(showingSettings ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 6))
                .padding(8)
            }
            .navigationTitle("Agent Channels")
            .toolbar {
                Button {
                    showingSettings = false
                    model.showAddChannel = true
                } label: {
                    Label("添加频道", systemImage: "plus")
                }
            }
        } detail: {
            if showingSettings {
                AgentChannelsSettingsView(model: model)
            } else if let channel = model.selectedChannel {
                ChannelDetailView(model: model, channel: channel)
            } else {
                EmptyStateView(
                    title: "还没有频道",
                    systemImage: "bubble.left.and.bubble.right",
                    detail: "创建频道，或粘贴 ac2: 邀请口令加入。"
                ) {
                    Button("添加频道") { model.showAddChannel = true }
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
    }
}

private enum AddChannelMode: Hashable {
    case create
    case join
}

private struct AddChannelSheet: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var mode = AddChannelMode.create

    private var actionDisabled: Bool {
        model.busy
            || model.state.defaultCallsign.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || (mode == .create && model.draftChannelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            || (mode == .join && model.invitationInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
                Text("添加频道").font(.title2.bold())
                Text("创建一个新频道，或使用邀请口令加入已有频道。")
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
                        SecureField("ac2: ...", text: $model.invitationInput)
                            .onSubmit(submit)
                        Button {
                            if let value = NSPasteboard.general.string(forType: .string) {
                                model.invitationInput = value
                            }
                        } label: {
                            Label("粘贴", systemImage: "doc.on.clipboard")
                        }
                    }
                    Text("口令已包含频道信息；加入后你会获得独立的成员凭证。")
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
                Button(mode == .create ? "创建频道" : "加入频道", action: submit)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(actionDisabled)
            }
        }
        .padding(24)
        .frame(width: 460)
    }
}

private struct CreateInvitationSheet: View {
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
            Text("范围：1–100 人、1–720 小时。口令只会显示并复制一次。")
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

private enum ChannelDetailTab: Hashable {
    case messages
    case members
    case subscriptions
}

private struct ChannelDetailView: View {
    @ObservedObject var model: AppModel
    let channel: ChannelProfile
    @State private var selectedTab = ChannelDetailTab.messages
    @State private var showCreateInvitation = false

    @ViewBuilder
    private func tabButton(_ title: String, tab: ChannelDetailTab) -> some View {
        Button {
            selectedTab = tab
        } label: {
            Text(title)
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
                    Text(channel.displayName)
                        .font(.title2.bold())
                        .onTapGesture(count: 2) { model.renameSelectedChannel() }
                        .help("双击修改频道名称")
                    Text("频道 ID：\(channel.channel) · 我的昵称：\(model.state.defaultCallsign) · \(channel.role == "owner" ? "所有者" : "成员") · \(model.channelStatus[channel.id] ?? "未连接")")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if channel.role == "owner" {
                    Button("创建邀请…") { showCreateInvitation = true }
                }
                if model.channelStatus[channel.id]?.contains("权限已撤销") == true {
                    Button("重新连接") { model.reconnectChannel(channel.id) }
                }
                Menu {
                    Button("修改频道昵称…") { model.renameSelectedChannel() }
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
                    Button("移除本机频道", role: .destructive) { model.removeSelectedChannel() }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            HStack(spacing: 24) {
                tabButton("消息", tab: .messages)
                tabButton("成员", tab: .members)
                tabButton("转发到会话", tab: .subscriptions)
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
    }
}

private struct ChannelMessagesView: View {
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
                    detail: "频道消息会先显示在这里，再转发到已连接的 AI 会话。"
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
                TextField("向频道发送消息", text: $model.composerText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await model.sendComposerMessage() } }
                Button("发送") { Task { await model.sendComposerMessage() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.busy || model.composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(12)
            .background(.bar)
        }
        .task(id: model.selectedChannelID) { await model.refreshHistory() }
    }
}

private struct MessageRow: View {
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
                Text(String(message.from.prefix(1)).uppercased())
                    .font(.caption.bold())
                    .frame(width: 30, height: 30)
                    .foregroundStyle(message.direction == .outbound ? Color.blue : Color.secondary)
                    .background(
                        message.direction == .outbound ? Color.blue.opacity(0.12) : Color.secondary.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 8)
                    )
            }
            VStack(alignment: .leading, spacing: 4) {
                if !continuation {
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 8) {
                            Text(message.from).font(.subheadline.bold())
                            Text(DateFormatter.delivery.string(from: Date(timeIntervalSince1970: message.at / 1000)))
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        if let label = message.source?.label, !label.isEmpty {
                            Text(label).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
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

private struct ChannelMembersView: View {
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
            Text("撤销邀请只阻止后续加入；移除或封禁成员会撤销其当前成员凭证。没有账号体系时，同一自然人仍可持新邀请加入。")
                .font(.caption).foregroundStyle(.secondary)
                .padding(12)
            Divider()
            List {
                if channel.role == "owner" {
                    Section("邀请") {
                        if model.invitations.isEmpty {
                            Text("暂无邀请；从窗口右上角创建。").foregroundStyle(.secondary)
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

private struct ChannelSubscriptionsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    TextField("搜索标题，或输入会话 ID / 链接", text: $model.draftTask)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { Task { await model.searchHostConversations() } }
                        .onChange(of: model.draftTask) { _ in
                            model.conversationSearchResults = []
                            model.conversationSearchStatus = ""
                        }
                        .overlay(alignment: .topLeading) {
                            if !model.conversationSearchResults.isEmpty {
                                ScrollView {
                                    LazyVStack(spacing: 0) {
                                        ForEach(model.conversationSearchResults) { conversation in
                                            Button {
                                                Task { await model.bindHostConversation(conversation) }
                                            } label: {
                                                VStack(alignment: .leading, spacing: 2) {
                                                    Text(conversation.title).lineLimit(1)
                                                    Text("\(hostDisplayName(conversation.provider)) · \(conversation.conversationID)")
                                                        .font(.caption2).foregroundStyle(.secondary)
                                                }
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                                .padding(.horizontal, 10)
                                                .padding(.vertical, 7)
                                                .contentShape(Rectangle())
                                            }
                                            .buttonStyle(.plain)
                                            .disabled(model.busy)
                                            if conversation.id != model.conversationSearchResults.last?.id { Divider() }
                                        }
                                    }
                                }
                                .frame(height: min(CGFloat(model.conversationSearchResults.count) * 48, 210))
                                .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
                                .overlay { RoundedRectangle(cornerRadius: 7).stroke(.separator) }
                                .shadow(color: .black.opacity(0.16), radius: 10, y: 4)
                                .offset(y: 30)
                            } else if !model.conversationSearchStatus.isEmpty {
                                Text(model.conversationSearchStatus)
                                    .font(.caption).foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(10)
                                    .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
                                    .overlay { RoundedRectangle(cornerRadius: 7).stroke(.separator) }
                                    .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
                                    .offset(y: 30)
                            }
                        }
                    Button("搜索") { Task { await model.searchHostConversations() } }
                        .disabled(model.busy || model.draftTask.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("按 ID 绑定") { Task { await model.addTaskSubscription() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.busy || model.draftTask.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .zIndex(1)
                Text("当前支持 ChatGPT Codex。可按本地会话标题搜索，也可直接粘贴 ID；绑定时会再次验证会话是否可投递。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(16)
            .zIndex(1)
            Divider()
            if model.selectedSubscriptions.isEmpty {
                EmptyStateView(title: "尚未连接会话", systemImage: "link.badge.plus", detail: "搜索或输入 AI 会话，让该会话接收本频道消息。") { EmptyView() }
                    .frame(maxHeight: .infinity)
            } else {
                List(model.selectedSubscriptions) { subscription in
                    SubscriptionCard(model: model, subscriptionID: subscription.id)
                        .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
                }
                .listStyle(.plain)
            }
        }
    }
}

private struct SubscriptionCard: View {
    @ObservedObject var model: AppModel
    let subscriptionID: UUID
    @State private var templateDraft = ""
    @State private var sentMessageTemplateDraft = ""
    @State private var isExpanded = false
    @State private var isPreviewingTemplate = false
    @State private var isEditingSentMessageTemplate = false

    private var subscription: ChannelSubscription? {
        model.state.subscriptions.first { $0.id == subscriptionID }
    }

    private func statusColor(_ status: String) -> Color {
        if status.contains("已连接") || status.contains("正在接收") { return .green }
        if status.contains("异常") || status.contains("不可用") || status.contains("失败") { return .red }
        if status.contains("暂停") { return .secondary }
        return .orange
    }

    private var templatePreview: AttributedString {
        let draft = isEditingSentMessageTemplate ? sentMessageTemplateDraft : templateDraft
        return (try? AttributedString(
            markdown: draft,
            options: .init(interpretedSyntax: .full)
        )) ?? AttributedString(draft)
    }

    private var activeTemplateDraft: Binding<String> {
        Binding(
            get: { isEditingSentMessageTemplate ? sentMessageTemplateDraft : templateDraft },
            set: {
                if isEditingSentMessageTemplate { sentMessageTemplateDraft = $0 }
                else { templateDraft = $0 }
            }
        )
    }

    var body: some View {
        if let subscription {
            let status = model.listenerStatus[subscription.id] ?? (subscription.enabled ? "准备接收" : "已暂停")
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    Button {
                        isExpanded.toggle()
                    } label: {
                        HStack(spacing: 10) {
                            Circle().fill(statusColor(status)).frame(width: 8, height: 8)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(model.taskLabel(subscription.taskID)).font(.headline)
                                Text(status).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if subscription.uncertainMessageID != nil {
                                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Button {
                        model.openTask(subscription.taskID)
                    } label: {
                        Label("打开会话", systemImage: "arrow.up.forward.app")
                    }
                    .buttonStyle(.borderless)
                    Button {
                        isExpanded.toggle()
                    } label: {
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                if isExpanded {
                    Divider().padding(.vertical, 12)
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 24) {
                            Toggle("接收消息", isOn: Binding(
                                get: { subscription.enabled },
                                set: { model.setSubscriptionEnabled(subscription.id, enabled: $0) }
                            ))
                            .toggleStyle(.switch)
                            .fixedSize()
                            Toggle("默认回复频道", isOn: Binding(
                                get: { subscription.defaultSend },
                                set: { model.setSubscriptionDefault(subscription.id, enabled: $0) }
                            ))
                            .toggleStyle(.switch)
                            .fixedSize()
                        }
                        if let messageID = subscription.uncertainMessageID {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("消息 #\(messageID) 的会话转发结果未知").font(.subheadline.bold())
                                if let detail = subscription.uncertainDetail { Text(detail).font(.caption).foregroundStyle(.secondary) }
                                HStack {
                                    Button("目标会话未出现，重试") {
                                        model.resolveUncertainDelivery(subscription.id, retry: true)
                                    }
                                    Button("目标会话已出现，跳过") {
                                        model.resolveUncertainDelivery(subscription.id, retry: false)
                                    }
                                }
                            }
                            .padding(8)
                            .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            Text("同成员消息").font(.caption.bold())
                            Picker("", selection: Binding(
                                get: { subscription.selfMessagePolicy },
                                set: { model.setSubscriptionPolicy(subscription.id, policy: $0) }
                            )) {
                                ForEach(SelfMessagePolicy.allCases) { policy in Text(policy.title).tag(policy) }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .fixedSize()
                            Text("当前会话自己发送的消息始终不会转发回来，以避免循环。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        HStack {
                            Text("会话消息模板").font(.caption.bold())
                            Picker("消息方向", selection: $isEditingSentMessageTemplate) {
                                Text("收到频道消息").tag(false)
                                Text("发送成功").tag(true)
                            }
                            .labelsHidden()
                            .pickerStyle(.segmented)
                            .fixedSize()
                            Spacer()
                            Picker("模板显示模式", selection: $isPreviewingTemplate) {
                                Text("编辑").tag(false)
                                Text("预览").tag(true)
                            }
                            .labelsHidden()
                            .pickerStyle(.segmented)
                            .fixedSize()
                        }
                        Group {
                            if isPreviewingTemplate {
                                ScrollView {
                                    Text(templatePreview)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(8)
                                        .textSelection(.enabled)
                                }
                            } else {
                                TextEditor(text: activeTemplateDraft)
                                    .font(.system(.body, design: .monospaced))
                            }
                        }
                        .frame(height: 130)
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(.quaternary))
                        Text(isEditingSentMessageTemplate
                            ? "发送成功后作为频道标志返回当前会话，不改写频道正文。"
                            : "收到频道消息时，整段 Markdown 作为会话输入。")
                            .font(.caption2).foregroundStyle(.secondary)
                        Text("变量：{channel_name} {sender_name} {message_source} {message_text} {message_id}")
                            .font(.caption2).foregroundStyle(.secondary)
                        HStack {
                            Button("停止转发到此会话", role: .destructive) { model.removeSubscription(subscription.id) }
                            Spacer()
                            Button("恢复默认") {
                                if isEditingSentMessageTemplate { sentMessageTemplateDraft = defaultSentMessageTemplate }
                                else { templateDraft = defaultMessageTemplate }
                            }
                            Button("保存模板") {
                                if isEditingSentMessageTemplate {
                                    model.setSubscriptionSentMessageTemplate(subscription.id, template: sentMessageTemplateDraft)
                                } else {
                                    model.setSubscriptionTemplate(subscription.id, template: templateDraft)
                                }
                            }
                                .buttonStyle(.borderedProminent)
                        }
                    }
                    .frame(maxWidth: 760, alignment: .leading)
                    .padding(.leading, 18)
                    .padding(.bottom, 4)
                }
            }
            .onAppear {
                templateDraft = subscription.template
                sentMessageTemplateDraft = subscription.sentMessageTemplate ?? defaultSentMessageTemplate
            }
        }
    }
}

private struct EmptyStateView<Actions: View>: View {
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

private struct AgentChannelsSettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("设置").font(.title2.bold())
                Spacer()
            }
            .padding()
            Divider()
            Form {
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
                    LabeledContent("ChatGPT Codex", value: model.codexIntegrationStatus)
                    if model.codexIntegrationNeedsRestart {
                        VStack(alignment: .leading, spacing: 4) {
                            Label("需要完全重启 ChatGPT", systemImage: "arrow.clockwise.circle.fill")
                                .font(.subheadline.bold())
                                .foregroundStyle(.orange)
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
                        Button("移除 Codex 集成", role: .destructive) { model.removeCodexIntegration() }
                    }
                    Text("MCP 提供当前会话的频道动作，Skill 负责识别外部消息和协作规则；频道凭证仍只保存在 App Keychain。配置后需完全重启 ChatGPT。")
                        .font(.caption).foregroundStyle(.secondary)
                }
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
            .formStyle(.grouped)
            .padding()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#if !SELF_TEST
@MainActor
private final class AgentChannelsAppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        AppModel.shared.shutdown()
    }
}

@main
private struct AgentChannelsV2App: App {
    @NSApplicationDelegateAdaptor(AgentChannelsAppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        Window("Agent Channels", id: "main") {
            MainWindowView(model: model)
                .frame(minWidth: 900, minHeight: 620)
        }
        .defaultSize(width: 1100, height: 760)

        MenuBarExtra {
            V2MenuPanel(model: model)
        } label: {
            BrandIcon(fallback: model.menuIcon, size: 18)
                .accessibilityLabel("Agent Channels")
        }
        .menuBarExtraStyle(.window)
    }
}
#else
@main
private struct AgentChannelsV2SelfTest {
    static func main() throws {
        let invitation = ChannelInvitation(
            version: 2,
            origin: "https://example.test",
            channel: "quiet-owl-0001",
            inviteToken: "invite-secret"
        )
        let encodedInvitation = try InvitationCodec.encode(invitation)
        let decodedInvitation = try InvitationCodec.decode(encodedInvitation)
        precondition(decodedInvitation == invitation)
        let managedInvite = try JSONDecoder().decode(ChannelInvite.self, from: Data(#"{"invite_id":"invite-1","label":"Backend","max_uses":3,"use_count":1,"created_at":1,"expires_at":2,"status":"active"}"#.utf8))
        precondition(managedInvite.label == "Backend" && managedInvite.maxUses == 3 && managedInvite.useCount == 1)
        let joinedChannel = ChannelProfile(
            id: UUID(),
            origin: invitation.origin,
            channel: invitation.channel,
            displayName: invitation.channel,
            callsign: "member-test",
            memberID: "member-test",
            role: "member",
            credentialAccount: "test",
            lastViewedMessageID: nil
        )
        precondition(alreadyJoinedChannel([joinedChannel], invitation: invitation))
        precondition(!alreadyJoinedChannel([], invitation: invitation))
        let reconciledChannel = try reconciledChannelProfile(joinedChannel, authenticatedMemberID: "server-member")
        precondition(reconciledChannel.memberID == "server-member" && reconciledChannel.callsign == joinedChannel.callsign)
        do {
            _ = try reconciledChannelProfile(joinedChannel, authenticatedMemberID: "")
            preconditionFailure("empty authenticated member id was accepted")
        } catch {}
        let block = CodexConfigEditor.managedBlock(sidecar: "/Applications/Agent Channels.app/Contents/MacOS/rogerthat-sidecar", binding: "/tmp/state-v2.json")
        let installed = try CodexConfigEditor.installing(block: block, into: "model = \"gpt-5\"\n")
        precondition(installed.contains(managedConfigStart))
        let removed = try CodexConfigEditor.removingManagedBlock(from: installed)
        precondition(removed == "model = \"gpt-5\"\n")
        let request = try LocalSendRequest.decode(Data(#"{"version":2,"operation":"send","source":{"provider":"codex","conversationId":"01900000-0000-7000-8000-000000000001"},"message":"hello"}"#.utf8))
        precondition(request.message == "hello")
        let inspectRequest = try LocalSendRequest.decode(Data(#"{"version":2,"operation":"inspect_message_source","source":{"provider":"codex","conversationId":"01900000-0000-7000-8000-000000000001"}}"#.utf8))
        precondition(inspectRequest.operation == "inspect_message_source")
        let readyRequest = try LocalSendRequest.decode(Data(#"{"version":2,"operation":"mcp_ready","client_version":"0.3.0-beta.16"}"#.utf8))
        precondition(readyRequest.clientVersion == "0.3.0-beta.16" && readyRequest.source == nil)
        precondition(requiresCodexRestart(configured: true, appVersion: "beta.16", loadedMCPVersion: nil))
        precondition(requiresCodexRestart(configured: true, appVersion: "beta.16", loadedMCPVersion: "beta.15"))
        precondition(!requiresCodexRestart(configured: true, appVersion: "beta.16", loadedMCPVersion: "beta.16"))
        precondition(!requiresCodexRestart(configured: false, appVersion: "beta.16", loadedMCPVersion: nil))
        let sentTemplate = try validateMessageTemplate(
            "> **{channel_name}** · {message_source} · #{message_id}\n>\n> {message_text}",
            defaultTemplate: defaultSentMessageTemplate
        )
        let sentConfirmation = renderMessageTemplate(
            sentTemplate,
            channelName: "API `联调`",
            senderName: "frontend",
            messageSource: "ChatGPT Codex · 01900000…",
            messageText: "第一行\n{channel_name}",
            messageID: "42"
        )
        precondition(sentConfirmation == "> **API ˋ联调ˋ** · ChatGPT Codex · 01900000… · #42\n>\n> 第一行\n> {channel_name}")
        let resetSentTemplate = try validateMessageTemplate("  ", defaultTemplate: defaultSentMessageTemplate)
        precondition(resetSentTemplate == defaultSentMessageTemplate)
        do {
            _ = try validateMessageTemplate("{unknown}", defaultTemplate: defaultSentMessageTemplate)
            preconditionFailure("unknown sent-message template variable was accepted")
        } catch {}
        do {
            _ = try LocalSendRequest.decode(Data(#"{"version":2,"operation":"send","source":{"provider":"codex","conversationId":"bad"},"message":"hello"}"#.utf8))
            preconditionFailure("invalid source was accepted")
        } catch {}
        do {
            _ = try LocalSendRequest.decode(Data(#"{"version":2,"operation":"mcp_ready","client_version":""}"#.utf8))
            preconditionFailure("empty MCP version was accepted")
        } catch {}
        precondition(ReleaseVersion("0.3.0-beta.7")! < ReleaseVersion("0.3.0-beta.8")!)
        let taskA = compactTaskKey("01900000-0000-7000-8000-000000000001")!
        let taskB = compactTaskKey("01900000-0000-7000-8000-000000000002")!
        precondition(taskA.count == 26 && taskB.count == 26 && taskA != taskB)
        precondition(!taskA.contains("019000") && !taskA.contains("000001"))
        precondition(receivedDeliveryDecision(nil).rawValue == "recorded")
        precondition(receivedDeliveryDecision(.received).rawValue == "recorded")
        precondition(receivedDeliveryDecision(.failed).rawValue == "recorded")
        precondition(receivedDeliveryDecision(.delivered).rawValue == "already_processed")
        precondition(receivedDeliveryDecision(.filtered).rawValue == "already_processed")
        precondition(receivedDeliveryDecision(.skipped).rawValue == "already_processed")
        precondition(receivedDeliveryDecision(.attempting).rawValue == "unresolved")
        precondition(receivedDeliveryDecision(.unknown).rawValue == "unresolved")
        precondition(advancedDeliveryCursor(nil, through: 8) == 8)
        precondition(advancedDeliveryCursor(10, through: 8) == 10)
        precondition(advancedDeliveryCursor(10, through: 12) == 12)
        precondition(bridgeRecoveryClearsError(kind: "connection", state: "connected"))
        precondition(bridgeRecoveryClearsError(kind: "delivery", state: "delivered"))
        precondition(!bridgeRecoveryClearsError(kind: "delivery", state: "connected"))
        precondition(!bridgeRecoveryClearsError(kind: "delivery_outcome_unknown", state: "connected"))
        precondition(!bridgeErrorShouldReplace(current: "delivery", incoming: "connection"))
        precondition(bridgeErrorShouldReplace(current: "connection", incoming: "delivery"))
        precondition(isCancellationError(CancellationError()))
        precondition(isCancellationError(URLError(.cancelled)))
        precondition(!isCancellationError(URLError(.timedOut)))

        let subscriptionID = UUID()
        let channelID = UUID()
        let taskID = UUID()
        let confirmed = SubscriptionDeliveryRecord(
            subscriptionID: subscriptionID,
            channelID: channelID,
            messageID: "7",
            state: .received,
            detail: "用户确认目标会话未出现，允许重试",
            updatedAt: 1
        )
        var manuallyStopped = ChannelSubscription(
            id: subscriptionID,
            channelID: channelID,
            taskID: taskID,
            enabled: false,
            template: defaultMessageTemplate,
            selfMessagePolicy: .includeOtherEndpoints,
            defaultSend: true
        )
        recoverSubscriptionDeliveryState(&manuallyStopped, deliveries: [confirmed])
        precondition(!manuallyStopped.enabled)
        var unresolved = manuallyStopped
        unresolved.uncertainMessageID = 7
        recoverSubscriptionDeliveryState(&unresolved, deliveries: [confirmed])
        precondition(unresolved.enabled && unresolved.uncertainMessageID == nil)
        let attempting = SubscriptionDeliveryRecord(
            subscriptionID: subscriptionID,
            channelID: channelID,
            messageID: "8",
            state: .attempting,
            detail: nil,
            updatedAt: 2
        )
        recoverSubscriptionDeliveryState(&unresolved, deliveries: [confirmed, attempting])
        precondition(!unresolved.enabled && unresolved.uncertainMessageID == 8)
        let messageA = ChannelMessageRecord(
            channelID: channelID,
            messageID: "8",
            direction: .inbound,
            from: "peer",
            to: "all",
            text: "hello",
            at: 1,
            state: .received,
            senderMemberID: "member-peer",
            senderEndpointID: "endpoint-peer",
            source: MessageSourceReference(
                provider: "codex",
                conversationID: "01900000-0000-7000-8000-000000000001",
                label: "API review"
            )
        )
        precondition(messageA.source?.provider == "codex")
        precondition(messageA.source?.conversationID == "01900000-0000-7000-8000-000000000001")
        let delivered = SubscriptionDeliveryRecord(
            subscriptionID: subscriptionID,
            channelID: channelID,
            messageID: messageA.messageID,
            state: .delivered,
            detail: nil,
            updatedAt: 3
        )
        let latest = latestDeliveredChannelMessage(
            taskID: taskID,
            subscriptions: [manuallyStopped],
            deliveries: { $0 == subscriptionID ? [attempting, delivered] : [] },
            messages: { $0 == channelID ? [messageA] : [] }
        )
        precondition(latest?.messageID == messageA.messageID)
        precondition(latestDeliveredChannelMessage(
            taskID: UUID(),
            subscriptions: [manuallyStopped],
            deliveries: { _ in [delivered] },
            messages: { _ in [messageA] }
        ) == nil)
        var messageB = messageA
        messageB.direction = .outbound
        precondition(messageA.id == messageB.id)
        var groupedMessage = messageA
        groupedMessage.messageID = "9"
        groupedMessage.at = messageA.at + 60_000
        precondition(continuesMessageGroup(previous: messageA, current: groupedMessage))
        groupedMessage.at = messageA.at + 6 * 60 * 1000
        precondition(!continuesMessageGroup(previous: messageA, current: groupedMessage))
        precondition(!continuesMessageGroup(previous: messageB, current: messageA))
        precondition(!shouldShowPendingSendStatus(startedAt: 1_000, now: 1_999))
        precondition(shouldShowPendingSendStatus(startedAt: 1_000, now: 2_000))
        precondition(channelDisplayName("  项目讨论  ", original: "quiet-owl-0001") == "项目讨论")
        precondition(channelDisplayName("  ", original: "quiet-owl-0001") == "quiet-owl-0001")

        let socketDirectory = URL(fileURLWithPath: "/private/tmp/ac-v2-\(getpid())", isDirectory: true)
        try FileManager.default.createDirectory(at: socketDirectory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: socketDirectory) }
        let logDirectory = socketDirectory.appendingPathComponent("logs", isDirectory: true)
        let exportedLog = socketDirectory.appendingPathComponent("exported.log")
        ClientLog.record("error", "self_test", detail: "line one\nline two", directory: logDirectory)
        try ClientLog.export(to: exportedLog, directory: logDirectory)
        let exportedLogText = try String(contentsOf: exportedLog, encoding: .utf8)
        precondition(exportedLogText.contains("ERROR\tself_test\tline one line two"))
        let configURL = socketDirectory.appendingPathComponent("config.toml")
        let missingConfig = try CodexConfigEditor.reading(configURL)
        precondition(missingConfig == nil)
        try Data([0xFF]).write(to: configURL)
        do {
            _ = try CodexConfigEditor.reading(configURL)
            preconditionFailure("invalid UTF-8 Codex config was treated as empty")
        } catch {}
        try FileManager.default.removeItem(at: configURL)
        let skillSource = socketDirectory.appendingPathComponent("app-skill", isDirectory: true)
        let skillDestination = socketDirectory.appendingPathComponent("codex-skills/agent-channels", isDirectory: true)
        try FileManager.default.createDirectory(at: skillSource, withIntermediateDirectories: true)
        try "---\nname: agent-channels\n---\n".write(
            to: skillSource.appendingPathComponent("SKILL.md"),
            atomically: true,
            encoding: .utf8
        )
        let integrationBlock = CodexConfigEditor.managedBlock(sidecar: "/Applications/Agent Channels.app/sidecar", binding: "/tmp/state.json")
        try "model = \"gpt-5\"\n".write(to: configURL, atomically: true, encoding: .utf8)
        try CodexIntegrationInstaller.install(
            configURL: configURL,
            block: integrationBlock,
            skillSource: skillSource,
            skillDestination: skillDestination
        )
        precondition(AgentChannelsSkillInstaller.isInstalled(source: skillSource, destination: skillDestination))
        let installedConfig = try CodexConfigEditor.reading(configURL)
        precondition(installedConfig?.contains(managedConfigStart) == true)
        try CodexIntegrationInstaller.install(
            configURL: configURL,
            block: integrationBlock,
            skillSource: skillSource,
            skillDestination: skillDestination
        )
        try CodexIntegrationInstaller.remove(
            configURL: configURL,
            skillSource: skillSource,
            skillDestination: skillDestination
        )
        let removedConfig = try CodexConfigEditor.reading(configURL)
        precondition(removedConfig == "model = \"gpt-5\"\n")
        precondition(!AgentChannelsSkillInstaller.isManagedLink(source: skillSource, destination: skillDestination))
        let linkedConfig = socketDirectory.appendingPathComponent("linked-config.toml")
        try "model = \"gpt-5\"\n".write(to: linkedConfig, atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: configURL)
        try FileManager.default.createSymbolicLink(at: configURL, withDestinationURL: linkedConfig)
        try CodexIntegrationInstaller.install(
            configURL: configURL,
            block: integrationBlock,
            skillSource: skillSource,
            skillDestination: skillDestination
        )
        try CodexIntegrationInstaller.remove(
            configURL: configURL,
            skillSource: skillSource,
            skillDestination: skillDestination
        )
        _ = try FileManager.default.destinationOfSymbolicLink(atPath: configURL.path)
        let linkedConfigAfterRemoval = try CodexConfigEditor.reading(configURL)
        precondition(linkedConfigAfterRemoval == "model = \"gpt-5\"\n")
        try FileManager.default.createDirectory(at: skillDestination, withIntermediateDirectories: true)
        do {
            try CodexIntegrationInstaller.install(
                configURL: configURL,
                block: integrationBlock,
                skillSource: skillSource,
                skillDestination: skillDestination
            )
            preconditionFailure("existing unmanaged skill was overwritten")
        } catch {}
        let configAfterRejectedInstall = try CodexConfigEditor.reading(configURL)
        precondition(configAfterRejectedInstall == "model = \"gpt-5\"\n")
        do {
            try CodexIntegrationInstaller.remove(
                configURL: configURL,
                skillSource: skillSource,
                skillDestination: skillDestination
            )
            preconditionFailure("MCP config changed before unmanaged skill validation")
        } catch {}
        let configAfterRejectedRemoval = try CodexConfigEditor.reading(configURL)
        precondition(configAfterRejectedRemoval == "model = \"gpt-5\"\n")
        try FileManager.default.removeItem(at: skillDestination)
        let otherSkill = socketDirectory.appendingPathComponent("other-skill", isDirectory: true)
        try FileManager.default.createDirectory(at: otherSkill, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: skillDestination, withDestinationURL: otherSkill)
        do {
            try CodexIntegrationInstaller.install(
                configURL: configURL,
                block: integrationBlock,
                skillSource: skillSource,
                skillDestination: skillDestination
            )
            preconditionFailure("foreign skill link was overwritten")
        } catch {}
        do {
            try CodexIntegrationInstaller.remove(
                configURL: configURL,
                skillSource: skillSource,
                skillDestination: skillDestination
            )
            preconditionFailure("foreign skill link was removed")
        } catch {}
        let configAfterForeignLink = try CodexConfigEditor.reading(configURL)
        precondition(configAfterForeignLink == "model = \"gpt-5\"\n")
        let socketURL = socketDirectory.appendingPathComponent("send.sock")
        let firstServer = LocalSendServer(socketURL: socketURL) { _ in .success(LocalOperationResult(message: "ok")) }
        try firstServer.start()
        let secondServer = LocalSendServer(socketURL: socketURL) { _ in .failure("unused") }
        do {
            try secondServer.start()
            preconditionFailure("second local server replaced a live socket")
        } catch {
            precondition(FileManager.default.fileExists(atPath: socketURL.path))
        }
        firstServer.stop()
        print("macos v2 self-test ok")
    }
}
#endif
