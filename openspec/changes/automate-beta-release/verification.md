# Verification

Status: source implementation complete; GitHub Environment and hosted workflow run pending.

## Local checks

- `./macos/next-beta-version.sh --self-test`: passed，当前结果为 `0.3.0-beta.21`。
- ad-hoc `Pijoo-0.3.0-beta.21-arm64.dmg` 构建并通过 `verify-package.sh`；包内 release/build
  为 `0.3.0-beta.21` / `21`，MCP 版本与 Skill 一致。
- server：11 files / 101 tests passed；typecheck 与 build passed。
- `openspec validate --strict --all`：15 passed；workflow YAML parse 与 `git diff --check` passed。
- Swift 与 package 验证因本地沙箱禁止 Unix socket，已在系统能力环境重跑通过。

## External checks pending

- GitHub `release` Environment 需要人工配置审批规则与签名、公证 secrets。
- 当前分支推送后验证 PR workflow；合并后验证七天候选 artifact。
- 首次正式触发验证临时 Keychain、Apple notarization、draft/public GitHub asset 回下载链路。
