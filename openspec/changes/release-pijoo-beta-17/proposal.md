# Proposal: Release Pijoo 0.3.0 Beta 17

## Why

Pijoo 已完成正式命名，需要一个可供外部测试者直接安装、通过 macOS Gatekeeper 验证的 Beta 包。

## What Changes

- 从 `main` 的确定提交构建 `Pijoo-0.3.0-beta.17-arm64.dmg`。
- 使用 Developer ID、hardened runtime 与安全时间戳签名 App 和内嵌可执行文件。
- 通过 Apple notarization、staple 与 Gatekeeper 验证后发布 GitHub prerelease。
- 记录提交、公证 ID、产物校验和与发布地址。

## Non-goals

- 正式稳定版、Mac App Store 或 Intel 构建。
- 迁移旧 Bundle ID 数据，或重命名现有 GitHub 仓库。
