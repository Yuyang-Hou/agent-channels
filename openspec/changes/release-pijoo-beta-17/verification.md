# Verification

## Release Evidence

- Version: `0.3.0-beta.17`
- Build commit: `77a57b7c3fdd588bea52d15aa7f3e98399e58a45`
- Signing identity: `Developer ID Application: yuyang hou (TX8KDF2W5K)`
- Final notarization submission: `06159d18-21f3-4280-b7f5-188e3d526e47` (`Accepted`)
- Gatekeeper: DMG 与挂载后的 `Pijoo.app` 均为 `accepted / Notarized Developer ID`
- Artifact: `Pijoo-0.3.0-beta.17-arm64.dmg`, `28,558,263` bytes
- SHA-256: `78c0fbdbea58e195eba002406fd2ffd27661a9a8e4b30866190c88c9033b054a`
- Release: https://github.com/Yuyang-Hou/pijoo/releases/tag/v0.3.0-beta.17
- Published asset was downloaded again and passed SHA-256, code-signing, staple, Gatekeeper and DMG integrity verification.

## Automated Checks

- `openspec validate --strict --all`: 7 passed
- `npm test`: 11 files / 97 tests passed
- `npm run typecheck`: passed
- Swift App self-test and updater self-test: passed during release build
