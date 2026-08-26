# Verification

## Release Evidence

- Version: `0.3.0-beta.18`
- Build commit: `bf499d87c4c4ce4a2333c95e2cc83c20364817f1`
- Signing identity: `Developer ID Application: yuyang hou (TX8KDF2W5K)`
- Signing certificate SHA-1: `7B8752F02C6FC7C22C71952C7B0665811E5CD320`
- Notarization submission: `dbff2a02-57a3-4666-bb97-48fccabd3368` (`Accepted`)
- Gatekeeper: DMG 与挂载后的 `Pijoo.app` 均为 `accepted / Notarized Developer ID`
- Artifact: `Pijoo-0.3.0-beta.18-arm64.dmg`, `28,571,929` bytes
- SHA-256: `52b8294a3e9b1b759f5deec2f7531abbc86536fbecd589fa6abbe77da063177e`
- Release: https://github.com/Yuyang-Hou/pijoo/releases/tag/v0.3.0-beta.18
- 公开资产已回下载并通过 SHA-256、签名、staple、Gatekeeper、DMG、Skill 与 MCP 版本校验。

## Automated Checks

- `openspec validate --strict --all`: 8 passed
- `npm test`: 11 files / 97 tests passed
- `npm run typecheck`: passed
- Swift App self-test and updater self-test: passed during release build
