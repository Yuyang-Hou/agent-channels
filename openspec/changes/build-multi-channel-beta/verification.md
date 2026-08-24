# Verification

Status: 0.3.0-beta.2 prerelease published; automated gates pass. Clean-install, two-machine, real-Host,
security inspection and stable-release gates remain pending.

## Current Beta Candidate

- Artifact: `macos/build/Agent-Channels-0.3.0-beta.2-arm64.dmg`
- SHA-256: `45dddf6d410e718b5e3d8353f543f59d79a6918b11c8b57bd5c3552d9232ef3b`
- Signing: ad-hoc local acceptance signature; not Developer ID signed or notarized.
- Local package checks: `hdiutil verify` and `codesign --verify --deep --strict` pass; the embedded MCP lists
  the six task-scoped tools.

## Automated Gates

- `npm test`: 11 files and 89 tests pass with the new member and multi-channel paths.
- `npm run typecheck` and `npm run build` pass.
- The macOS candidate build completes its focused Swift self-test before compiling and packaging the App.
- The legacy 0.2 detection banner has a persistent dismiss control; dismissing it does not alter legacy data or
  hide the detection status in Settings.
- The menu-bar Settings entry uses native `SettingsLink` on macOS 14+ and activates the AppKit settings window
  on macOS 13.
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
- Template tests cover all four allowed variables, invalid variables, untrusted text escaping and size limits.
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
5. Verify the default template and a custom template in real turns. Verify exact task self-send creates no
   echo turn and both same-member policies behave independently.
6. Remove one online member, then prove its existing stream closes and old credential cannot send or
   reconnect. Repeat with ban and unban while another member remains online.
7. Interrupt one Subscription's network and make another Host unavailable; prove errors, cursors and
   unknown-result pause remain isolated while unaffected Subscriptions continue.
8. Leave channels idle and prove no Codex turn is created.

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
checks pass, the ad-hoc, non-notarized package remains an acceptance build: no stable release and no
production-ready claim. Existing 0.2 Release records remain historical facts.
