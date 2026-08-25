# Tasks

## 1. Release Readiness

- [x] 合并并提交仓库全部本地代码，严格校验 OpenSpec、测试、类型和 diff
- [x] 版本提升为 `0.3.0-beta.19` / build `19`，推送确定的 `main` 提交

## 2. Package

- [x] 从已推送提交构建 Developer ID 签名的 `Pijoo-0.3.0-beta.19-arm64.dmg`
- [x] 校验 DMG、App 与内嵌可执行文件签名以及产物可挂载
- [x] 校验内嵌 MCP 版本、Pijoo Skill、源提交和 SHA-256

## 3. Publication Boundary

- [x] Apple notarization Accepted，staple 后通过 Gatekeeper 验证
- [x] 创建 `v0.3.0-beta.19` GitHub prerelease 并上传 DMG
- [x] 回下载公开资产，复核 SHA-256、签名、staple、Gatekeeper、MCP 与 Skill
- [x] 明确记录本轮未安装到 `/Applications`
