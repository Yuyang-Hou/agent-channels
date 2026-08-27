import AppKit
import Foundation

#if SELF_TEST
@main
private struct PijooV2SelfTest {
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
        let accountVerifier = String(repeating: "v", count: 43)
        precondition(accountPKCEChallenge(accountVerifier) == "7w_YNF9DSfIdPf_pRjSq646_kPr-2-o9NAl16JGghdM")
        let accountState = String(repeating: "s", count: 43)
        let accountCode = String(repeating: "c", count: 43)
        let parsedAccountCode = try accountExchangeCode(
            from: URL(string: "pijoo://oauth/callback?code=\(accountCode)&state=\(accountState)")!,
            expectedState: accountState
        )
        precondition(parsedAccountCode == accountCode)
        do {
            _ = try accountExchangeCode(
                from: URL(string: "pijoo://oauth/callback?code=\(accountCode)&state=wrong")!,
                expectedState: accountState
            )
            preconditionFailure("mismatched OAuth state was accepted")
        } catch {}
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
        let unboundSend = try outboundSelection(
            taskID: nil,
            explicitChannelID: joinedChannel.id,
            channels: [joinedChannel],
            subscriptions: []
        )
        precondition(unboundSend.channelID == joinedChannel.id && unboundSend.subscriptionID == nil)
        let soleChannelSend = try outboundSelection(
            taskID: nil,
            explicitChannelID: nil,
            channels: [joinedChannel],
            subscriptions: []
        )
        precondition(soleChannelSend.channelID == joinedChannel.id && soleChannelSend.subscriptionID == nil)
        do {
            _ = try outboundSelection(
                taskID: nil,
                explicitChannelID: nil,
                channels: [joinedChannel, ChannelProfile(
                    id: UUID(),
                    origin: invitation.origin,
                    channel: "second-channel",
                    displayName: "second-channel",
                    callsign: "member-test",
                    memberID: "member-test",
                    role: "member",
                    credentialAccount: "test",
                    lastViewedMessageID: nil
                )],
                subscriptions: []
            )
            preconditionFailure("unbound multi-channel send selected an implicit channel")
        } catch {}
        let reconciledChannel = try reconciledChannelProfile(joinedChannel, authenticatedMemberID: "server-member")
        precondition(reconciledChannel.memberID == "server-member" && reconciledChannel.callsign == joinedChannel.callsign)
        do {
            _ = try reconciledChannelProfile(joinedChannel, authenticatedMemberID: "")
            preconditionFailure("empty authenticated member id was accepted")
        } catch {}
        let block = CodexConfigEditor.managedBlock(sidecar: "/Applications/Pijoo.app/Contents/MacOS/rogerthat-sidecar", binding: "/tmp/state-v2.json")
        let installed = try CodexConfigEditor.installing(block: block, into: "model = \"gpt-5\"\n")
        precondition(installed.contains(managedConfigStart))
        let removed = try CodexConfigEditor.removingManagedBlock(from: installed)
        precondition(removed == "model = \"gpt-5\"\n")
        let request = try LocalSendRequest.decode(Data(#"{"version":2,"operation":"send","source":{"provider":"codex","conversationId":"01900000-0000-7000-8000-000000000001"},"message":"hello","mentions":["member-a","member-b"]}"#.utf8))
        precondition(request.message == "hello" && request.mentions == ["member-a", "member-b"])
        let inspectRequest = try LocalSendRequest.decode(Data(#"{"version":2,"operation":"inspect_message_source","source":{"provider":"codex","conversationId":"01900000-0000-7000-8000-000000000001"}}"#.utf8))
        precondition(inspectRequest.operation == "inspect_message_source")
        let readyRequest = try LocalSendRequest.decode(Data(#"{"version":2,"operation":"mcp_ready","client_version":"0.3.0-beta.16"}"#.utf8))
        precondition(readyRequest.clientVersion == "0.3.0-beta.16" && readyRequest.source == nil)
        precondition(requiresCodexRestart(configured: true, appVersion: "beta.16", loadedMCPVersion: nil))
        precondition(requiresCodexRestart(configured: true, appVersion: "beta.16", loadedMCPVersion: "beta.15"))
        precondition(!requiresCodexRestart(configured: true, appVersion: "beta.16", loadedMCPVersion: "beta.16"))
        precondition(!requiresCodexRestart(configured: false, appVersion: "beta.16", loadedMCPVersion: nil))
        precondition(generatedLocalNickname(id: UUID(uuidString: "12345678-0000-0000-0000-000000000000")!) == "Pijoo用户-123456")
        precondition(codexIntegrationReadiness(configured: false, appVersion: "beta.16", loadedMCPVersion: nil) == .notConfigured)
        precondition(codexIntegrationReadiness(configured: true, appVersion: "beta.16", loadedMCPVersion: nil) == .awaitingRestart)
        precondition(codexIntegrationReadiness(configured: true, appVersion: "beta.16", loadedMCPVersion: "beta.15") == .versionMismatch)
        precondition(codexIntegrationReadiness(configured: true, appVersion: "beta.16", loadedMCPVersion: "beta.16") == .ready)
        let recoveryChannelID = UUID(uuidString: "12345678-0000-0000-0000-000000000000")!
        let recoveryRecords = [1, 2, 3].map {
            ChannelMessageRecord(channelID: recoveryChannelID, messageID: String($0), direction: .inbound, from: "peer", to: "all", text: "m\($0)", at: Double($0), state: .received)
        }
        precondition(pendingRecoveryMessages(after: 1, records: recoveryRecords).map(\.messageID) == ["2", "3"])
        var visibleRecords = upsertedMessages(recoveryRecords[1], into: [recoveryRecords[0]])
        precondition(visibleRecords.map(\.messageID) == ["1", "2"])
        var deliveredRecord = recoveryRecords[1]
        deliveredRecord.state = .delivered
        visibleRecords = upsertedMessages(deliveredRecord, into: visibleRecords)
        precondition(visibleRecords.count == 2 && visibleRecords.last?.state == .delivered)
        let listenURL = channelListenURL(
            base: URL(string: "https://example.com/api/channels/test")!,
            cursor: 123
        )
        precondition(listenURL.absoluteString == "https://example.com/api/channels/test/listen?timeout=30&since=123")
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
            messageID: "42",
            mentions: "@张三、@李四"
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
            _ = try LocalSendRequest.decode(Data(#"{"version":2,"operation":"send","source":{"provider":"codex","conversationId":"01900000-0000-7000-8000-000000000001"},"message":"hello","mentions":["all","member-a"]}"#.utf8))
            preconditionFailure("mixed all/member mentions were accepted")
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
        precondition(bridgeRecoveryClearsError(kind: "connection", state: "stopped"))
        precondition(bridgeRecoveryClearsError(kind: "delivery", state: "delivered"))
        precondition(!bridgeRecoveryClearsError(kind: "delivery", state: "connected"))
        precondition(!bridgeRecoveryClearsError(kind: "delivery_outcome_unknown", state: "connected"))
        precondition(!bridgeErrorShouldReplace(current: "delivery", incoming: "connection"))
        precondition(bridgeErrorShouldReplace(current: "connection", incoming: "delivery"))
        precondition(!bridgeErrorAffectsGlobalHealthImmediately("connection"))
        precondition(bridgeErrorAffectsGlobalHealthImmediately("delivery"))
        precondition(isDisconnectedHostError("Codex task abc needs rebind: open it once"))
        precondition(isDisconnectedHostError("Could not connect to ChatGPT Desktop IPC (/tmp/ipc.sock)"))
        precondition(!isDisconnectedHostError("Host delivery outcome is unknown"))
        precondition(clientLogField("a\tb\nc") == "a b c")
        precondition(isCancellationError(CancellationError()))
        precondition(isCancellationError(URLError(.cancelled)))
        precondition(!isCancellationError(URLError(.timedOut)))

        let subscriptionID = UUID()
        let channelID = UUID()
        let taskID = UUID()
        let disconnectedTask = TaskBinding(id: taskID, provider: "codex", conversationID: "01900000-0000-7000-8000-000000000001")
        let disconnectedSubscription = ChannelSubscription(
            id: subscriptionID,
            channelID: channelID,
            taskID: taskID,
            enabled: true,
            template: defaultMessageTemplate,
            selfMessagePolicy: .excludeMember,
            defaultSend: false
        )
        let disconnectedState = HostConversationRuntimeState(connected: false, workspace: nil, permission: "unknown")
        precondition(disconnectedHostTaskIDs(
            tasks: [disconnectedTask],
            subscriptions: [disconnectedSubscription],
            states: [taskID: disconnectedState]
        ) == [taskID])
        var pausedSubscription = disconnectedSubscription
        pausedSubscription.enabled = false
        precondition(disconnectedHostTaskIDs(
            tasks: [disconnectedTask],
            subscriptions: [pausedSubscription],
            states: [taskID: disconnectedState]
        ).isEmpty)
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
        precondition(manuallyStopped.receiveScope == nil)
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
            ),
            mention: MessageMention(
                kind: "members",
                members: [
                    MentionedMember(memberID: "member-a", memberName: "张三"),
                    MentionedMember(memberID: "member-b", memberName: "李四"),
                ]
            )
        )
        precondition(messageA.source?.provider == "codex")
        precondition(messageA.source?.conversationID == "01900000-0000-7000-8000-000000000001")
        precondition(messageA.mention?.displayText == "@张三、@李四")
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
        let skillDestination = socketDirectory.appendingPathComponent("codex-skills/pijoo", isDirectory: true)
        try FileManager.default.createDirectory(at: skillSource, withIntermediateDirectories: true)
        try "---\nname: pijoo\n---\n".write(
            to: skillSource.appendingPathComponent("SKILL.md"),
            atomically: true,
            encoding: .utf8
        )
        let integrationBlock = CodexConfigEditor.managedBlock(sidecar: "/Applications/Pijoo.app/sidecar", binding: "/tmp/state.json")
        try "model = \"gpt-5\"\n".write(to: configURL, atomically: true, encoding: .utf8)
        try CodexIntegrationInstaller.install(
            configURL: configURL,
            block: integrationBlock,
            skillSource: skillSource,
            skillDestination: skillDestination
        )
        precondition(PijooSkillInstaller.isInstalled(source: skillSource, destination: skillDestination))
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
        precondition(!PijooSkillInstaller.isManagedLink(source: skillSource, destination: skillDestination))
        let previousApp = socketDirectory.appendingPathComponent("Previous Pijoo.app", isDirectory: true)
        let previousSkill = previousApp.appendingPathComponent("Contents/Resources/skills/pijoo", isDirectory: true)
        try FileManager.default.createDirectory(at: previousSkill, withIntermediateDirectories: true)
        try "---\nname: pijoo\n---\n".write(
            to: previousSkill.appendingPathComponent("SKILL.md"),
            atomically: true,
            encoding: .utf8
        )
        let previousInfo = try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleIdentifier": "dev.pijoo.menubar"],
            format: .xml,
            options: 0
        )
        try previousInfo.write(to: previousApp.appendingPathComponent("Contents/Info.plist"))
        try FileManager.default.createSymbolicLink(at: skillDestination, withDestinationURL: previousSkill)
        let retargeted = try PijooSkillInstaller.install(
            source: skillSource,
            destination: skillDestination,
            allowRetargetFromBundleIdentifier: "dev.pijoo.menubar"
        )
        precondition(retargeted?.standardizedFileURL == previousSkill.standardizedFileURL)
        precondition(PijooSkillInstaller.isInstalled(source: skillSource, destination: skillDestination))
        try PijooSkillInstaller.restoreLink(
            destination: skillDestination,
            current: skillSource,
            previous: previousSkill
        )
        try CodexIntegrationInstaller.install(
            configURL: configURL,
            block: integrationBlock,
            skillSource: skillSource,
            skillDestination: skillDestination,
            allowSkillRetargetFromBundleIdentifier: "dev.pijoo.menubar"
        )
        precondition(PijooSkillInstaller.isInstalled(source: skillSource, destination: skillDestination))
        try CodexIntegrationInstaller.remove(
            configURL: configURL,
            skillSource: skillSource,
            skillDestination: skillDestination
        )
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
