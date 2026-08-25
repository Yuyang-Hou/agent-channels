# Verification

Status: source rename complete; no App/DMG build, signing, notarization, upload or release performed.

## Evidence

- 产品名称、App/DMG、Bundle ID、Keychain、App Support、MCP、Skill、环境变量、协议标签、
  资源和源码文件已统一为 `Pijoo / pijoo / PIJOO / dev.pijoo`。
- 新源码候选版本为 `0.3.0-beta.17`；旧 beta.16 与更早产物的文件名、签名身份和哈希记录保持原样。
- `openspec validate --strict --all`：6 项通过，0 失败。
- `npm test`：11 个测试文件、97 项测试通过；`npm run typecheck` 通过。
- `plutil -lint macos/Info.plist` 与 `bash -n macos/build-app.sh` 通过。
- `macos/PijooApp.swift` 以 `SELF_TEST` 编译成功；因沙箱禁止 Unix socket，已在沙箱外运行并返回
  `macos v2 self-test ok`。`macos/UpdateHelper.swift --self-test` 编译运行通过。
- 全局查漏只保留：尚未迁移的 GitHub 仓库 URL/API、旧内测签名身份字面值、历史产物与验证记录，
  以及本 change 对旧工作名称的说明。
