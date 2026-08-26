# Repository Identity Specification

## ADDED Requirements

### Requirement: Pijoo GitHub Repository

Pijoo 的公开 GitHub 仓库 MUST 使用 `Yuyang-Hou/pijoo`，App 自动更新和当前文档 MUST 指向该地址。

#### Scenario: App checks for a Beta update

- **WHEN** Pijoo 请求 GitHub Release API
- **THEN** 请求目标为 `Yuyang-Hou/pijoo`，并能读取已发布的 Beta Release
