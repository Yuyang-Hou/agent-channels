# Verification

Status: 0.3.0-beta.2 prerelease published. 0.3.0-beta.14 local candidate adds the product Skill, editable
Markdown external-message card, replay recovery, on-demand conversation search with corrected overlay stacking, member identity recovery, client log export and a fixed internal signing
identity; automated gates pass. Clean-install, two-machine, real-Host, security inspection and beta.14
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
- MCP tests prove the tool table contains exactly send/list/subscribe/unsubscribe/get_settings/update_settings/inspect_message_source;
  every tool uses `_meta.threadId` as its task source, and missing, wrong-type or malformed metadata is rejected
  before the App socket. App routing rejects unbound or ambiguous targets before Channel Service access, while
  a paused receive Subscription remains eligible for explicit or unique-default outbound sending.
- MCP boundary tests prove it never opens a channel stream, consumes inbound messages, persists history or
  invokes a Host Connector; those receive-side effects remain App-owned.
- Template tests cover the editable full-message template, all five allowed variables, single-pass substitution,
  default Markdown blockquote continuation, invalid variables and size limits.
- Self-message tests cover exact endpoint suppression and both same-member policies.

## 2026-08-24 Send Status And Full Template Update

- App messages show no transient state during the first second; if still pending at 1 second, the row shows
  `发送中` until the existing reliable `accepted` / `failed` / `unknown` outcome replaces it.
- The current external-message card is now the complete default Subscription template. Title, source row,
  body and blockquote Markdown are editable; the Connector adds no fixed visible wrapper outside the template.
- Existing local Subscriptions are not migrated because this Beta has not opened to users; recreate them to use the new default.
- `npm run build`, all 11 server test files / 92 tests, Swift compilation and the macOS v2 self-test pass.
- Local `Agent-Channels-0.3.0-beta.8-arm64.dmg` was rebuilt with the stable Beta signing identity; Swift self-test,
  `codesign --verify --deep --strict` and `hdiutil verify` pass. SHA-256 is
  `00870ff657f94db461cfb78a1f9142b8378202642bb2996d66e22d32a6e76a45`.
- The rebuilt App was not installed or exercised through the real UI, so both interactions still require real acceptance.

## 2026-08-24 Template Name Resolution

- `{channel_name}` is now supplied from the App's saved channel display name; the internal channel id remains the fallback.
- `{sender_name}` uses the service-owned member nickname. Railway production deployment
  `f6119103-4270-4e88-9d6b-7d95add10c8a` built commit `00b7f87`, passed its healthcheck and reached `SUCCESS`;
  the public `/healthz` endpoint returned `ok` after cutover.
- No production test channel was created because channels have no deletion endpoint. A new message through an
  existing channel remains the required visible acceptance for the rendered sender nickname.
- All 11 server test files / 93 tests, TypeScript typecheck/build, strict OpenSpec validation and diff checks pass.
- Live message `1787569685428` proved the deployed service now renders sender nickname `侯老师`. Its channel id
  came from an orphan pre-update listener while the installed listener already carried `--channel-name 产品协助`.
- The stale listener was stopped; the enabled Subscription automatically recovered with exactly one App-owned
  listener and cursor `1787569685428`. Normal App termination and update handoff now stop all supervised sidecars.

## 2026-08-24 Message Source Variable

- Messages carry `source(provider, conversation_id, label)`; `{message_source}` displays only label, while the
  local timeline stores the full reference and exposes source conversation-id copy from the message context menu.
- `npm run build`, all 11 server test files / 94 tests, Swift typecheck, strict OpenSpec validation and diff checks pass.
- No App package, server deployment or real cross-device message was changed during this source verification.
- The beta.10 product Skill recognizes editable inbound titles containing either `频道消息` or `Agent Channels`.
- Each Subscription row exposes an `打开会话` button that opens its exact `codex://threads/<id>` binding through macOS.
- The working-tree sidecar can search the live Codex index by title or id while excluding internal subagent/reviewer sessions. Titles remain transient search data; TaskBinding persists only provider and conversation id, and Subscription rows use the shortened id.

## 2026-08-24 On-demand Message Source Inspection

- `inspect_message_source` is the seventh task-scoped MCP tool. It has no model-supplied target arguments and
  uses protected `_meta.threadId` to ask the App for that TaskBinding's latest successful Channel delivery.
- The App joins existing SubscriptionDelivery and LocalMessage JSONL records; it does not read Codex history,
  change the editable template or add visible source text. A missing record remains unknown rather than proof
  of manual user input.
- All 11 server test files / 95 tests, TypeScript typecheck/build, Swift warnings-as-errors typecheck and focused
  self-test, strict OpenSpec validation and diff checks pass. No App package was built, installed or published.

## 2026-08-25 On-demand Conversation Search

- “转发到会话”不再预载最近 30 条会话；只有非空关键词才会搜索全部未归档用户主会话索引，结果仍排除 subagent/reviewer。
- 匹配结果以搜索框下方按内容高度收缩的浮层展示，整行点选即绑定，不再挤压下方页面布局。
- Swift warnings-as-errors typecheck、OpenSpec strict validation 与 diff checks 通过；未构建、安装或发布 App 包。

## 2026-08-25 Beta.12 Local Package

- `codex-search-conversations` commit `5868088` was merged into local `main`; the package includes on-demand floating conversation results and aligned invitation/member rows.
- `macos/build/Agent-Channels-0.3.0-beta.12-arm64.dmg` is 28,489,756 bytes with SHA-256 `1e908db89ab1d41f2dd498d2eae60f3cdfea589455351661915b2d0170dc4903`.
- The mounted DMG contains release version `0.3.0-beta.12`, bundle build `12`, a deep/strict-valid fixed internal signature and MCP `serverInfo.version` `0.3.0-beta.12`; `hdiutil verify` passes. It is not notarized, installed, pushed or published.

## 2026-08-25 Opaque Search Overlay And Member Identity Recovery

- Conversation search results and empty-state feedback now use the opaque system window background instead of translucent material, so content below the overlay does not show through.
- A read-only production member lookup confirmed the saved local owner id had drifted from the Member authenticated by the same Keychain credential. Successful send, channel-feed and Subscription-listener joins now atomically persist the authenticated `member_id` while still requiring a non-empty server `endpoint_id`.
- Swift warnings-as-errors typecheck, the focused self-test, strict OpenSpec validation and diff checks pass. No App package was rebuilt or installed.

## 2026-08-25 Client Diagnostic Log Export

- SwiftUI and URLSession cancellation now ends history, member and invitation refreshes silently instead of becoming a persistent global health error.
- The App keeps two local 1 MB client diagnostic logs for lifecycle, UI errors, channel reconnects and Subscription listener failures; it does not log channel text, invitation tokens or member credentials.
- Settings exposes “导出客户端日志…” and combines the previous and current rolling logs into one user-selected `.log` file without deleting the originals.
- Swift warnings-as-errors typecheck, the focused macOS self-test, strict OpenSpec validation (4/4) and diff checks pass. No App package was built, installed or published.

## 2026-08-25 Beta.13 Local Package

- `fix-conversation-overlay-binding` commit `07c4325` was merged into local `main` as `2c1ba16`; the package includes the opaque conversation overlay, authenticated Member identity recovery, cancellation handling and exportable client diagnostics.
- `macos/build/Agent-Channels-0.3.0-beta.13-arm64.dmg` is 28,506,272 bytes with SHA-256 `1a0bbebec1e8b583f06f7c68135044fbb2baec03ff161ae80ed10e0b5dc57d24`.
- The mounted DMG contains release version `0.3.0-beta.13`, bundle build `13`, a deep/strict-valid fixed internal signature and MCP `serverInfo.version` `0.3.0-beta.13`; `hdiutil verify` passes. It is not notarized, installed, pushed or published.

## 2026-08-25 Conversation Search Overlay Stacking

- The search action row now has a higher local z-index than its following explanatory text, so the opaque result overlay covers that sibling instead of letting the later-drawn label appear above it.
- This is a source-only layout correction; no App package was rebuilt or installed.

## 2026-08-25 Beta.14 Local Package

- `fix-conversation-search-layer` commit `ef21003` was merged into local `main` as `d80ce43`; the package includes the corrected conversation-search overlay stacking.
- `macos/build/Agent-Channels-0.3.0-beta.14-arm64.dmg` is 28,506,699 bytes with SHA-256 `c28b85da0b2dddd50f8798d3eeda35ff09965a0d37ae26ff1d649c31c0ff9088`.
- The mounted DMG contains release version `0.3.0-beta.14`, bundle build `14`, a deep/strict-valid fixed internal signature and MCP `serverInfo.version` `0.3.0-beta.14`; `hdiutil verify` passes. It is not notarized, installed, pushed or published.

## 2026-08-24 Configurable Invitations

- Owner invitation creation accepts an optional 64-character label, 1–100 uses and 1–720 hours in the App;
  the service accepts 60 seconds through 30 days and persists use count plus derived active, exhausted, expired
  or revoked state without storing the raw token.
- The owner-only invitation list never returns raw tokens. Revoke is idempotent and preserves the record; it
  blocks later redemptions without changing Members already created from the invitation.
- A concurrent three-request redemption test for a two-use invitation produces exactly two Members and one
  rejection. Expiry, validation, independent credentials, owner-only list/create and replay are covered.
- All 11 server test files / 93 tests, TypeScript typecheck/build, Swift typecheck and focused macOS self-test,
  strict OpenSpec validation and diff checks pass. The rebuilt App was not installed or exercised through the
  real UI in this source-only change.

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
4. From both tasks, exercise all seven MCP tools, then complete App → task, task → App and task → task sends.
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
- Server messages may contain sender-declared source provider/conversation id/label for traceability, but no
  target TaskBinding, Host path, workspace, task snapshot or credential; source metadata never selects a target.
- MCP App requests contain only protocol version, operation-specific arguments and local source context;
  channel credentials, inbound payloads and local history do not appear in model content, argv, environment
  or MCP process memory.
- 0.2 `binding.json` and Keychain entries remain untouched during 0.3 clean-start detection.

## Release Gate

GitHub prerelease `v0.3.0-beta.2` is public, non-draft and contains the 28,677,748-byte arm64 DMG whose GitHub
digest matches the SHA-256 above. Pre-launch distribution remains Beta-only. Until the real-Host and security
checks pass, the fixed-internal-signed, non-notarized beta.8 package remains an acceptance build: no stable
release and no production-ready claim. Existing 0.2 Release records remain historical facts.
