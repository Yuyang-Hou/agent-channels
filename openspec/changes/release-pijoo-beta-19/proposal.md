# Proposal: Release Pijoo 0.3.0 Beta 19

## Why

Pijoo 已合并新建专属 Codex 会话、频道多人 @ 与仅接收 @我的能力，需要生成可追溯的新版本安装包，不能覆盖已发布的 beta.18。

## What Changes

- 将 App 与内嵌 MCP 版本提升为 `0.3.0-beta.19`，bundle build 提升为 `19`。
- 从已推送 `main` 的确定提交构建 Developer ID 签名的 Apple Silicon DMG。
- 提交 Apple notarization，Accepted 后 staple，并校验 Gatekeeper。
- 创建 GitHub prerelease、上传 DMG，并回下载校验公开资产、内嵌 sidecar/MCP 版本与 Pijoo Skill。

## Non-goals

- 安装到 `/Applications` 或自动替换用户当前 App。
- Intel 构建或稳定版发布。
