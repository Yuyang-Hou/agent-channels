import AppKit
import CryptoKit
import Darwin
import Foundation
import Security
import ServiceManagement
import SwiftUI

private let defaultOrigin = "https://rogerthat-production-fff6.up.railway.app"
private let keychainService = "com.agentchannels.channel"
private let managedConfigStart = "# >>> Agent Channels managed MCP >>>"
private let managedConfigEnd = "# <<< Agent Channels managed MCP <<<"
private let githubReleasesURL = URL(string: "https://api.github.com/repos/Yuyang-Hou/agent-channels/releases?per_page=100")!
private let localSendProtocolVersion = 2
private let maxChannelMessageLength = 8192
private let maxLocalSendFrameBytes = 64 * 1024
private let defaultMessageTemplate = "收到 {channel_name} 频道中 {sender_name} 的消息。你可以不回复或简单回复。\n内容：{message_text}"

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

struct TaskBinding: Codable, Equatable, Identifiable {
    let id: UUID
    var provider: String
    var conversationID: String
    var label: String
}

struct ChannelSubscription: Codable, Equatable, Identifiable {
    let id: UUID
    var channelID: UUID
    var taskID: UUID
    var enabled: Bool
    var template: String
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

enum CodexConfigEditor {
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

enum AppPaths {
    static let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Agent Channels", isDirectory: true)
    static let state = support.appendingPathComponent("state-v2.json")
    static let legacyBinding = support.appendingPathComponent("binding.json")
    static let sendSocket = support.appendingPathComponent("send.sock")
    static let messages = support.appendingPathComponent("messages", isDirectory: true)
    static let codexDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".codex", isDirectory: true)
    static let codexConfig = codexDirectory.appendingPathComponent("config.toml")

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
    }
}

private struct LocalSource: Codable {
    let provider: String
    let conversationId: String
}

private struct LocalSettingsPatch: Codable {
    let template: String?
    let selfMessagePolicy: SelfMessagePolicy?
    let defaultSend: Bool?

    enum CodingKeys: String, CodingKey {
        case template
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

    enum CodingKeys: String, CodingKey {
        case id, from, to, text, at, state, error
        case senderMemberID = "sender_member_id"
        case senderEndpointID = "sender_endpoint_id"
    }
}

private struct LocalSendRequest: Decodable {
    let version: Int
    let operation: String
    let source: LocalSource
    let channel: String?
    let message: String?
    let settings: LocalSettingsPatch?
    let subscriptionID: String?
    let event: LocalSidecarEvent?

    enum CodingKeys: String, CodingKey {
        case version, operation, source, channel, message, settings, event
        case subscriptionID = "subscription_id"
    }

    static func decode(_ data: Data) throws -> LocalSendRequest {
        let request = try JSONDecoder().decode(LocalSendRequest.self, from: data)
        guard request.version == localSendProtocolVersion else {
            throw AppFailure("本机发送协议版本不兼容")
        }
        guard request.source.provider == "codex",
              UUID(uuidString: request.source.conversationId) != nil else {
            throw AppFailure("当前 Codex task 上下文无效")
        }
        let operations = [
            "list_channels", "send", "subscribe", "unsubscribe", "get_settings", "update_settings",
            "record_received", "record_outcome",
        ]
        guard operations.contains(request.operation) else {
            throw AppFailure("不支持的本机操作")
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
    let selfMessagePolicy: SelfMessagePolicy
    let defaultSend: Bool

    enum CodingKeys: String, CodingKey {
        case channel, template
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
    let message: String?

    init(
        id: String? = nil,
        callsign: String? = nil,
        channel: String? = nil,
        channels: [LocalChannelSummary]? = nil,
        settings: LocalSubscriptionSummary? = nil,
        message: String? = nil
    ) {
        self.id = id
        self.callsign = callsign
        self.channel = channel
        self.channels = channels
        self.settings = settings
        self.message = message
    }

    static func send(id: String, callsign: String, channel: String) -> LocalOperationResult {
        LocalOperationResult(id: id, callsign: callsign, channel: channel)
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
                let count = Darwin.send(client, bytes.baseAddress?.advanced(by: sent), bytes.count - sent, 0)
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
            let callsign = try normalizedCallsign(draftCallsign)
            let url = URL(string: "\(defaultOrigin)/api/channels")!
            let json = try await requestJSON(
                url: url,
                method: "POST",
                body: ["api_version": 2, "retention": "none", "trust_mode": "untrusted"]
            )
            guard let channel = json["channel_id"] as? String,
                  let credential = (json["member_credential"] as? String) ?? (json["join_token"] as? String) else {
                throw AppFailure("服务端未返回频道成员凭证")
            }
            let profileID = UUID()
            let account = "channel:\(profileID.uuidString):credential"
            try KeychainStore.set(credential, service: keychainService, account: account)
            let profile = ChannelProfile(
                id: profileID,
                origin: defaultOrigin,
                channel: channel,
                displayName: channel,
                callsign: callsign,
                memberID: (json["member_id"] as? String) ?? "owner",
                role: (json["role"] as? String) ?? "owner",
                credentialAccount: account,
                lastViewedMessageID: nil
            )
            state.defaultCallsign = callsign
            state.channels.append(profile)
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
            let callsign = try normalizedCallsign(draftCallsign)
            let invitation = try InvitationCodec.decode(invitationInput)
            guard let encoded = invitation.channel.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
                  let url = URL(string: "\(invitation.origin)/api/channels/\(encoded)/invites/redeem") else {
                throw AppFailure("邀请地址无效")
            }
            let json = try await requestJSON(
                url: url,
                method: "POST",
                body: ["invite_token": invitation.inviteToken, "name": callsign]
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
                displayName: invitation.channel,
                callsign: callsign,
                memberID: memberID,
                role: (json["role"] as? String) ?? "member",
                credentialAccount: account,
                lastViewedMessageID: nil
            )
            state.defaultCallsign = callsign
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

    func copyInvitation() async {
        guard !busy, let profile = selectedChannel else { return }
        busy = true
        defer { busy = false }
        do {
            let json = try await authorizedJSON(profile, suffix: "invites", method: "POST", body: [:])
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
            showNotice(title: "邀请已复制", message: "对方粘贴 ac2: 邀请口令即可加入；口令不会包含你的成员凭证。")
        } catch {
            fail(error)
        }
    }

    func removeSelectedChannel() {
        guard let profile = selectedChannel else { return }
        let alert = NSAlert()
        alert.messageText = "从本机移除 \(profile.displayName)？"
        alert.informativeText = "将停止该频道全部 task 监听并删除本机成员凭证与消息历史。"
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
        guard let profile = selectedChannel else { return }
        let text = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let pending = ChannelMessageRecord(
            channelID: profile.id,
            messageID: "local-\(UUID().uuidString.lowercased())",
            direction: .outbound,
            from: endpointCallsign(profile, kind: "app"),
            to: "all",
            text: text,
            at: Date().timeIntervalSince1970 * 1000,
            state: .pending
        )
        upsertMessage(pending, persist: false)
        busy = true
        defer { busy = false }
        do {
            let result = try await sendChannelMessage(text, profile: profile, endpoint: endpointCallsign(profile, kind: "app"))
            composerText = ""
            messages.removeAll { $0.id == pending.id }
            upsertMessage(ChannelMessageRecord(
                channelID: profile.id,
                messageID: result.id,
                direction: .outbound,
                from: result.callsign,
                to: "all",
                text: text,
                at: Date().timeIntervalSince1970 * 1000,
                state: .accepted,
                senderMemberID: result.memberID,
                senderEndpointID: result.endpointID
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
        endpoint: String
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
                body: ["callsign": endpoint]
            )
        } catch {
            throw ChannelSendFailure.definitive("频道加入失败：\(error.localizedDescription)")
        }
        guard let session = join["session_id"] as? String,
              let memberID = join["member_id"] as? String,
              let endpointID = join["endpoint_id"] as? String else {
            throw ChannelSendFailure.definitive("频道加入响应缺少 session/member/endpoint")
        }
        do {
            let json = try await requestJSON(
                url: base.appendingPathComponent("send"),
                method: "POST",
                bearer: credential,
                headers: ["X-Session-Id": session],
                body: ["to": "all", "message": message]
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

    private func normalizedCallsign(_ raw: String) throws -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard value.range(of: #"^[a-z0-9][a-z0-9_-]{0,31}$"#, options: .regularExpression) != nil,
              value != "all" else {
            throw AppFailure("Agent 名称须为 1–32 位字母、数字、_ 或 -，且不能是 all")
        }
        return value
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
        return ChannelMessageRecord(
            channelID: channelID,
            messageID: id,
            direction: .inbound,
            from: (json["from"] as? String) ?? "unknown",
            to: (json["to"] as? String) ?? "all",
            text: (json["text"] as? String) ?? "",
            at: at,
            state: state,
            senderMemberID: json["sender_member_id"] as? String,
            senderEndpointID: json["sender_endpoint_id"] as? String
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
    @Published var listenerStatus: [UUID: String] = [:]
    @Published var channelStatus: [UUID: String] = [:]
    @Published var lastError = ""
    @Published var busy = false
    @Published var launchAtLogin = false
    @Published var sendStatus = "未启用"
    @Published var updateStatus = "未检查"
    @Published var draftCallsign = ""
    @Published var invitationInput = ""
    @Published var draftTask = ""
    @Published var composerText = ""
    @Published var showAddChannel = false
    @Published var oldBetaDataDetected = FileManager.default.fileExists(atPath: AppPaths.legacyBinding.path)

    private var listeners: [UUID: SubscriptionListener] = [:]
    private var startingListeners: Set<UUID> = []
    private var listenerGenerations: [UUID: Int] = [:]
    private var feedTasks: [UUID: Task<Void, Never>] = [:]
    private var localSendServer: LocalSendServer?

    private init() {
        try? AppPaths.prepare()
        var loaded = Self.loadState()
        Self.recoverDeliveryState(&loaded)
        state = loaded
        selectedChannelID = state.selectedChannelID ?? state.channels.first?.id
        draftCallsign = state.defaultCallsign
        launchAtLogin = SMAppService.mainApp.status == .enabled
        persistState()
        refreshSendStatus()
        refreshSelectedChannel()
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
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            for channel in self.state.channels { self.startChannelFeed(channel.id) }
            for subscription in self.state.subscriptions where subscription.enabled {
                Task { await self.startListener(subscription.id) }
            }
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
        if selectedChannelID != nil {
            Task {
                await refreshHistory()
                await refreshMembers()
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
            case "list_channels":
                let task = taskBinding(for: request.source)
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
            case "send":
                guard let message = request.message else { throw AppFailure("message is required") }
                let (task, subscription, profile) = try outboundRoute(source: request.source, channel: request.channel)
                let endpoint = endpointCallsign(profile, conversationID: task.conversationID, kind: "t")
                do {
                    let receipt = try await sendChannelMessage(message, profile: profile, endpoint: endpoint)
                    upsertMessage(ChannelMessageRecord(
                        channelID: profile.id,
                        messageID: receipt.id,
                        direction: .outbound,
                        from: receipt.callsign,
                        to: "all",
                        text: message,
                        at: Date().timeIntervalSince1970 * 1000,
                        state: .accepted,
                        senderMemberID: receipt.memberID,
                        senderEndpointID: receipt.endpointID
                    ))
                    return .success(.send(id: receipt.id, callsign: receipt.callsign, channel: profile.channel))
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
                let subscription = try await subscribe(source: request.source, profile: profile)
                return .success(LocalOperationResult(
                    channel: profile.channel,
                    settings: subscriptionSummary(subscription, profile: profile),
                    message: "当前 task 已订阅 \(profile.displayName)"
                ))
            case "unsubscribe":
                let profile = try resolveChannel(request.channel)
                let subscription = try requireSubscription(source: request.source, profile: profile)
                stopListener(subscription.id)
                updateSubscription(subscription.id) { $0.enabled = false }
                return .success(LocalOperationResult(channel: profile.channel, message: "当前 task 已停止监听 \(profile.displayName)"))
            case "get_settings":
                let profile = try resolveChannel(request.channel)
                let subscription = try requireSubscription(source: request.source, profile: profile)
                return .success(LocalOperationResult(settings: subscriptionSummary(subscription, profile: profile)))
            case "update_settings":
                let profile = try resolveChannel(request.channel)
                let subscription = try requireSubscription(source: request.source, profile: profile)
                try applySettings(request.settings, to: subscription.id)
                let updated = state.subscriptions.first { $0.id == subscription.id }!
                if updated.enabled { restartListenerIfNeeded(updated.id) }
                return .success(LocalOperationResult(
                    channel: profile.channel,
                    settings: subscriptionSummary(updated, profile: profile),
                    message: "当前 task 的频道设置已更新"
                ))
            case "record_received":
                try recordSidecarEvent(request, expectedState: .received)
                return .success(LocalOperationResult(message: "recorded"))
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

    func addTaskSubscription() async {
        guard let profile = selectedChannel else { return }
        busy = true
        defer { busy = false }
        do {
            let raw = draftTask.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty else { throw AppFailure("请粘贴 codex://threads/...") }
            let result = try await Sidecar.run(["codex-preflight", "--codex-thread", raw])
            guard result.status == 0,
                  let data = result.stdout.data(using: .utf8),
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  json["ok"] as? Bool == true,
                  let threadID = json["thread_id"] as? String,
                  UUID(uuidString: threadID) != nil else {
                let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                throw AppFailure(detail.isEmpty ? "Codex task 检测失败" : detail)
            }
            _ = try await subscribe(
                source: LocalSource(provider: "codex", conversationId: threadID.lowercased()),
                profile: profile
            )
            draftTask = ""
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
            let value = try validatedTemplate(template)
            updateSubscription(id) { $0.template = value }
            restartListenerIfNeeded(id)
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
        guard let task = state.tasks.first(where: { $0.id == taskID }) else { return "未知 task" }
        return task.label.isEmpty ? "\(task.conversationID.prefix(8))…" : task.label
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
            throw AppFailure("当前 task 尚未订阅该频道")
        }
        return subscription
    }

    private func outboundRoute(
        source: LocalSource,
        channel: String?
    ) throws -> (TaskBinding, ChannelSubscription, ChannelProfile) {
        guard let task = taskBinding(for: source) else { throw AppFailure("当前 task 尚未绑定 Agent Channels") }
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
                throw AppFailure("当前 task 未启用该频道订阅")
            }
            subscription = value
        } else {
            let defaults = candidates.filter(\.defaultSend)
            if defaults.count == 1, let value = defaults.first { subscription = value }
            else if defaults.isEmpty, candidates.count == 1, let value = candidates.first { subscription = value }
            else if candidates.isEmpty { throw AppFailure("当前 task 没有可发送的频道订阅") }
            else { throw AppFailure("当前 task 有多个频道，请指定 channel 或设置唯一默认发送频道") }
        }
        guard let profile = state.channels.first(where: { $0.id == subscription.channelID }) else {
            throw AppFailure("订阅对应的频道不存在")
        }
        return (task, subscription, profile)
    }

    @discardableResult
    private func subscribe(source: LocalSource, profile: ChannelProfile) async throws -> ChannelSubscription {
        let task: TaskBinding
        if let existing = taskBinding(for: source) {
            task = existing
        } else {
            task = TaskBinding(
                id: UUID(),
                provider: source.provider,
                conversationID: source.conversationId.lowercased(),
                label: "\(source.conversationId.prefix(8))…"
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
        let template = try patch.template.map(validatedTemplate)
        guard let index = state.subscriptions.firstIndex(where: { $0.id == id }) else {
            throw AppFailure("订阅不存在")
        }
        if let template { state.subscriptions[index].template = template }
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

    private func validatedTemplate(_ raw: String) throws -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { return defaultMessageTemplate }
        guard value.count <= 2_000 else { throw AppFailure("消息模板不能超过 2000 字符") }
        let allowed = Set(["{channel_name}", "{sender_name}", "{message_text}", "{message_id}"])
        let expression = try NSRegularExpression(pattern: #"\{[^{}]+\}"#)
        let range = NSRange(value.startIndex..., in: value)
        for match in expression.matches(in: value, range: range) {
            guard let tokenRange = Range(match.range, in: value), allowed.contains(String(value[tokenRange])) else {
                throw AppFailure("模板只支持 {channel_name}、{sender_name}、{message_text}、{message_id}")
            }
        }
        return value
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
        listenerStatus[id] = "正在检查 ChatGPT…"
        do {
            let preflight = try await Sidecar.run(["codex-preflight", "--codex-thread", task.conversationID])
            guard listenerCanStart(id, generation: generation) else { return }
            guard preflight.status == 0 else {
                let detail = preflight.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                throw AppFailure(detail.isEmpty ? "ChatGPT task 当前不可用" : detail)
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
                body: ["callsign": txEndpoint]
            )
            guard listenerCanStart(id, generation: generation) else { return }
            guard txJoin["member_id"] as? String == profile.memberID,
                  let txEndpointID = txJoin["endpoint_id"] as? String, !txEndpointID.isEmpty else {
                throw AppFailure("服务端未返回可信 task endpoint 身份")
            }
            process.executableURL = Sidecar.executable
            var arguments = [
                "listen-here",
                "--origin", profile.origin,
                "--channel", profile.channel,
                "--identity-key", endpointCallsign(profile, conversationID: task.conversationID, kind: "r"),
                "--codex-thread", task.conversationID,
                "--secrets-stdin",
                "--status-json",
                "--quiet",
                "--message-template", subscription.template,
                "--self-message-policy", subscription.selfMessagePolicy.rawValue,
                "--self-endpoint-id", txEndpointID,
                "--self-member-id", profile.memberID,
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
            lastError = ""
        } catch {
            guard listenerGenerations[id, default: 0] == generation else { return }
            listenerStatus[id] = "不可用：\(error.localizedDescription)"
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
            scheduleListenerRestart(id)
        } else if listenerStatus[id] == nil {
            listenerStatus[id] = "已停止"
        }
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
            switch state {
            case "joined", "connecting": listenerStatus[id] = "正在连接…"
            case "connected": listenerStatus[id] = "已连接"
            case "reconnecting": listenerStatus[id] = "正在重连…"
            case "delivered": listenerStatus[id] = "已投递 #\(event["messageId"] ?? "")"
            case "filtered": listenerStatus[id] = "已过滤自消息"
            case "error":
                let detail = (event["error"] as? String) ?? (event["kind"] as? String) ?? "未知错误"
                listenerStatus[id] = "异常：\(detail)"
                lastError = "订阅异常：\(detail)"
                if (event["status"] as? NSNumber)?.intValue == 401,
                   let channelID = self.state.subscriptions.first(where: { $0.id == id })?.channelID {
                    markChannelAuthorizationLost(channelID, detail: detail)
                }
            case "stopped": listenerStatus[id] = "已停止"
            default: break
            }
        }
    }

    private func recordSidecarEvent(_ request: LocalSendRequest, expectedState: MessageDeliveryState) throws {
        guard expectedState == .received,
              let subscriptionID = request.subscriptionID.flatMap(UUID.init(uuidString:)),
              let subscription = state.subscriptions.first(where: { $0.id == subscriptionID }),
              let task = state.tasks.first(where: { $0.id == subscription.taskID }),
              task.provider == request.source.provider,
              task.conversationID.caseInsensitiveCompare(request.source.conversationId) == .orderedSame,
              let profile = state.channels.first(where: { $0.id == subscription.channelID }),
              profile.channel == request.channel,
              let event = request.event,
              let id = event.id, let from = event.from, let to = event.to,
              let text = event.text, let at = event.at,
              let senderMemberID = event.senderMemberID, !senderMemberID.isEmpty,
              let senderEndpointID = event.senderEndpointID, !senderEndpointID.isEmpty else {
            throw AppFailure("sidecar received event does not match its subscription")
        }
        let record = ChannelMessageRecord(
            channelID: profile.id,
            messageID: String(id),
            direction: senderMemberID == profile.memberID ? .outbound : .inbound,
            from: from,
            to: to,
            text: text,
            at: at,
            state: .received,
            senderMemberID: senderMemberID,
            senderEndpointID: senderEndpointID
        )
        try MessageLedger.append(record)
        upsertMessage(record, persist: false)
        try MessageLedger.appendDelivery(SubscriptionDeliveryRecord(
            subscriptionID: subscriptionID,
            channelID: profile.id,
            messageID: String(id),
            state: .received,
            detail: nil,
            updatedAt: Date().timeIntervalSince1970
        ))
    }

    private func recordSidecarOutcome(_ request: LocalSendRequest) throws {
        guard let subscriptionID = request.subscriptionID.flatMap(UUID.init(uuidString:)),
              let subscriptionIndex = state.subscriptions.firstIndex(where: { $0.id == subscriptionID }),
              let task = state.tasks.first(where: { $0.id == state.subscriptions[subscriptionIndex].taskID }),
              task.provider == request.source.provider,
              task.conversationID.caseInsensitiveCompare(request.source.conversationId) == .orderedSame,
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
            state.subscriptions[subscriptionIndex].lastDeliveredMessageID = id
            state.subscriptions[subscriptionIndex].lastDeliveredAt = Date().timeIntervalSince1970
            state.subscriptions[subscriptionIndex].uncertainMessageID = nil
            state.subscriptions[subscriptionIndex].uncertainDetail = nil
            if outcome == .filtered { listenerStatus[subscriptionID] = "已过滤自消息" }
        } else if outcome == .unknown {
            state.subscriptions[subscriptionIndex].enabled = false
            state.subscriptions[subscriptionIndex].uncertainMessageID = id
            state.subscriptions[subscriptionIndex].uncertainDetail = event.error
            listenerStatus[subscriptionID] = "结果未知，已暂停"
        } else if outcome == .failed, let error = event.error {
            listenerStatus[subscriptionID] = "投递失败：\(error)"
        } else if outcome == .attempting {
            listenerStatus[subscriptionID] = "正在投递 #\(id)"
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
                detail: retry ? "用户确认目标 task 未出现，允许重试" : "用户确认目标 task 已出现，跳过重放",
                updatedAt: Date().timeIntervalSince1970
            ))
            if !retry { state.subscriptions[index].lastDeliveredMessageID = messageID }
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
                    body: ["callsign": endpoint]
                )
                guard let session = join["session_id"] as? String else { throw AppFailure("频道加入响应缺少 session_id") }
                let base = try channelBaseURL(profile)
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
                            handleFeedData(dataLines.joined(separator: "\n"), profile: profile)
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
    func refreshSendStatus() {
        guard let raw = try? String(contentsOf: AppPaths.codexConfig, encoding: .utf8) else {
            sendStatus = "未启用"
            return
        }
        sendStatus = raw.contains(managedConfigStart) && raw.contains(AppPaths.state.path) ? "已配置" : "未启用"
    }

    func enableSending() {
        do {
            guard AppPaths.appIsInstalled else { throw AppFailure("请先把 Agent Channels.app 移到 Applications 后再启用 MCP") }
            persistState()
            try FileManager.default.createDirectory(at: AppPaths.codexDirectory, withIntermediateDirectories: true)
            let existing = (try? String(contentsOf: AppPaths.codexConfig, encoding: .utf8)) ?? ""
            let block = CodexConfigEditor.managedBlock(sidecar: Sidecar.executable.path, binding: AppPaths.state.path)
            let updated = try CodexConfigEditor.installing(block: block, into: existing)
            try updated.write(to: AppPaths.codexConfig, atomically: true, encoding: .utf8)
            refreshSendStatus()
            showNotice(title: "MCP 已启用", message: "请完全退出并重新打开 ChatGPT，让所有 task 加载 Agent Channels 工具。")
        } catch {
            fail(error)
        }
    }

    func removeManagedMCP() {
        do {
            guard let existing = try? String(contentsOf: AppPaths.codexConfig, encoding: .utf8) else {
                sendStatus = "未启用"
                return
            }
            let updated = try CodexConfigEditor.removingManagedBlock(from: existing)
            try updated.write(to: AppPaths.codexConfig, atomically: true, encoding: .utf8)
            refreshSendStatus()
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

    func checkBetaUpdate() async {
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
                showNotice(title: "Agent Channels", message: "当前已是最新 Beta。")
                return
            }
            updateStatus = "可更新到 \(version)"
            let alert = NSAlert()
            alert.messageText = "发现 Agent Channels Beta 更新"
            alert.informativeText = "当前 \(current)，最新 \(version)。"
            alert.addButton(withTitle: release.arm64DMG == nil ? "查看 Release" : "下载 DMG")
            alert.addButton(withTitle: "取消")
            if alert.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.open(release.arm64DMG ?? release.htmlURL)
            }
        } catch {
            updateStatus = "检查失败"
            fail(error)
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
        listenerStatus = [:]
        channelStatus = [:]
        try? FileManager.default.removeItem(at: AppPaths.state)
        removeManagedMCP()
    }

    func quit() {
        for id in Set(listeners.keys).union(startingListeners) { stopListener(id) }
        for task in feedTasks.values { task.cancel() }
        NSApplication.shared.terminate(nil)
    }

    fileprivate func fail(_ error: Error) {
        lastError = error.localizedDescription
        showNotice(title: "Agent Channels", message: error.localizedDescription)
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
    func saveDefaultCallsign() {
        do {
            let callsign = try normalizedCallsign(draftCallsign)
            state.defaultCallsign = callsign
            draftCallsign = callsign
            persistState()
        } catch {
            fail(error)
        }
    }
}

private struct V2MenuPanel: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                BrandIcon(fallback: model.menuIcon, size: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Agent Channels").font(.headline)
                    Text("\(model.state.channels.count) 个频道 · \(model.runningListenerCount)/\(model.enabledSubscriptionCount) 个监听在线")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            if !model.lastError.isEmpty {
                Text(model.lastError).font(.caption).foregroundStyle(.red).lineLimit(3)
            }
            Button("打开 Agent Channels…") {
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "main")
            }
            .buttonStyle(.borderedProminent)
            .frame(maxWidth: .infinity)
            HStack {
                if model.enabledSubscriptionCount > 0 {
                    Button("暂停全部监听") { model.setAllListening(false) }
                } else if !model.state.subscriptions.isEmpty {
                    Button("恢复全部监听") { model.setAllListening(true) }
                }
                Button("设置…") {
                    NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                }
                Spacer()
                Button("退出") { model.quit() }
            }
        }
        .padding(14)
        .frame(width: 350)
    }
}

private struct MainWindowView: View {
    @ObservedObject var model: AppModel
    @AppStorage("legacyBetaNoticeDismissed") private var legacyBetaNoticeDismissed = false

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(
                get: { model.selectedChannelID },
                set: { model.selectChannel($0) }
            )) {
                Section("频道") {
                    ForEach(model.state.channels) { channel in
                        HStack {
                            Circle()
                                .fill(model.channelStatus[channel.id] == "已连接" ? .green : .secondary.opacity(0.4))
                                .frame(width: 7, height: 7)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(channel.displayName).lineLimit(1)
                                Text("\(channel.callsign) · \(channel.role)")
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
                        .tag(channel.id)
                    }
                }
            }
            .navigationTitle("Agent Channels")
            .toolbar {
                Button {
                    model.showAddChannel = true
                } label: {
                    Label("添加频道", systemImage: "plus")
                }
            }
        } detail: {
            if let channel = model.selectedChannel {
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

private struct AddChannelSheet: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("添加频道").font(.title2.bold())
            TextField("你的 Agent 名称，例如 frontend", text: $model.draftCallsign)
                .textFieldStyle(.roundedBorder)
            GroupBox("创建新频道") {
                HStack {
                    Text("创建后可复制一次性邀请口令给其他成员。")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("创建") {
                        let count = model.state.channels.count
                        Task {
                            await model.createChannel()
                            if model.state.channels.count > count { dismiss() }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(.vertical, 4)
            }
            GroupBox("加入已有频道") {
                VStack(alignment: .leading, spacing: 8) {
                    SecureField("粘贴 ac2: 邀请口令", text: $model.invitationInput)
                        .textFieldStyle(.roundedBorder)
                    Text("邀请口令已经包含频道名，无需再次填写。每个成员会获得独立凭证。")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Spacer()
                        Button("加入") {
                            let count = model.state.channels.count
                            Task {
                                await model.joinInvitation()
                                if model.state.channels.count > count { dismiss() }
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.invitationInput.isEmpty)
                    }
                }
                .padding(.vertical, 4)
            }
            HStack {
                Spacer()
                Button("取消") { dismiss() }
            }
        }
        .padding(20)
        .frame(width: 520)
        .disabled(model.busy)
    }
}

private struct ChannelDetailView: View {
    @ObservedObject var model: AppModel
    let channel: ChannelProfile

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(channel.displayName).font(.title2.bold())
                    Text("\(channel.channel) · \(channel.callsign) · \(channel.role)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if channel.role == "owner" {
                    Button("复制邀请") { Task { await model.copyInvitation() } }
                }
                if model.channelStatus[channel.id]?.contains("权限已撤销") == true {
                    Button("重新连接") { model.reconnectChannel(channel.id) }
                }
                Button("刷新") {
                    Task {
                        await model.refreshHistory()
                        await model.refreshMembers()
                    }
                }
                Menu {
                    Button("移除本机频道", role: .destructive) { model.removeSelectedChannel() }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
            .padding()
            Divider()
            TabView {
                ChannelMessagesView(model: model, channel: channel)
                    .tabItem { Label("消息", systemImage: "message") }
                ChannelMembersView(model: model, channel: channel)
                    .tabItem { Label("成员", systemImage: "person.2") }
                ChannelSubscriptionsView(model: model, channel: channel)
                    .tabItem { Label("Task 订阅", systemImage: "link") }
            }
            .padding([.horizontal, .bottom])
        }
    }
}

private struct ChannelMessagesView: View {
    @ObservedObject var model: AppModel
    let channel: ChannelProfile

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text("本机最近消息").font(.headline)
                Spacer()
                Button("清空本机历史", role: .destructive) { model.clearSelectedHistory() }
                    .disabled(model.messages.isEmpty)
            }
            if model.messages.isEmpty {
                EmptyStateView(
                    title: "暂无消息",
                    systemImage: "text.bubble",
                    detail: "频道消息会先写入这里，再投递给已订阅的 task。"
                ) { EmptyView() }
                    .frame(maxHeight: .infinity)
            } else {
                List(model.messages) { message in
                    MessageRow(message: message)
                }
                .listStyle(.inset)
            }
            HStack(alignment: .bottom) {
                TextField("向频道发送消息", text: $model.composerText, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...5)
                Button("发送") { Task { await model.sendComposerMessage() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.busy || model.composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(.top, 8)
    }
}

private struct MessageRow: View {
    let message: ChannelMessageRecord

    private var stateColor: Color {
        switch message.state {
        case .delivered, .accepted: return .green
        case .failed, .unknown: return .red
        case .pending, .attempting: return .orange
        case .filtered, .skipped: return .secondary
        case .received: return .blue
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: message.direction == .outbound ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                .foregroundStyle(message.direction == .outbound ? .blue : .secondary)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(message.from).font(.subheadline.bold())
                    Text(DateFormatter.delivery.string(from: Date(timeIntervalSince1970: message.at / 1000)))
                        .font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    Text(message.state.rawValue).font(.caption2).foregroundStyle(stateColor)
                }
                Text(message.text).textSelection(.enabled)
            }
        }
        .padding(.vertical, 3)
    }
}

private struct ChannelMembersView: View {
    @ObservedObject var model: AppModel
    let channel: ChannelProfile

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("成员").font(.headline).padding(.top, 8)
            Text("0.3 Beta 的封禁只撤销当前成员身份；没有账号体系时，无法阻止同一自然人通过新邀请创建新成员。")
                .font(.caption).foregroundStyle(.secondary)
            List(model.members) { member in
                HStack {
                    Circle().fill(member.online == true ? .green : .secondary.opacity(0.35)).frame(width: 8, height: 8)
                    VStack(alignment: .leading) {
                        Text(member.name.isEmpty ? member.memberID : member.name)
                        Text("\(member.role) · \(member.status) · \(member.memberID.prefix(8))…")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if channel.role == "owner", member.memberID != channel.memberID {
                        if member.status == "banned" {
                            Button("解除封禁") { Task { await model.unbanMember(member) } }
                        } else if member.status == "active" {
                            Button("移除", role: .destructive) { Task { await model.removeMember(member, ban: false) } }
                            Button("封禁", role: .destructive) { Task { await model.removeMember(member, ban: true) } }
                        }
                    }
                }
            }
            .listStyle(.inset)
        }
    }
}

private struct ChannelSubscriptionsView: View {
    @ObservedObject var model: AppModel
    let channel: ChannelProfile

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Task 订阅").font(.headline).padding(.top, 8)
            HStack {
                TextField("codex://threads/...", text: $model.draftTask)
                    .textFieldStyle(.roundedBorder)
                Button("检查并订阅") { Task { await model.addTaskSubscription() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.busy || model.draftTask.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Text("每个 task 可订阅多个频道；默认发送频道每个 task 最多一个。空闲监听不会创建 turn。")
                .font(.caption).foregroundStyle(.secondary)
            if model.selectedSubscriptions.isEmpty {
                EmptyStateView(title: "暂无 Task 订阅", systemImage: "link.badge.plus", detail: "可粘贴上方 task 链接开始监听。") { EmptyView() }
                    .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(model.selectedSubscriptions) { subscription in
                            SubscriptionCard(model: model, subscriptionID: subscription.id)
                        }
                    }
                }
            }
        }
    }
}

private struct SubscriptionCard: View {
    @ObservedObject var model: AppModel
    let subscriptionID: UUID
    @State private var templateDraft = ""

    private var subscription: ChannelSubscription? {
        model.state.subscriptions.first { $0.id == subscriptionID }
    }

    var body: some View {
        if let subscription {
            GroupBox {
                VStack(alignment: .leading, spacing: 9) {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(model.taskLabel(subscription.taskID)).font(.headline)
                            Text(model.listenerStatus[subscription.id] ?? (subscription.enabled ? "等待启动" : "已暂停"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Toggle("监听", isOn: Binding(
                            get: { subscription.enabled },
                            set: { model.setSubscriptionEnabled(subscription.id, enabled: $0) }
                        ))
                        .toggleStyle(.switch)
                        Toggle("默认发送", isOn: Binding(
                            get: { subscription.defaultSend },
                            set: { model.setSubscriptionDefault(subscription.id, enabled: $0) }
                        ))
                        .toggleStyle(.switch)
                    }
                    if let messageID = subscription.uncertainMessageID {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("消息 #\(messageID) 的 Host 投递结果未知").font(.subheadline.bold())
                            if let detail = subscription.uncertainDetail { Text(detail).font(.caption).foregroundStyle(.secondary) }
                            HStack {
                                Button("目标 task 未出现，重试") {
                                    model.resolveUncertainDelivery(subscription.id, retry: true)
                                }
                                Button("目标 task 已出现，跳过") {
                                    model.resolveUncertainDelivery(subscription.id, retry: false)
                                }
                            }
                        }
                        .padding(8)
                        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                    }
                    Picker("同成员消息", selection: Binding(
                        get: { subscription.selfMessagePolicy },
                        set: { model.setSubscriptionPolicy(subscription.id, policy: $0) }
                    )) {
                        ForEach(SelfMessagePolicy.allCases) { policy in Text(policy.title).tag(policy) }
                    }
                    Text("当前 task 自己发送的消息始终不会回投，以避免循环。")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("消息拼接模板").font(.caption.bold())
                    TextEditor(text: $templateDraft).font(.system(.body, design: .monospaced)).frame(minHeight: 70)
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(.quaternary))
                    HStack {
                        Text("变量：{channel_name} {sender_name} {message_text} {message_id}")
                            .font(.caption2).foregroundStyle(.secondary)
                        Spacer()
                        Button("恢复默认") { templateDraft = defaultMessageTemplate }
                        Button("保存模板") { model.setSubscriptionTemplate(subscription.id, template: templateDraft) }
                        Button("删除订阅", role: .destructive) { model.removeSubscription(subscription.id) }
                    }
                }
                .padding(.vertical, 3)
            }
            .onAppear { templateDraft = subscription.template }
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
        Form {
            Section("身份") {
                HStack {
                    TextField("默认 Agent 名称", text: $model.draftCallsign)
                    Button("保存") { model.saveDefaultCallsign() }
                }
            }
            Section("Codex MCP") {
                LabeledContent("状态", value: model.sendStatus)
                HStack {
                    Button("启用或修复 MCP") { model.enableSending() }
                    Button("移除 MCP 配置", role: .destructive) { model.removeManagedMCP() }
                }
                Text("MCP 只连接本机 App；频道凭证保存在 Keychain，不会写入 Codex 配置。配置后需完全重启 ChatGPT。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("App") {
                Toggle("登录时启动", isOn: Binding(
                    get: { model.launchAtLogin },
                    set: { model.setLaunchAtLogin($0) }
                ))
                HStack {
                    Text("版本 \(model.currentVersion)")
                    Spacer()
                    Text(model.updateStatus).foregroundStyle(.secondary)
                    Button("检查 Beta 更新…") { Task { await model.checkBetaUpdate() } }
                }
            }
            Section("本机数据") {
                if model.oldBetaDataDetected {
                    Text("检测到旧 0.2 数据；0.3 保持隔离且不会迁移或删除。")
                        .foregroundStyle(.orange)
                }
                Button("移除全部 0.3 Beta 本机配置…", role: .destructive) { model.removeAllV2Data() }
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 600, height: 480)
    }
}

#if !SELF_TEST
@main
private struct AgentChannelsV2App: App {
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

        Settings {
            AgentChannelsSettingsView(model: model)
        }
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
        let block = CodexConfigEditor.managedBlock(sidecar: "/Applications/Agent Channels.app/Contents/MacOS/rogerthat-sidecar", binding: "/tmp/state-v2.json")
        let installed = try CodexConfigEditor.installing(block: block, into: "model = \"gpt-5\"\n")
        precondition(installed.contains(managedConfigStart))
        let removed = try CodexConfigEditor.removingManagedBlock(from: installed)
        precondition(removed == "model = \"gpt-5\"\n")
        let request = try LocalSendRequest.decode(Data(#"{"version":2,"operation":"send","source":{"provider":"codex","conversationId":"01900000-0000-7000-8000-000000000001"},"message":"hello"}"#.utf8))
        precondition(request.message == "hello")
        do {
            _ = try LocalSendRequest.decode(Data(#"{"version":2,"operation":"send","source":{"provider":"codex","conversationId":"bad"},"message":"hello"}"#.utf8))
            preconditionFailure("invalid source was accepted")
        } catch {}
        precondition(ReleaseVersion("0.3.0-beta.1")! < ReleaseVersion("0.3.0-beta.2")!)
        let taskA = compactTaskKey("01900000-0000-7000-8000-000000000001")!
        let taskB = compactTaskKey("01900000-0000-7000-8000-000000000002")!
        precondition(taskA.count == 26 && taskB.count == 26 && taskA != taskB)
        precondition(!taskA.contains("019000") && !taskA.contains("000001"))

        let subscriptionID = UUID()
        let channelID = UUID()
        let taskID = UUID()
        let confirmed = SubscriptionDeliveryRecord(
            subscriptionID: subscriptionID,
            channelID: channelID,
            messageID: "7",
            state: .received,
            detail: "用户确认目标 task 未出现，允许重试",
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
            state: .received
        )
        var messageB = messageA
        messageB.direction = .outbound
        precondition(messageA.id == messageB.id)

        let socketDirectory = URL(fileURLWithPath: "/private/tmp/ac-v2-\(getpid())", isDirectory: true)
        try FileManager.default.createDirectory(at: socketDirectory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: socketDirectory) }
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
