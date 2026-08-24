import Foundation
import Darwin

private struct UpdateFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

@main
private enum AgentChannelsUpdateHelper {
    static func main() {
        if CommandLine.arguments.dropFirst().first == "--self-test" {
            precondition(designatedRequirement(from: "designated => identifier \"com.agentchannels.menubar\"\n") == "identifier \"com.agentchannels.menubar\"")
            precondition(designatedRequirement(from: "# designated => cdhash H\"abc\"\n") == "cdhash H\"abc\"")
            return
        }
        guard CommandLine.arguments.count == 7, let parentPID = pid_t(CommandLine.arguments[1]) else {
            exit(64)
        }
        let dmg = URL(fileURLWithPath: CommandLine.arguments[2])
        let target = URL(fileURLWithPath: CommandLine.arguments[3])
        let expectedVersion = CommandLine.arguments[4]
        let metadata = URL(fileURLWithPath: CommandLine.arguments[5])
        let errorFile = URL(fileURLWithPath: CommandLine.arguments[6])

        waitForExit(parentPID)
        do {
            try install(dmg: dmg, target: target, expectedVersion: expectedVersion)
            try? FileManager.default.removeItem(at: metadata)
            try? FileManager.default.removeItem(at: dmg)
            try? FileManager.default.removeItem(at: errorFile)
        } catch {
            try? FileManager.default.removeItem(at: metadata)
            try? Data(error.localizedDescription.utf8).write(to: errorFile, options: .atomic)
        }
        _ = try? run("/usr/bin/open", ["-n", target.path])
    }

    private static func waitForExit(_ pid: pid_t) {
        while kill(pid, 0) == 0 || errno == EPERM { usleep(100_000) }
    }

    private static func install(dmg: URL, target: URL, expectedVersion: String) throws {
        guard dmg.isFileURL, target.isFileURL,
              target.path.hasPrefix("/Applications/") || target.path.hasPrefix(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path + "/") else {
            throw UpdateFailure(message: "更新目标不在 Applications")
        }
        try verifyBundle(target, expectedVersion: nil)
        let requirement = try currentDesignatedRequirement(target)
        let mountOutput = try run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-plist", dmg.path])
        let plist = try PropertyListSerialization.propertyList(from: mountOutput, format: nil) as? [String: Any]
        guard let entities = plist?["system-entities"] as? [[String: Any]],
              let mountPath = entities.compactMap({ $0["mount-point"] as? String }).first else {
            throw UpdateFailure(message: "更新包挂载失败")
        }
        defer { _ = try? run("/usr/bin/hdiutil", ["detach", mountPath]) }

        let candidate = URL(fileURLWithPath: mountPath).appendingPathComponent("Agent Channels.app")
        try verifyBundle(candidate, expectedVersion: expectedVersion)
        guard try currentDesignatedRequirement(candidate) == requirement else {
            throw UpdateFailure(message: "更新包签名身份与当前 App 不一致")
        }

        let manager = FileManager.default
        let staged = target.deletingLastPathComponent().appendingPathComponent(".Agent-Channels-update-\(UUID().uuidString).app")
        let backupName = ".Agent-Channels-previous-\(UUID().uuidString).app"
        let backup = target.deletingLastPathComponent().appendingPathComponent(backupName)
        defer { try? manager.removeItem(at: staged) }
        try manager.copyItem(at: candidate, to: staged)
        try verifyBundle(staged, expectedVersion: expectedVersion)
        guard try currentDesignatedRequirement(staged) == requirement else {
            throw UpdateFailure(message: "暂存 App 签名身份不一致")
        }
        do {
            _ = try manager.replaceItemAt(target, withItemAt: staged, backupItemName: backupName, options: .usingNewMetadataOnly)
        } catch {
            if !manager.fileExists(atPath: target.path), manager.fileExists(atPath: backup.path) {
                try? manager.moveItem(at: backup, to: target)
            }
            throw error
        }
        try? manager.removeItem(at: backup)
    }

    private static func verifyBundle(_ app: URL, expectedVersion: String?) throws {
        guard try app.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
            throw UpdateFailure(message: "更新 App 不能是符号链接")
        }
        let plistURL = app.appendingPathComponent("Contents/Info.plist")
        guard let values = NSDictionary(contentsOf: plistURL) as? [String: Any],
              values["CFBundleIdentifier"] as? String == "com.agentchannels.menubar" else {
            throw UpdateFailure(message: "更新包不是 Agent Channels")
        }
        if let expectedVersion,
           values["AgentChannelsReleaseVersion"] as? String != expectedVersion {
            throw UpdateFailure(message: "更新包版本与 Release 不一致")
        }
        _ = try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
    }

    private static func currentDesignatedRequirement(_ app: URL) throws -> String {
        let output = try run("/usr/bin/codesign", ["-d", "-r-", app.path], mergeError: true)
        guard let text = String(data: output, encoding: .utf8), let requirement = designatedRequirement(from: text) else {
            throw UpdateFailure(message: "无法读取当前 App 签名要求")
        }
        return requirement
    }

    private static func designatedRequirement(from output: String) -> String? {
        output.split(separator: "\n").compactMap { line -> String? in
            let value = line.hasPrefix("# ") ? line.dropFirst(2) : line[...]
            guard value.hasPrefix("designated => ") else { return nil }
            return String(value.dropFirst("designated => ".count))
        }.first
    }

    @discardableResult
    private static func run(_ executable: String, _ arguments: [String], mergeError: Bool = false) throws -> Data {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = mergeError ? pipe : FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            throw UpdateFailure(message: "更新命令失败：\(URL(fileURLWithPath: executable).lastPathComponent)")
        }
        return data
    }
}
