import AppKit
import Combine
import CryptoKit
import Darwin
import Foundation
import Security
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

enum AppPaths {
    static let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Pijoo", isDirectory: true)
    static let state = support.appendingPathComponent("state-v2.json")
    static let accountStates = support.appendingPathComponent("accounts", isDirectory: true)
    static let legacyBinding = support.appendingPathComponent("binding.json")
    static let sendSocket = support.appendingPathComponent("send.sock")
    static let messages = support.appendingPathComponent("messages", isDirectory: true)
    static let logs = support.appendingPathComponent("logs", isDirectory: true)
    static let updates = support.appendingPathComponent("updates", isDirectory: true)
    static let defaultWorkspace = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Pijoo", isDirectory: true)
    static let pendingUpdateDMG = updates.appendingPathComponent("pending-update.dmg")
    static let pendingUpdate = updates.appendingPathComponent("pending-update.json")
    static let updateError = updates.appendingPathComponent("last-error.txt")
    static let codexDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".codex", isDirectory: true)
    static let codexConfig = codexDirectory.appendingPathComponent("config.toml")
    static let codexSkills = codexDirectory.appendingPathComponent("skills", isDirectory: true)
    static let agentChannelsSkill = codexSkills.appendingPathComponent("pijoo", isDirectory: true)
    static var isDevelopmentBuild: Bool {
        Bundle.main.object(forInfoDictionaryKey: "PijooDevelopmentBuild") as? Bool == true
    }

    static var appIsInstalled: Bool {
        if isDevelopmentBuild { return true }
        let app = Bundle.main.bundleURL.standardizedFileURL.path
        let userApplications = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications", isDirectory: true).path + "/"
        return app.hasPrefix("/Applications/") || app.hasPrefix(userApplications)
    }

    static func accountState(_ accountID: String) -> URL {
        let digest = SHA256.hash(data: Data(accountID.utf8)).map { String(format: "%02x", $0) }.joined()
        return accountStates.appendingPathComponent("\(digest).json")
    }

    static func assistantConfig(_ accountID: String) -> URL {
        let digest = SHA256.hash(data: Data(accountID.utf8)).map { String(format: "%02x", $0) }.joined()
        return accountStates.appendingPathComponent("\(digest)-assistant.json")
    }

    static func prepare() throws {
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: support.path)
        try FileManager.default.createDirectory(at: messages, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: messages.path)
        try FileManager.default.createDirectory(at: accountStates, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: accountStates.path)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: logs.path)
        try FileManager.default.createDirectory(at: defaultWorkspace, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: defaultWorkspace.path)
    }
}

enum AssistantConfigStore {
    static func load(accountID: String) -> AssistantConfig {
        let url = AppPaths.assistantConfig(accountID)
        guard let data = try? Data(contentsOf: url),
              let config = try? JSONDecoder().decode(AssistantConfig.self, from: data),
              config.version == 1,
              config.replyMode == .draft else {
            return AssistantConfig()
        }
        return config
    }

    static func save(_ config: AssistantConfig, accountID: String) throws {
        guard config.version == 1, config.replyMode == .draft else {
            throw AppFailure("助理配置版本不受支持")
        }
        try AppPaths.prepare()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let url = AppPaths.assistantConfig(accountID)
        try encoder.encode(config).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

enum ClientLog {
    private static let queue = DispatchQueue(label: "dev.pijoo.client-log")
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
                data = Data("No Pijoo client log entries.\n".utf8)
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

enum PijooSkillInstaller {
    static var bundledSkill: URL {
        Bundle.main.resourceURL!
            .appendingPathComponent("skills", isDirectory: true)
            .appendingPathComponent("pijoo", isDirectory: true)
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
        destination: URL = AppPaths.agentChannelsSkill,
        allowRetargetFromBundleIdentifier: String? = nil
    ) throws -> URL? {
        guard FileManager.default.fileExists(atPath: source.appendingPathComponent("SKILL.md").path) else {
            throw AppFailure("App 安装包缺少 Pijoo Skill，请重新安装")
        }
        if itemExists(destination) {
            guard isSymbolicLink(destination) else {
                throw AppFailure("~/.codex/skills/pijoo 已存在且不由本 App 管理，请先手动处理")
            }
            let target = try resolvedLinkTarget(destination).standardizedFileURL
            if target == source.standardizedFileURL { return nil }
            guard let bundleIdentifier = allowRetargetFromBundleIdentifier,
                  isBundledSkill(target, bundleIdentifier: bundleIdentifier) else {
                throw AppFailure("~/.codex/skills/pijoo 指向其他内容，未覆盖")
            }
            try replaceLink(destination, from: target, to: source)
            return target
        }
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: source)
        return nil
    }

    static func restoreLink(destination: URL, current: URL, previous: URL) throws {
        try replaceLink(destination, from: current.standardizedFileURL, to: previous)
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
            throw AppFailure("未移除不由本 App 管理的 Pijoo Skill")
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

    private static func isBundledSkill(_ target: URL, bundleIdentifier: String) -> Bool {
        let bundle = target
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        guard bundle.pathExtension == "app",
              target == bundle.appendingPathComponent("Contents/Resources/skills/pijoo").standardizedFileURL,
              FileManager.default.fileExists(atPath: target.appendingPathComponent("SKILL.md").path),
              let info = NSDictionary(contentsOf: bundle.appendingPathComponent("Contents/Info.plist")),
              info["CFBundleIdentifier"] as? String == bundleIdentifier else { return false }
        return true
    }

    private static func replaceLink(_ destination: URL, from previous: URL, to replacement: URL) throws {
        guard isSymbolicLink(destination),
              try resolvedLinkTarget(destination).standardizedFileURL == previous.standardizedFileURL else {
            throw AppFailure("~/.codex/skills/pijoo 在修复期间发生变化，未覆盖")
        }
        try FileManager.default.removeItem(at: destination)
        do {
            try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: replacement)
        } catch {
            try? FileManager.default.createSymbolicLink(at: destination, withDestinationURL: previous)
            throw error
        }
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
        skillSource: URL = PijooSkillInstaller.bundledSkill,
        skillDestination: URL = AppPaths.agentChannelsSkill,
        allowSkillRetargetFromBundleIdentifier: String? = nil
    ) throws {
        let existing = try CodexConfigEditor.reading(configURL) ?? ""
        let updated = try CodexConfigEditor.installing(block: block, into: existing)
        let skillLinkAlreadyExisted = PijooSkillInstaller.isManagedLink(
            source: skillSource,
            destination: skillDestination
        )
        var previousSkillTarget: URL?
        do {
            previousSkillTarget = try PijooSkillInstaller.install(
                source: skillSource,
                destination: skillDestination,
                allowRetargetFromBundleIdentifier: allowSkillRetargetFromBundleIdentifier
            )
            if updated != existing { try CodexConfigEditor.writing(updated, to: configURL) }
        } catch {
            if let previousSkillTarget {
                try? PijooSkillInstaller.restoreLink(
                    destination: skillDestination,
                    current: skillSource,
                    previous: previousSkillTarget
                )
            } else if !skillLinkAlreadyExisted {
                try? PijooSkillInstaller.remove(source: skillSource, destination: skillDestination)
            }
            throw error
        }
    }

    static func remove(
        configURL: URL,
        skillSource: URL = PijooSkillInstaller.bundledSkill,
        skillDestination: URL = AppPaths.agentChannelsSkill
    ) throws {
        try PijooSkillInstaller.validateRemoval(source: skillSource, destination: skillDestination)
        let existing = try CodexConfigEditor.reading(configURL)
        let updated = try existing.map { try CodexConfigEditor.removingManagedBlock(from: $0) }
        let configChanged = existing != updated
        if let updated, configChanged { try CodexConfigEditor.writing(updated, to: configURL) }
        do {
            try PijooSkillInstaller.remove(source: skillSource, destination: skillDestination)
        } catch {
            if let existing, configChanged { try? CodexConfigEditor.writing(existing, to: configURL) }
            throw error
        }
    }
}

struct LocalSource: Codable {
    let provider: String
    let conversationId: String
}

struct LocalSettingsPatch: Codable {
    let template: String?
    let sentMessageTemplate: String?
    let selfMessagePolicy: SelfMessagePolicy?
    let receiveScope: ReceiveScope?
    let defaultSend: Bool?

    enum CodingKeys: String, CodingKey {
        case template
        case sentMessageTemplate = "sent_message_template"
        case selfMessagePolicy = "self_message_policy"
        case receiveScope = "receive_scope"
        case defaultSend = "default_send"
    }
}

struct LocalSidecarEvent: Codable {
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
    let mention: MessageMention?

    enum CodingKeys: String, CodingKey {
        case id, from, to, text, at, state, error, source, mention
        case senderMemberID = "sender_member_id"
        case senderEndpointID = "sender_endpoint_id"
        case senderName = "sender_name"
    }
}

struct LocalSendRequest: Decodable {
    let version: Int
    let operation: String
    let source: LocalSource?
    let clientVersion: String?
    let channel: String?
    let message: String?
    let mentions: [String]?
    let settings: LocalSettingsPatch?
    let subscriptionID: String?
    let event: LocalSidecarEvent?

    enum CodingKeys: String, CodingKey {
        case version, operation, source, channel, message, mentions, settings, event
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
            if let mentions = request.mentions {
                guard !mentions.isEmpty, mentions.count <= 100,
                      mentions.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
                      Set(mentions).count == mentions.count,
                      !mentions.contains("all") || mentions == ["all"] else {
                    throw AppFailure("mentions must contain 1-100 unique member ids, or only all")
                }
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

struct LocalChannelSummary: Encodable {
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

struct LocalSubscriptionSummary: Encodable {
    let channel: String
    let receiveEnabled: Bool
    let template: String
    let sentMessageTemplate: String
    let selfMessagePolicy: SelfMessagePolicy
    let receiveScope: ReceiveScope
    let defaultSend: Bool

    enum CodingKeys: String, CodingKey {
        case channel, template
        case sentMessageTemplate = "sent_message_template"
        case receiveEnabled = "receive_enabled"
        case selfMessagePolicy = "self_message_policy"
        case receiveScope = "receive_scope"
        case defaultSend = "default_send"
    }
}

struct LocalMentionMemberSummary: Encodable {
    let memberID: String
    let name: String
    let isSelf: Bool

    enum CodingKeys: String, CodingKey {
        case name
        case memberID = "member_id"
        case isSelf = "is_self"
    }
}

struct LocalOperationResult: Encodable {
    let id: String?
    let callsign: String?
    let channel: String?
    let channels: [LocalChannelSummary]?
    let members: [LocalMentionMemberSummary]?
    let settings: LocalSubscriptionSummary?
    let provenance: LocalMessageProvenance?
    let message: String?

    init(
        id: String? = nil,
        callsign: String? = nil,
        channel: String? = nil,
        channels: [LocalChannelSummary]? = nil,
        members: [LocalMentionMemberSummary]? = nil,
        settings: LocalSubscriptionSummary? = nil,
        provenance: LocalMessageProvenance? = nil,
        message: String? = nil
    ) {
        self.id = id
        self.callsign = callsign
        self.channel = channel
        self.channels = channels
        self.members = members
        self.settings = settings
        self.provenance = provenance
        self.message = message
    }

    static func send(id: String, callsign: String, channel: String, message: String) -> LocalOperationResult {
        LocalOperationResult(id: id, callsign: callsign, channel: channel, message: message)
    }
}

struct LocalSendResponse: Encodable {
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

enum ChannelSendFailure: LocalizedError {
    case definitive(String)
    case unknown(String)

    var errorDescription: String? {
        switch self {
        case .definitive(let message), .unknown(let message): return message
        }
    }
}

struct ChannelAuthorizationFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

final class LocalSendServer {
    typealias Handler = @MainActor (LocalSendRequest) async -> LocalSendResponse

    private let socketURL: URL
    private let handler: Handler
    private let queue = DispatchQueue(label: "dev.pijoo.local-send", qos: .utility)
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
        if result == 0 { throw AppFailure("Pijoo 已在运行") }
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

struct PendingUpdate: Codable {
    let version: String
}

enum UpdateCoordinator {
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
        let helper = Bundle.main.executableURL!.deletingLastPathComponent().appendingPathComponent("pijoo-updater")
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
        guard let url = Bundle.main.url(forResource: "PijooMenuBar", withExtension: "svg"),
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


extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

extension DateFormatter {
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


final class SubscriptionListener {
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

enum MessageLedger {
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
