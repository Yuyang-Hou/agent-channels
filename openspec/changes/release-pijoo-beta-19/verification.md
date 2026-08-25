# Verification

Status: Developer ID signed package complete; notarization and GitHub prerelease in progress.

## Release Evidence

- Build source: pushed `main` commit `8c56be6e024e1c5059059b2a97a11bf2a1a59c05`.
- Artifact: `macos/build/Pijoo-0.3.0-beta.19-arm64.dmg`, `28,617,148` bytes.
- SHA-256: `987069375b0eea07a6d4b0e5ffa25dfc1ff05fd2b673daf0e7d4054eb8462aa1`.
- Signing identity: `Developer ID Application: yuyang hou (TX8KDF2W5K)`, certificate SHA-1 `7B8752F02C6FC7C22C71952C7B0665811E5CD320`.
- `hdiutil verify`, DMG signature, mounted App deep/strict signature, sidecar and updater signatures passed; App and embedded executables use Team ID `TX8KDF2W5K` and hardened runtime.
- Mounted App reports release `0.3.0-beta.19`, build `19`; packaged Pijoo Skill exactly matches source.
- Packaged MCP initialize reports `serverInfo.version` `0.3.0-beta.19`, seven tools, `mentions` and `receive_scope` contracts.

## Automated Checks

- Server: 11 files / 100 tests passed; typecheck and build passed.
- macOS App self-test passed after merging dedicated conversation creation and channel mentions.
- `openspec validate --strict --all`: 10 passed; `git diff --check`: passed.

## Pending Public Release Evidence

- Apple notarization submission, Accepted status, staple and Gatekeeper evidence.
- GitHub prerelease URL and downloaded public asset verification.
- The App remains uninstalled locally unless separately requested.
