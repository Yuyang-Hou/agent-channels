# Proposal: Release Pijoo 0.3.0 Beta 18

## Why

Pijoo 已完成首次设置、频道入口与提示层级优化，需要发布可由 macOS Gatekeeper 直接验证的新 Beta。

## What Changes

- 从 `main` 的确定提交构建 `Pijoo-0.3.0-beta.18-arm64.dmg`。
- 使用 Developer ID、hardened runtime 与安全时间戳签名 App、内嵌可执行文件和 DMG。
- 通过 Apple notarization、staple 与 Gatekeeper 验证后发布 GitHub prerelease。
- 记录提交、公证 ID、产物校验和与发布地址。

## Non-goals

- 正式稳定版、Mac App Store 或 Intel 构建。
- 新增首次设置和频道体验之外的产品能力。
