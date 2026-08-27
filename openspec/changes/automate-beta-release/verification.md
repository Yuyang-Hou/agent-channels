# Verification

Status: complete; GitHub Environment、hosted CI 与首次正式发布均已验证。

## Local checks

- `./macos/next-beta-version.sh --self-test`: passed，当前结果为 `0.3.0-beta.21`。
- ad-hoc `Pijoo-0.3.0-beta.21-arm64.dmg` 构建并通过 `verify-package.sh`；包内 release/build
  为 `0.3.0-beta.21` / `21`，MCP 版本与 Skill 一致。
- server：11 files / 101 tests passed；typecheck 与 build passed。
- `openspec validate --strict --all`：15 passed；workflow YAML parse 与 `git diff --check` passed。
- Swift 与 package 验证因本地沙箱禁止 Unix socket，已在系统能力环境重跑通过。

## Hosted checks

- `checkout v7.0.1`、`setup-node v7.0.0` 与 `upload-artifact v7.0.1` 均固定到官方精确提交，
  其 `action.yml` 声明使用 Node 24 runtime。
- GitHub `release` Environment 已配置审批规则和五项签名、公证 secrets。
- PR #3 与 `main` CI 均通过；`main` run `33036692439` 上传了七天候选 artifact。
- `0.3.0-beta.21` 已完成临时 Keychain、Apple notarization、draft/public asset 回下载链路；
  最终 SHA-256 为 `db87fb4abaff8ce67e3c4539f77b1f95f737facf059948d30fc2cc8e10b73c06`，
  notarization submission 为 `af6ee3ea-d616-4839-b24f-8f87ce5844c4`。
- GitHub Release Notes API 已按 `v0.3.0-beta.20...v0.3.0-beta.21` 生成 PR #1、#2、#3
  更新列表和完整对比链接，并与构建验证信息合并。

## macOS 26 appearance regression

- 正式 `beta.20` App 的 Mach-O `LC_BUILD_VERSION` 记录 SDK `26.1`；正式 `beta.21` 记录 SDK `14.5`。
- macOS `26.1` 会为旧 SDK 产物保留旧兼容外观；问题来自 hosted runner 回退，而不是用户主题设置。
- CI 与 release 已改用 `macos-26`，`verify-package.sh` 会读取 App 可执行文件并拒绝 SDK 主版本低于 26 的包。
