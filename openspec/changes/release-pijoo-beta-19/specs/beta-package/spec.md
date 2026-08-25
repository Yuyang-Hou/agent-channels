# Beta Package Specification

## ADDED Requirements

### Requirement: Traceable Local Beta Package

Beta.19 DMG MUST 从已推送 `main` 的确定提交构建，使用稳定 Developer ID 签名，并携带与文件名一致的 App 与 MCP 版本。

#### Scenario: Maintainer audits the package

- **WHEN** 维护者检查 beta.19 DMG
- **THEN** 可以核对源提交、DMG SHA-256、App 深度签名、内嵌可执行文件、MCP 版本和 Pijoo Skill

### Requirement: Publication Boundary

本地发包 MUST NOT 被描述为已公证或已公开发布，除非 notarization、staple、Gatekeeper 与公开 Release 均另行完成。

#### Scenario: Package is handed off locally

- **WHEN** Developer ID 签名 DMG 构建和本地校验完成
- **THEN** 交付记录明确区分本地签名包与公开公证版本
