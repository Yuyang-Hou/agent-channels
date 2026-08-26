# Tasks

## 1. Release Readiness

- [x] 审计当前权限与冷会话改动，严格校验 OpenSpec、测试、类型和 diff
- [x] 版本提升为 `0.3.0-beta.20` / build `20`，推送确定的 `main` 提交

## 2. Package

- [x] 从已推送提交构建 Developer ID 签名的 `Pijoo-0.3.0-beta.20-arm64.dmg`
- [x] 校验 DMG、App、内嵌可执行文件、MCP 版本、Pijoo Skill 与实时只读会话状态

## 3. Publication

- [x] Apple notarization Accepted，staple 后通过 Gatekeeper 验证
- [x] 创建 `v0.3.0-beta.20` GitHub prerelease 并上传 DMG
- [x] 回下载公开资产，复核 SHA-256、签名、staple、Gatekeeper、MCP 与 Skill
- [x] 明确记录本轮未安装到 `/Applications`
