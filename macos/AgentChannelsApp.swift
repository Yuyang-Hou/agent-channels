import AppKit
import Foundation
import Security
import ServiceManagement
import SwiftUI

private let defaultOrigin = "https://rogerthat-production-fff6.up.railway.app"
private let keychainService = "com.agentchannels.channel"
private let managedConfigStart = "# >>> Agent Channels managed MCP >>>"
private let managedConfigEnd = "# <<< Agent Channels managed MCP <<<"

struct ChannelBinding: Codable, Equatable {
    var origin: String
    var channel: String
    var callsign: String
    var codexThread: String
    var replyDirectory: String
    var keychainService: String
    var keychainAccount: String
    var ownerPasswordAccount: String
    var lastDeliveredMessageId: Int64?
    var lastDeliveredAt: Double?
}

struct ChannelInvitation: Codable, Equatable {
    let version: Int
    let origin: String
    let channel: String
    let token: String
    let ownerPassword: String?
}

enum InvitationCodec {
    static func encode(_ invitation: ChannelInvitation) throws -> String {
        let data = try JSONEncoder().encode(invitation)
        return "ac1:" + data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func decode(_ raw: String) throws -> ChannelInvitation {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("ac1:") else {
            throw AppFailure("邀请口令格式不正确，应以 ac1: 开头")
        }
        var encoded = String(trimmed.dropFirst(4))
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let data = Data(base64Encoded: encoded) else {
            throw AppFailure("邀请口令已损坏")
        }
        let invitation = try JSONDecoder().decode(ChannelInvitation.self, from: data)
        guard invitation.version == 1,
              let url = URL(string: invitation.origin),
              url.scheme == "https" || url.scheme == "http",
              !invitation.channel.isEmpty,
              !invitation.token.isEmpty else {
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
            "args = [\(tomlString("reply-mcp")), \(tomlString("--config")), \(tomlString(binding))]",
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
    static let binding = support.appendingPathComponent("binding.json")
    static let replies = support.appendingPathComponent("replies", isDirectory: true)
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
        try FileManager.default.createDirectory(at: replies, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
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

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published var binding: ChannelBinding?
    @Published var draftCallsign = ""
    @Published var draftTask = ""
    @Published var invitationInput = ""
    @Published var showSetup = false
    @Published var busy = false
    @Published var listenerRunning = false
    @Published var networkStatus = "未监听"
    @Published var chatGPTStatus = "待检测"
    @Published var taskStatus = "未绑定"
    @Published var replyStatus = "未启用"
    @Published var lastDelivery = "暂无"
    @Published var lastError = ""
    @Published var uncertainMessageID: Int64?
    @Published var launchAtLogin = false

    private var listener: Process?
    private var listenerOutput: Pipe?
    private var listenerError: Pipe?
    private var statusRemainder = ""
    private var expectedStop = false
    private let defaults = UserDefaults.standard

    private init() {
        try? AppPaths.prepare()
        binding = try? Self.loadBinding()
        draftCallsign = binding?.callsign ?? ""
        draftTask = binding?.codexThread ?? ""
        launchAtLogin = SMAppService.mainApp.status == .enabled
        refreshReplyStatus()
        refreshLastDelivery()
        showSetup = binding == nil
        DispatchQueue.main.async { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                let ok = await self.preflight(showFailure: false)
                if ok && self.defaults.bool(forKey: "resumeListening") {
                    await self.startListening()
                }
            }
        }
    }

    var menuIcon: String {
        if listenerRunning && networkStatus == "已连接" { return "point.3.connected.trianglepath.dotted" }
        if !lastError.isEmpty { return "exclamationmark.triangle.fill" }
        return "point.3.filled.connected.trianglepath.dotted"
    }

    var hasCompleteBinding: Bool {
        guard let binding else { return false }
        return !binding.channel.isEmpty && !binding.callsign.isEmpty && !binding.codexThread.isEmpty
    }

    func createChannel() async {
        guard validateCallsign() else { return }
        guard confirmReplacementIfNeeded() else { return }
        busy = true
        defer { busy = false }
        do {
            var request = URLRequest(url: URL(string: "\(defaultOrigin)/api/channels")!)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "retention": "none",
                "trust_mode": "untrusted",
            ])
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let channel = object["channel_id"] as? String,
                  let token = object["join_token"] as? String else {
                throw AppFailure(Self.httpError(data: data, response: response))
            }
            let ownerPassword = object["owner_password"] as? String
            try storeChannel(origin: defaultOrigin, channel: channel, token: token, ownerPassword: ownerPassword)
            copyInvitation()
            showSetup = true
            showNotice(title: "频道已创建", message: "邀请口令已复制。绑定 Codex task 后即可开始监听。")
        } catch {
            fail(error)
        }
    }

    func useInvitation() {
        guard validateCallsign() else { return }
        guard confirmReplacementIfNeeded() else { return }
        do {
            let invitation = try InvitationCodec.decode(invitationInput)
            try storeChannel(
                origin: invitation.origin,
                channel: invitation.channel,
                token: invitation.token,
                ownerPassword: invitation.ownerPassword
            )
            invitationInput = ""
            showSetup = true
            lastError = ""
        } catch {
            fail(error)
        }
    }

    func preflight(showFailure: Bool = true) async -> Bool {
        let task = draftTask.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !task.isEmpty else {
            taskStatus = "未绑定"
            if showFailure { fail(AppFailure("请粘贴 codex://threads/...")) }
            return false
        }
        busy = true
        defer { busy = false }
        do {
            let result = try await Sidecar.run(["codex-preflight", "--codex-thread", task])
            guard result.status == 0,
                  let data = result.stdout.data(using: .utf8),
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  json["ok"] as? Bool == true,
                  let threadID = json["thread_id"] as? String else {
                throw AppFailure(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "Codex task 检测失败")
            }
            draftTask = "codex://threads/\(threadID)"
            chatGPTStatus = "可用"
            taskStatus = "已绑定 \(threadID.prefix(8))…"
            lastError = ""
            if var current = binding {
                current.callsign = draftCallsign.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                current.codexThread = draftTask
                try saveBinding(current)
            }
            return true
        } catch {
            let text = error.localizedDescription
            if text.localizedCaseInsensitiveContains("socket") || text.localizedCaseInsensitiveContains("ChatGPT") {
                chatGPTStatus = "不可用"
            } else {
                taskStatus = "需重新绑定"
            }
            lastError = text
            if showFailure { showNotice(title: "无法绑定 Codex task", message: text) }
            return false
        }
    }

    func toggleListening() {
        if listenerRunning {
            pauseListening()
        } else {
            Task { await startListening() }
        }
    }

    func startListening(since: Int64? = nil) async {
        guard listener == nil else { return }
        guard validateCallsign(), var current = binding else {
            fail(AppFailure("请先创建或加入频道"))
            showSetup = true
            return
        }
        guard await preflight() else { return }
        current.callsign = draftCallsign.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        current.codexThread = draftTask
        do {
            try saveBinding(current)
            guard let token = try KeychainStore.get(service: current.keychainService, account: current.keychainAccount),
                  !token.isEmpty else {
                throw AppFailure("Keychain 中没有频道 token，请重新粘贴邀请口令")
            }
            let owner = try KeychainStore.get(service: current.keychainService, account: current.ownerPasswordAccount)
            var secretObject: [String: Any] = ["token": token]
            if let owner, !owner.isEmpty { secretObject["ownerPassword"] = owner }
            let secrets = try JSONSerialization.data(withJSONObject: secretObject) + Data([0x0A])

            let process = Process()
            let output = Pipe()
            let error = Pipe()
            let input = Pipe()
            process.executableURL = Sidecar.executable
            var arguments = [
                "listen-here",
                "--origin", current.origin,
                "--channel", current.channel,
                "--identity-key", current.callsign,
                "--codex-thread", current.codexThread,
                "--secrets-stdin",
                "--reply-directory", current.replyDirectory,
                "--status-json",
            ]
            if let since {
                arguments += ["--since", String(since)]
            }
            process.arguments = arguments
            process.standardOutput = output
            process.standardError = error
            process.standardInput = input
            expectedStop = false
            statusRemainder = ""
            output.fileHandleForReading.readabilityHandler = { handle in
                _ = handle.availableData
            }
            error.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                let text = String(decoding: data, as: UTF8.self)
                DispatchQueue.main.async { self?.consumeSidecarOutput(text) }
            }
            process.terminationHandler = { [weak self] process in
                DispatchQueue.main.async { self?.listenerEnded(status: process.terminationStatus) }
            }
            try process.run()
            listener = process
            listenerOutput = output
            listenerError = error
            listenerRunning = true
            if since != nil { uncertainMessageID = nil }
            networkStatus = "连接中"
            lastError = ""
            defaults.set(true, forKey: "resumeListening")
            input.fileHandleForWriting.write(secrets)
            try? input.fileHandleForWriting.close()
        } catch {
            fail(error)
        }
    }

    func pauseListening() {
        defaults.set(false, forKey: "resumeListening")
        expectedStop = true
        listener?.terminate()
        if listener == nil {
            listenerRunning = false
            networkStatus = "已暂停"
        }
    }

    func resolveUncertainDelivery(retry: Bool) {
        guard !busy, listener == nil, let id = uncertainMessageID else { return }
        Task { await startListening(since: retry ? max(0, id - 1) : id) }
    }

    func copyInvitation() {
        guard let binding else { return fail(AppFailure("尚未配置频道")) }
        do {
            guard let token = try KeychainStore.get(service: binding.keychainService, account: binding.keychainAccount) else {
                throw AppFailure("Keychain 中没有频道 token")
            }
            let owner = try KeychainStore.get(service: binding.keychainService, account: binding.ownerPasswordAccount)
            let code = try InvitationCodec.encode(ChannelInvitation(
                version: 1,
                origin: binding.origin,
                channel: binding.channel,
                token: token,
                ownerPassword: owner
            ))
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(code, forType: .string)
        } catch {
            fail(error)
        }
    }

    // ponytail: fixed broadcast only; add a composer/recipient picker when proactive messaging becomes a product requirement.
    func sendTestHello() async {
        guard !busy, listenerRunning, networkStatus == "已连接", let current = binding else {
            return fail(AppFailure("请先开始监听并等待频道显示“已连接”"))
        }
        busy = true
        defer { busy = false }
        do {
            guard let token = try KeychainStore.get(service: current.keychainService, account: current.keychainAccount),
                  !token.isEmpty else { throw AppFailure("Keychain 中没有频道 token") }
            let owner = try KeychainStore.get(service: current.keychainService, account: current.ownerPasswordAccount)
            var joinBody: [String: Any] = ["callsign": current.callsign]
            if let owner, !owner.isEmpty { joinBody["owner_password"] = owner }

            let base = "\(current.origin)/api/channels/\(current.channel.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? current.channel)"
            var joinRequest = URLRequest(url: URL(string: "\(base)/join")!)
            joinRequest.httpMethod = "POST"
            joinRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            joinRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            joinRequest.httpBody = try JSONSerialization.data(withJSONObject: joinBody)
            let (joinData, joinResponse) = try await URLSession.shared.data(for: joinRequest)
            guard let joinHTTP = joinResponse as? HTTPURLResponse, (200..<300).contains(joinHTTP.statusCode),
                  let joinJSON = try JSONSerialization.jsonObject(with: joinData) as? [String: Any],
                  let session = joinJSON["session_id"] as? String else {
                throw AppFailure(Self.httpError(data: joinData, response: joinResponse))
            }

            var sendRequest = URLRequest(url: URL(string: "\(base)/send")!)
            sendRequest.httpMethod = "POST"
            sendRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            sendRequest.setValue(session, forHTTPHeaderField: "X-Session-Id")
            sendRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            sendRequest.httpBody = try JSONSerialization.data(withJSONObject: [
                "to": "all",
                "message": "\(current.callsign) 已加入 Agent Channels，正在进行连接验收。请回复一条确认消息。",
            ])
            let (sendData, sendResponse) = try await URLSession.shared.data(for: sendRequest)
            guard let sendHTTP = sendResponse as? HTTPURLResponse, (200..<300).contains(sendHTTP.statusCode) else {
                throw AppFailure(Self.httpError(data: sendData, response: sendResponse))
            }
            lastError = ""
            showNotice(title: "测试招呼已发送", message: "另一台在线设备的绑定 task 应收到一条真实消息。")
        } catch {
            fail(error)
        }
    }

    func enableReplies() {
        guard let binding else { return fail(AppFailure("请先配置频道")) }
        guard AppPaths.appIsInstalled else {
            return fail(AppFailure("请先把 Agent Channels.app 拖入 Applications，再启用 AI 回复"))
        }
        let alert = NSAlert()
        alert.messageText = "启用 AI 回复？"
        alert.informativeText = "Agent Channels 将只在 ~/.codex/config.toml 的受管理标记区块中添加固定 STDIO MCP。频道密钥仍保存在 Keychain，不会修改环境变量。启用后需要完全重启 ChatGPT。"
        alert.addButton(withTitle: "启用并写入配置")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try Self.writeReplyConfig(binding: binding)
            refreshReplyStatus()
            showNotice(title: "AI 回复已配置", message: "请完全退出并重新打开 ChatGPT。Agent Channels 不会替你重启或修改环境变量。")
        } catch {
            fail(error)
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        if enabled && !AppPaths.appIsInstalled {
            launchAtLogin = false
            return fail(AppFailure("请先把 Agent Channels.app 拖入 Applications，再启用登录启动"))
        }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLogin = SMAppService.mainApp.status == .enabled
        } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            fail(AppFailure("无法修改登录启动：\(error.localizedDescription)"))
        }
    }

    func showDiagnostics() {
        let message = lastError.isEmpty
            ? "频道：\(networkStatus)\nChatGPT：\(chatGPTStatus)\n任务：\(taskStatus)\n回复：\(replyStatus)"
            : lastError
        showNotice(title: "Agent Channels 连接诊断", message: message)
    }

    func removeLocalConfiguration() {
        guard let current = binding else { return }
        let alert = NSAlert()
        alert.messageText = "移除 Agent Channels 本机配置？"
        alert.informativeText = "将暂停监听，并移除频道凭证、Binding、待回复引用和受管理的 MCP 配置。之后需要重启 ChatGPT。"
        alert.addButton(withTitle: "移除")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            pauseListening()
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            if FileManager.default.fileExists(atPath: AppPaths.codexConfig.path) {
                let existing = try String(contentsOf: AppPaths.codexConfig, encoding: .utf8)
                try Self.writeCodexConfig(CodexConfigEditor.removingManagedBlock(from: existing))
            }
            try KeychainStore.delete(service: current.keychainService, account: current.keychainAccount)
            try KeychainStore.delete(service: current.keychainService, account: current.ownerPasswordAccount)
            for url in [AppPaths.binding, AppPaths.replies] where FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            defaults.removeObject(forKey: "resumeListening")
            binding = nil
            draftCallsign = ""
            draftTask = ""
            invitationInput = ""
            showSetup = true
            listenerRunning = false
            networkStatus = "未监听"
            chatGPTStatus = "待检测"
            taskStatus = "未绑定"
            replyStatus = "未启用"
            lastDelivery = "暂无"
            lastError = ""
            uncertainMessageID = nil
            launchAtLogin = false
            showNotice(title: "本机配置已移除", message: "请完全退出并重新打开 ChatGPT，使 MCP 配置变更生效。")
        } catch {
            fail(error)
        }
    }

    func quit() {
        pauseListening()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { NSApp.terminate(nil) }
    }

    private func consumeSidecarOutput(_ chunk: String) {
        statusRemainder += chunk
        let lines = statusRemainder.components(separatedBy: .newlines)
        statusRemainder = lines.last ?? ""
        for line in lines.dropLast() {
            guard line.hasPrefix("@agent-channels ") else {
                if line.localizedCaseInsensitiveContains("error") { lastError = line }
                continue
            }
            let payload = String(line.dropFirst("@agent-channels ".count))
            guard let data = payload.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let state = json["state"] as? String else { continue }
            let detail = (json["error"] as? String) ?? (json["message"] as? String) ?? ""
            switch state {
            case "joined": networkStatus = "已加入"
            case "connecting": networkStatus = "连接中"
            case "connected": networkStatus = "已连接"
            case "delivered":
                networkStatus = "已连接"
                chatGPTStatus = "可用"
                uncertainMessageID = nil
                if let id = Self.messageID(json) {
                    recordDelivery(id: id)
                } else {
                    lastDelivery = DateFormatter.delivery.string(from: Date())
                }
            case "reconnecting": networkStatus = "重连中"
            case "error":
                let kind = json["kind"] as? String
                if kind == "delivery_outcome_unknown", let id = Self.messageID(json) {
                    uncertainMessageID = id
                    defaults.set(false, forKey: "resumeListening")
                    networkStatus = "待人工确认"
                    lastError = "消息 #\(id) 的投递结果不确定。请检查目标 task 后选择重试或跳过。"
                    continue
                }
                lastError = detail.nilIfEmpty ?? "Bridge 报告未知错误"
                if detail.localizedCaseInsensitiveContains("codex") ||
                    detail.localizedCaseInsensitiveContains("chatgpt") ||
                    detail.localizedCaseInsensitiveContains("ipc") ||
                    detail.localizedCaseInsensitiveContains("rebind") {
                    chatGPTStatus = "不可用"
                    taskStatus = detail.localizedCaseInsensitiveContains("rebind") ? "需重新绑定" : taskStatus
                } else {
                    networkStatus = "异常"
                }
            case "stopped": networkStatus = "已暂停"
            default: break
            }
        }
    }

    private func listenerEnded(status: Int32) {
        listenerOutput?.fileHandleForReading.readabilityHandler = nil
        listenerError?.fileHandleForReading.readabilityHandler = nil
        listener = nil
        listenerOutput = nil
        listenerError = nil
        listenerRunning = false
        if uncertainMessageID != nil {
            networkStatus = "待人工确认"
        } else if expectedStop || status == 0 {
            networkStatus = "已暂停"
        } else {
            networkStatus = "异常"
            if lastError.isEmpty { lastError = "Bridge 已退出（exit \(status)）" }
        }
        expectedStop = false
    }

    private func storeChannel(origin: String, channel: String, token: String, ownerPassword: String?) throws {
        pauseListening()
        let previous = binding
        let tokenAccount = "channel:\(channel):token"
        let ownerAccount = "channel:\(channel):owner-password"
        try KeychainStore.set(token, service: keychainService, account: tokenAccount)
        if let ownerPassword, !ownerPassword.isEmpty {
            try KeychainStore.set(ownerPassword, service: keychainService, account: ownerAccount)
        } else {
            try KeychainStore.delete(service: keychainService, account: ownerAccount)
        }
        let newBinding = ChannelBinding(
            origin: origin,
            channel: channel,
            callsign: draftCallsign.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            codexThread: draftTask.trimmingCharacters(in: .whitespacesAndNewlines),
            replyDirectory: AppPaths.replies.path,
            keychainService: keychainService,
            keychainAccount: tokenAccount,
            ownerPasswordAccount: ownerAccount,
            lastDeliveredMessageId: nil,
            lastDeliveredAt: nil
        )
        try saveBinding(newBinding)
        if let previous, previous.keychainAccount != tokenAccount {
            try KeychainStore.delete(service: previous.keychainService, account: previous.keychainAccount)
            try KeychainStore.delete(service: previous.keychainService, account: previous.ownerPasswordAccount)
            if FileManager.default.fileExists(atPath: AppPaths.replies.path) {
                try FileManager.default.removeItem(at: AppPaths.replies)
                try AppPaths.prepare()
            }
        }
        networkStatus = "未监听"
        refreshReplyStatus()
    }

    private func saveBinding(_ value: ChannelBinding) throws {
        try AppPaths.prepare()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: AppPaths.binding, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: AppPaths.binding.path)
        binding = value
    }

    private static func loadBinding() throws -> ChannelBinding {
        try JSONDecoder().decode(ChannelBinding.self, from: Data(contentsOf: AppPaths.binding))
    }

    private func validateCallsign() -> Bool {
        let value = draftCallsign.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let valid = value.range(of: #"^[a-z0-9][a-z0-9_-]{0,31}$"#, options: .regularExpression) != nil && value != "all"
        if !valid { fail(AppFailure("频道昵称须为 1–32 位字母、数字、_ 或 -，且不能是 all")) }
        return valid
    }

    private func confirmReplacementIfNeeded() -> Bool {
        guard binding != nil else { return true }
        let alert = NSAlert()
        alert.messageText = "替换当前频道？"
        alert.informativeText = "当前监听会暂停，并改为新的单频道配置。"
        alert.addButton(withTitle: "替换")
        alert.addButton(withTitle: "取消")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func refreshReplyStatus() {
        guard binding != nil,
              let existing = try? String(contentsOf: AppPaths.codexConfig, encoding: .utf8) else {
            replyStatus = "未启用"
            return
        }
        let expected = CodexConfigEditor.managedBlock(sidecar: Sidecar.executable.path, binding: AppPaths.binding.path)
        replyStatus = existing.contains(expected) ? "已配置" : existing.contains(managedConfigStart) ? "需重新启用" : "未启用"
    }

    private static func writeReplyConfig(binding: ChannelBinding) throws {
        try AppPaths.prepare()
        try FileManager.default.createDirectory(at: AppPaths.codexDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let existing = (try? String(contentsOf: AppPaths.codexConfig, encoding: .utf8)) ?? ""
        let block = CodexConfigEditor.managedBlock(sidecar: Sidecar.executable.path, binding: AppPaths.binding.path)
        let updated = try CodexConfigEditor.installing(block: block, into: existing)
        try writeCodexConfig(updated)
    }

    private static func writeCodexConfig(_ updated: String) throws {
        let permissions = ((try? FileManager.default.attributesOfItem(atPath: AppPaths.codexConfig.path)[.posixPermissions]) as? NSNumber)?.intValue ?? 0o600
        try updated.write(to: AppPaths.codexConfig, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: AppPaths.codexConfig.path)
    }

    private func recordDelivery(id: Int64) {
        let date = Date()
        lastDelivery = "\(DateFormatter.delivery.string(from: date)) · #\(id)"
        guard var current = binding else { return }
        current.lastDeliveredMessageId = id
        current.lastDeliveredAt = date.timeIntervalSince1970
        try? saveBinding(current)
    }

    private func refreshLastDelivery() {
        guard let binding, let timestamp = binding.lastDeliveredAt else { return }
        let date = Date(timeIntervalSince1970: timestamp)
        let suffix = binding.lastDeliveredMessageId.map { " · #\($0)" } ?? ""
        lastDelivery = DateFormatter.delivery.string(from: date) + suffix
    }

    private static func messageID(_ json: [String: Any]) -> Int64? {
        for key in ["message_id", "messageId", "id"] {
            if let value = json[key] as? NSNumber { return value.int64Value }
            if let value = json[key] as? String, let id = Int64(value) { return id }
        }
        return nil
    }

    private static func httpError(data: Data, response: URLResponse) -> String {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = object["error"] as? String { return error }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return "频道服务请求失败（HTTP \(status)）"
    }

    private func fail(_ error: Error) {
        lastError = error.localizedDescription
        showNotice(title: "Agent Channels", message: error.localizedDescription)
    }

    private func showNotice(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        alert.runModal()
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

struct MenuPanel: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: model.menuIcon).font(.title2)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Agent Channels").font(.headline)
                    Text(model.binding.map { "\($0.channel) · \($0.callsign)" } ?? "尚未配置")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }

            GroupBox {
                VStack(spacing: 7) {
                    StatusRow(name: "频道", value: model.networkStatus)
                    StatusRow(name: "ChatGPT", value: model.chatGPTStatus)
                    StatusRow(name: "任务", value: model.taskStatus)
                    StatusRow(name: "回复", value: model.replyStatus)
                    StatusRow(name: "最近投递", value: model.lastDelivery)
                }
                .padding(.vertical, 2)
            }

            if model.showSetup || model.binding == nil {
                setup
            } else {
                controls
            }

            if let id = model.uncertainMessageID, !model.listenerRunning {
                GroupBox("消息 #\(id) 是否已出现？") {
                    HStack {
                        Button("未出现，重试") { model.resolveUncertainDelivery(retry: true) }
                        Button("已出现，跳过") { model.resolveUncertainDelivery(retry: false) }
                        Spacer()
                    }
                    .padding(.vertical, 2)
                }
                .disabled(model.busy)
            }

            Divider()
            Toggle("登录时启动", isOn: Binding(
                get: { model.launchAtLogin },
                set: { model.setLaunchAtLogin($0) }
            ))
            .toggleStyle(.switch)

            HStack {
                Button("连接诊断…") { model.showDiagnostics() }
                if model.binding != nil {
                    Button("移除本机配置…", role: .destructive) { model.removeLocalConfiguration() }
                }
                Spacer()
                Button("退出") { model.quit() }
            }
        }
        .padding(14)
        .frame(width: 390)
    }

    private var controls: some View {
        VStack(spacing: 8) {
            HStack {
                Button(model.listenerRunning ? "暂停监听" : "开始监听") { model.toggleListening() }
                    .buttonStyle(.borderedProminent)
                Button("复制邀请") { model.copyInvitation() }
                Button("发送测试招呼") { Task { await model.sendTestHello() } }
                    .disabled(model.busy || !model.listenerRunning || model.networkStatus != "已连接")
                Spacer()
            }
            HStack {
                Button("重新绑定…") { model.showSetup = true }
                if model.replyStatus != "已配置" {
                    Button("启用 AI 回复…") { model.enableReplies() }
                }
                Spacer()
            }
        }
    }

    private var setup: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("频道").font(.subheadline.bold())
            TextField("频道昵称，例如 frontend", text: $model.draftCallsign)
                .textFieldStyle(.roundedBorder)
            HStack {
                Button("创建新频道") { Task { await model.createChannel() } }
                    .disabled(model.busy)
                Text("或").foregroundStyle(.secondary)
                SecureField("粘贴 ac1: 邀请口令", text: $model.invitationInput)
                    .textFieldStyle(.roundedBorder)
                Button("使用") { model.useInvitation() }
                    .disabled(model.busy || model.invitationInput.isEmpty)
            }

            Text("Codex task").font(.subheadline.bold()).padding(.top, 2)
            TextField("codex://threads/...", text: $model.draftTask)
                .textFieldStyle(.roundedBorder)
            Text("先在 ChatGPT Desktop 中打开目标 task 一次；检测不会创建 turn。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("检查并绑定") { Task { await model.preflight() } }
                    .disabled(model.busy || model.draftTask.isEmpty)
                Button(model.listenerRunning ? "暂停监听" : "开始监听") { model.toggleListening() }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.busy || !model.hasCompleteBinding)
                if model.binding != nil {
                    Button("完成") { model.showSetup = false }
                }
                Spacer()
            }
            if model.binding != nil && model.replyStatus != "已配置" {
                Button("启用 AI 回复…") { model.enableReplies() }
            }
        }
    }
}

#if !SELF_TEST
@main
struct AgentChannelsApp: App {
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        MenuBarExtra {
            MenuPanel(model: model)
        } label: {
            Image(systemName: model.menuIcon)
        }
        .menuBarExtraStyle(.window)
    }
}
#else
@main
struct AgentChannelsSelfTest {
    static func main() throws {
        let invitation = ChannelInvitation(version: 1, origin: "https://example.test", channel: "quiet-owl-0001", token: "rt_secret", ownerPassword: nil)
        let encodedInvitation = try InvitationCodec.encode(invitation)
        let decodedInvitation = try InvitationCodec.decode(encodedInvitation)
        precondition(decodedInvitation == invitation)
        let block = CodexConfigEditor.managedBlock(sidecar: "/Applications/Agent Channels.app/Contents/MacOS/rogerthat-sidecar", binding: "/tmp/binding.json")
        let installed = try CodexConfigEditor.installing(block: block, into: "model = \"gpt-5\"\n")
        precondition(installed.contains(managedConfigStart))
        let replaced = try CodexConfigEditor.installing(block: block.replacingOccurrences(of: "reply-mcp", with: "reply-mcp-v2"), into: installed)
        precondition(replaced.components(separatedBy: managedConfigStart).count == 2)
        let removed = try CodexConfigEditor.removingManagedBlock(from: replaced)
        precondition(removed == "model = \"gpt-5\"\n")
        print("macos self-test ok")
    }
}
#endif
