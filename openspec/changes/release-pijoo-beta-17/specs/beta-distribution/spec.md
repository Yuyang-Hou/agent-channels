# Beta Distribution Specification

## ADDED Requirements

### Requirement: Notarized Developer ID Distribution

正式 Beta MUST 由 Developer ID 签名，App 与内嵌可执行文件 MUST 启用 hardened runtime 和安全时间戳，DMG 容器 MUST 使用 Developer ID 时间戳签名、获得 Apple notarization Accepted 并 staple。

#### Scenario: Tester opens the downloaded DMG

- **WHEN** 测试者从正式发布页下载 Beta DMG
- **THEN** macOS Gatekeeper 接受 DMG 和其中的 Pijoo App

### Requirement: Traceable Beta Artifact

正式 Beta MUST 从 `main` 的确定提交构建，并在 prerelease 中记录相同版本的 DMG、SHA-256、公证 submission ID 与源提交。

#### Scenario: Maintainer audits a release

- **WHEN** 维护者检查发布记录
- **THEN** 可以把下载产物对应到精确源提交和 Apple 公证记录
