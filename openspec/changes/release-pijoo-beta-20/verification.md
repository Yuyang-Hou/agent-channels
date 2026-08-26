# Verification

Status: notarized GitHub prerelease published and public asset verified; not installed locally.

## Release Evidence

- Build source: pushed `main` commit `69eed4099362eaffb11037ac0e3cd5587d2db368`.
- Final stapled artifact: `Pijoo-0.3.0-beta.20-arm64.dmg`, `28,667,140` bytes.
- SHA-256: `eb43c7ca02a8ddd9dd5a90f2ce48d3fc606fcef170ba08666e10071f05bfaae2`.
- Signing identity: `Developer ID Application: yuyang hou (TX8KDF2W5K)`, certificate SHA-1
  `7B8752F02C6FC7C22C71952C7B0665811E5CD320`.
- DMG、App、sidecar 与 updater 签名通过；App 与内嵌可执行文件使用 Team ID `TX8KDF2W5K`
  和 hardened runtime。
- 挂载包内版本为 `0.3.0-beta.20` / build `20`，MCP `serverInfo.version` 同为
  `0.3.0-beta.20`，Pijoo Skill 与源码一致。
- 包内 `host-state` 实际返回当前会话 `connected=true`、目录
  `/Users/hyy/project/agent-channels`、权限 `approve-for-me`。

## Automated Checks

- Server: 11 files / 101 tests passed; TypeScript typecheck and build passed.
- Swift warnings-as-errors typecheck passed.
- `openspec validate --strict --all`: 11 passed; `git diff --check`: passed.

## Public Release Evidence

- Apple notarization submission `f28547e4-5cfc-4173-9641-13dbe467b792` is `Accepted`；
  `stapler validate` 通过。
- DMG 与挂载后 App 均为 Gatekeeper `accepted`，source `Notarized Developer ID`。
- GitHub prerelease: https://github.com/Yuyang-Hou/pijoo/releases/tag/v0.3.0-beta.20；
  tag 指向构建源码提交 `69eed4099362eaffb11037ac0e3cd5587d2db368`。
- 公开资产已重新下载，SHA-256、大小、staple、Gatekeeper、App deep/strict 签名、Skill、MCP
  和只读会话状态均与本地产物一致。
- App 未安装到 `/Applications`。
