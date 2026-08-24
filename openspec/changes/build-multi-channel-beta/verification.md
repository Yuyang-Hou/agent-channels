# Verification

Status: 0.3.0-beta.2 prerelease published. 0.3.0-beta.8 local candidate adds the product Skill, compact
Markdown external-message card, replay recovery, unified main-window interaction and a fixed internal signing
identity; automated gates pass. Clean-install, two-machine, real-Host, security inspection and beta.8
publication remain pending.

## Post-candidate Working Tree

- 添加频道弹窗已改为创建时只填频道名称、加入时只填邀请口令；“我的昵称”在设置中全局维护，
  App 的所有 join/send 路径显式使用该昵称，服务端持久化并随邀请返回频道名称。
- 双击频道详情标题与现有编辑按钮复用同一改名流程。
- `npm test` 通过 11 个文件 / 92 项测试；TypeScript typecheck、Swift 编译与本机 self-test、
  `openspec validate --strict --all` 和 `git diff --check` 通过。
- 下方 beta.8 DMG 早于这些工作区修改；本轮没有重新构建、签名或发布 DMG。

## Next Beta Local Candidate

- Artifact: `macos/build/Agent-Channels-0.3.0-beta.8-arm64.dmg`
- SHA-256: `ac9b856570a3ff7261d0f9c5e842a0a31f3412a118a2a9398166f88b33953af0`
- Size: 28,738,735 bytes; signed by the fixed internal `Agent Channels Beta Signing` identity and not notarized.
- The beta.8 App and sidecar retain the same designated requirements as the two independently built beta.7
  candidates, anchored to certificate
  SHA-1 `7D4A076571734A0E816D5C522FF9A7286D1C5A50`; the App identifier is
  `com.agentchannels.menubar` and the sidecar identifier is `com.agentchannels.rogerthat-sidecar`.
- The packaged Swift source hash was unchanged throughout compilation. The reviewed UI includes the compact
  menu panel, focused single main window, sidebar Settings destination, tabbed channel detail, grouped message
  rows, member action menu and collapsible Subscription controls; no macOS 13 compatibility blocker was found.
- `npm test` passes 11 files / 92 tests; typecheck, build, Swift self-test, codesign, DMG verification and
  `openspec validate --strict --all` pass.
- The App bundle contains the validated static Agent Channels Skill. Its installer self-test covers first install,
  idempotent repair, managed removal, unreadable Codex config, combined-operation preflight and refusal to
  overwrite or remove an unmanaged same-name directory or foreign link.
- The unified Connector formatter renders only the fixed title, channel, sender, message id and body; the default
  body is exactly `{message_text}`. CRLF, blank lines, headings and code fences remain inside the blockquote, and
  template substitutions are single-pass.
- Integration tests prove an abnormal SSE body failure reconnects from the latest handled message id, terminal
  replay does not call the Host twice, and unresolved delivery does not call the Host or advance the cursor.

## Current Beta Candidate

- Artifact: `macos/build/Agent-Channels-0.3.0-beta.8-arm64.dmg`
- SHA-256: `cff67d8f4e7015252240730b042f22bb6193ae3fb4675721c262190678898b44`
- Signing: fixed `Agent Channels Beta Signing` identity; not Developer ID signed or notarized.
- Local package checks: `hdiutil verify` and `codesign --verify --deep --strict` pass; the App and mounted DMG
  candidate have the same designated requirement, and the embedded MCP lists the six task-scoped tools.
- The Settings toggle, startup/daily background download, pending-update handoff and packaged native update helper
  compile and pass focused self-tests. The helper rejects symlinked bundles, wrong Bundle IDs or versions,
  invalid signatures and mismatched designated requirements; replacement retains a backup for failure recovery.
- A real beta.7-to-beta.8 replacement and the mismatched-signer failure path remain unchecked; no published
  Release or installed App was changed during this source verification.

## Automated Gates

- `npm test`: 11 files and 92 tests pass with the new member, multi-channel and replay-recovery paths.
- `npm run typecheck` and `npm run build` pass.
- The macOS candidate build completes its focused Swift self-test before compiling and packaging the App.
- The legacy 0.2 detection banner has a persistent dismiss control; dismissing it does not alter legacy data or
  hide the detection status in Settings.
- The menu-bar panel contains only overall status, the main-window entry, listen pause/resume and quit. Settings
  render in the main-window sidebar; opening reuses, deminiaturizes and focuses the normal main window.
- `openspec validate --strict --all`: 4 items pass.
- Service tests prove member credentials are channel-scoped, owner-only mutations are enforced, and remove or
  ban invalidates existing sessions and streams, clears queued SSE messages and stops further delivery.
- App self-tests cover enabled Subscription restart recovery and terminal per-channel revocation handling; the
  latter stops the channel feed and all of that channel's Subscription sidecars without affecting other channels.
- Local-store/runtime tests prove the App acknowledges `record_received` only after committing LocalMessage
  and SubscriptionDelivery, Connector invocation happens after that ack, and persistence failure leaves the
  Host untouched.
- MCP tests prove the tool table contains exactly send/list/subscribe/unsubscribe/get_settings/update_settings;
  every tool uses `_meta.threadId` as its task source, and missing, wrong-type or malformed metadata is rejected
  before the App socket. App routing rejects unbound or ambiguous targets before Channel Service access, while
  a paused receive Subscription remains eligible for explicit or unique-default outbound sending.
- MCP boundary tests prove it never opens a channel stream, consumes inbound messages, persists history or
  invokes a Host Connector; those receive-side effects remain App-owned.
- Template tests cover all four allowed variables, invalid variables, single-pass substitution, Markdown
  blockquote confinement and size limits.
- Self-message tests cover exact endpoint suppression and both same-member policies.

## Live Service Gate

- Railway production deployment `2531a50f-116b-4d8c-9f30-e01af302137d` is `SUCCESS`; `/healthz` passed before cutover.
- Public API acceptance on `https://rogerthat-production-fff6.up.railway.app` used newly created 0.3 test channels only.
- Channel `brisk-xerus-386d` proved the minimal v2 create response, cross-channel credential rejection,
  one-use invitation, server-owned sender identity, history, member list, remove, ban, unban and unaffected owner access.
- Channel `olive-raven-0689` proved an already-open SSE receives `member_revoked`, closes after ban and rejects the
  invalidated session afterward.

## Required Real-Host Acceptance

Use two independent users on two Apple Silicon Macs, two newly created 0.3 channels and two real Codex
tasks. Do not reuse or import 0.2 data.

1. Join both channels, exchange App messages, restart both Apps and verify channel isolation, local history,
   unread state and stable message ids.
2. Capture real `tools/call params._meta.threadId` for task A and B; each must equal its own
   `codex://threads/...` UUID. Source-code inspection alone does not pass this gate.
3. Configure at least three task-channel Subscriptions, including one task subscribed to both channels and
   one channel subscribed by both tasks.
4. From both tasks, exercise all six MCP tools, then complete App → task, task → App and task → task sends.
   No message or configuration mutation may use the currently selected UI channel or most recently active
   task as an implicit route; task sends must also work before either task receives a message.
5. In a new task, verify the installed Skill explains App-only creation, invitation, member, history and
   TaskBinding flows; it must not invent MCP tools or poll for messages.
6. Verify the default template and a custom template in real turns. Verify exact task self-send creates no
   echo turn and both same-member policies behave independently.
7. Remove one online member, then prove its existing stream closes and old credential cannot send or
   reconnect. Repeat with ban and unban while another member remains online.
8. Interrupt one Subscription's network and make another Host unavailable; prove errors, cursors and
   unknown-result pause remain isolated while unaffected Subscriptions continue.
9. Leave channels idle and prove no Codex turn is created.

## Data And Security Inspection

- Keychain contains independent member credentials; local store contains only credential references.
- Server records contain member and opaque endpoint ids but no Codex thread id, Host path, workspace or task
  snapshot.
- MCP App requests contain only protocol version, operation-specific arguments and local source context;
  channel credentials, inbound payloads and local history do not appear in model content, argv, environment
  or MCP process memory.
- 0.2 `binding.json` and Keychain entries remain untouched during 0.3 clean-start detection.

## Release Gate

GitHub prerelease `v0.3.0-beta.2` is public, non-draft and contains the 28,677,748-byte arm64 DMG whose GitHub
digest matches the SHA-256 above. Pre-launch distribution remains Beta-only. Until the real-Host and security
checks pass, the fixed-internal-signed, non-notarized beta.8 package remains an acceptance build: no stable
release and no production-ready claim. Existing 0.2 Release records remain historical facts.
