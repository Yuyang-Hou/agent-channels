# Verification

Date: 2026-08-21

## Passed

- `npm test`: 10 files, 72 tests passed.
- `npm run typecheck` and `npm run build`: passed.
- `openspec validate --strict --all`: 3 items passed.
- Swift focused self-test and arm64 release compile: passed.
- Packaged STDIO MCP `tools/list` exposes exactly `send_to_channel(message)`; no inbound reference is required.
- Swift self-test covers stable/Beta version ordering, including `beta.10 > beta.2` and stable over same-core Beta.
- Embedded Bun sidecar starts with a clean `PATH=/usr/bin:/bin`; no Node/npm/Codex CLI runtime dependency.
- `codesign --verify --deep --strict`: passed with ad-hoc signature.
- `hdiutil verify`: final DMG checksum valid.
- E3 `AppIcon.icns` contains all ten standard/Retina representations; the no-face template SVG is present in
  the signed App resources.
- Final packaged sidecar performed read-only owner discovery against a real current ChatGPT task without
  creating a turn.
- Packaged sidecar connected to temporary hosted channel `dusty-marten-0ed4`, delivered a real message
  through Desktop IPC to the dedicated acceptance task, and that task completed with
  `MACOS_PACKAGE_HOST_OK`.

Final artifact:

```text
macos/build/Agent-Channels-0.2.0-beta.1-arm64.dmg
SHA-256 b53a7b07c0d6246df83f2c1580d971605f5cf54711a640975ff81c2d5c32cf3f
```

## Still Requires User Acceptance

- Install the DMG on two Apple Silicon Macs and exercise the actual menu UI.
- Confirm the first Keychain read and login-item behavior on each machine.
- Confirm ChatGPT loads the user-approved fixed STDIO MCP after restart.
- Confirm an AI can call `send_to_channel(message)` before receiving any channel message.
- Complete A AI proactive send → B real turn, then B AI proactive send → A real turn.
- Exercise the stable and Beta update buttons against published Releases.

These items remain unchecked in `tasks.md`; this public prerelease is an ad-hoc acceptance candidate,
not a notarized production release.
