# Verification

Status: notarized GitHub prerelease published and public asset verified; not installed locally.

## Release Evidence

- Build source: pushed `main` commit `8c56be6e024e1c5059059b2a97a11bf2a1a59c05`.
- Final stapled artifact: `Pijoo-0.3.0-beta.19-arm64.dmg`, `28,618,880` bytes.
- SHA-256: `8313a0f8dd48c7441fecbe0fe33481904987f3240554d2e22e9477646ca51950`.
- Signing identity: `Developer ID Application: yuyang hou (TX8KDF2W5K)`, certificate SHA-1 `7B8752F02C6FC7C22C71952C7B0665811E5CD320`.
- `hdiutil verify`, DMG signature, mounted App deep/strict signature, sidecar and updater signatures passed; App and embedded executables use Team ID `TX8KDF2W5K` and hardened runtime.
- Mounted App reports release `0.3.0-beta.19`, build `19`; packaged Pijoo Skill exactly matches source.
- Packaged MCP initialize reports `serverInfo.version` `0.3.0-beta.19`, seven tools, `mentions` and `receive_scope` contracts.

## Automated Checks

- Server: 11 files / 100 tests passed; typecheck and build passed.
- macOS App self-test passed after merging dedicated conversation creation and channel mentions.
- `openspec validate --strict --all`: 10 passed; `git diff --check`: passed.

## Public Release Evidence

- Apple notarization submission `dde15a7f-2ba3-402d-9374-a4a3c6d7cb7e` is `Accepted`; `stapler validate` passed.
- DMG and mounted App are both Gatekeeper `accepted`, source `Notarized Developer ID`.
- GitHub prerelease: https://github.com/Yuyang-Hou/pijoo/releases/tag/v0.3.0-beta.19; tag points to build source `8c56be6e024e1c5059059b2a97a11bf2a1a59c05`.
- The public asset was downloaded again and passed SHA-256, size, hdiutil, staple, Gatekeeper, deep/strict signature, source Skill and MCP `0.3.0-beta.19` checks.
- The App remains uninstalled locally.
