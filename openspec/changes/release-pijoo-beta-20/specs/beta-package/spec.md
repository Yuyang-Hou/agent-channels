# Beta Package Specification

## ADDED Requirements

### Requirement: Traceable Beta 20 Package

Beta.20 DMG MUST 从已推送 `main` 的确定提交构建，使用 Developer ID 签名，并携带与文件名一致的
App 与 MCP 版本。

#### Scenario: Maintainer audits the package

- **WHEN** 维护者检查 beta.20 DMG
- **THEN** 可以核对源提交、DMG SHA-256、App 深度签名、MCP 版本、Pijoo Skill 和只读会话状态

### Requirement: Notarized Public Beta

公开 Beta MUST 获得 Apple notarization Accepted、staple 并通过 Gatekeeper，GitHub prerelease
MUST 指向构建源码提交并只附带校验一致的 beta.20 arm64 DMG。

#### Scenario: Tester downloads the public prerelease

- **WHEN** 测试者下载并打开 beta.20 GitHub prerelease DMG
- **THEN** DMG 与其中的 Pijoo App 都通过签名、staple 与 Gatekeeper 校验，且 MCP/Skill 与发布记录一致
