# Proposal: Automate Pijoo Beta Release

## Why

当前每次 Beta 都依赖人工重复测试、改版本、构建、签名、公证和上传，容易遗漏 build number、
公证后摘要或公开资产回下载校验。仓库也没有 PR CI，合并前缺少统一门禁。

## What Changes

- PR 与 `main` push 统一执行 server、OpenSpec、Swift 自测和 arm64 App/DMG 构建校验。
- `main` push 根据最新正式 Beta tag 计算下一 `beta.N`，保存七天候选 DMG，但不公开发布。
- 维护者人工触发受保护的 release workflow；流水线从 `origin/main` 精确提交重新验证，完成
  Developer ID 签名、Apple notarization、staple、Gatekeeper、GitHub prerelease 和公开回下载校验。
- Release Notes 自动汇总上一版本以来合并的 PR，并保留源码、摘要与 Apple 公证信息。
- Beta 序号同时成为 `CFBundleVersion`，避免 App 版本与 bundle build 漂移。

## Decisions

- 合并不会直接公开发版；人工触发是发布授权边界。
- 签名与 Apple 凭据只进入 `release` Environment，不进入 PR workflow。
- 版本以最新 `vX.Y.Z-beta.N` tag 为准，不由 workflow 回写或自动提交源码。

## Non-goals

- 自动发布稳定版、Intel 包或 App Store 包。
- 自动合并 PR、修改 branch protection 或代替真实双用户产品验收。
- 失败后自动删除、覆盖或重新发布已有 GitHub Release。
