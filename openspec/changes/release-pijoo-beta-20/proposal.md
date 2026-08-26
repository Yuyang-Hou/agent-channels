# Proposal: Release Pijoo 0.3.0 Beta 20

## Why

Pijoo 已支持冷会话先绑定、加载后展示当前目录与权限，并允许用户在 App 内修改三档 ChatGPT
会话权限。beta.19 已公开发布，因此本次必须使用新版本产物。

## What Changes

- 将 App 与内嵌 MCP 版本提升为 `0.3.0-beta.20`，bundle build 提升为 `20`。
- 从已推送 `main` 的确定提交构建 Developer ID 签名的 Apple Silicon DMG。
- 提交 Apple notarization，Accepted 后 staple，并校验 Gatekeeper。
- 创建 GitHub prerelease、上传 DMG，并回下载验证公开资产、内嵌 MCP、Skill 与会话状态读取。

## Non-goals

- 安装到 `/Applications` 或自动替换用户当前 App。
- 将权限修改入口暴露给频道、MCP 或 AI。
- Intel 构建或稳定版发布。
