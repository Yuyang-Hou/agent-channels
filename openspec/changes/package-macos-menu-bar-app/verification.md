# Verification

Date: 2026-08-21

## Passed

- `npm test`: 10 files, 72 tests passed.
- `npm run typecheck` and `npm run build`: passed.
- `openspec validate --strict --all`: 3 items passed.
- Swift focused self-test and arm64 release compile: passed.
- Embedded Bun sidecar starts with a clean `PATH=/usr/bin:/bin`; no Node/npm/Codex CLI runtime dependency.
- `codesign --verify --deep --strict`: passed with ad-hoc signature.
- `hdiutil verify`: final DMG checksum valid.
- Final packaged sidecar performed read-only owner discovery against a real current ChatGPT task without
  creating a turn.
- Packaged sidecar connected to temporary hosted channel `dusty-marten-0ed4`, delivered a real message
  through Desktop IPC to the dedicated acceptance task, and that task completed with
  `MACOS_PACKAGE_HOST_OK`.

Final artifact:

```text
macos/build/Agent-Channels-0.1.0-arm64.dmg
SHA-256 95d36e2ddc6b4f8f3a35bfb87f40c0fc1028511c5d72baa5362d6515df394da6
```

## Still Requires User Acceptance

- Install the DMG on two Apple Silicon Macs and exercise the actual menu UI.
- Confirm the first Keychain read and login-item behavior on each machine.
- Confirm ChatGPT loads the user-approved fixed STDIO MCP after restart.
- Complete B test hello → A AI `reply_to_message` → B real turn.

These items remain unchecked in `tasks.md`; the local build is an acceptance candidate, not a public
release.
