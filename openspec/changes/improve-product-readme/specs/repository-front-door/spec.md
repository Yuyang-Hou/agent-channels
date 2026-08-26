# Repository Front Door Specification

## ADDED Requirements

### Requirement: Product-first README

仓库 README MUST 先说明 Pijoo 的用户问题、核心价值、下载入口与使用要求，再提供开发信息。

#### Scenario: New visitor opens the repository

- **WHEN** 首次访问者打开仓库首页
- **THEN** 无需理解 MCP、SSE 或 IPC 即可知道 Pijoo 的用途、当前平台和如何开始体验

### Requirement: Accurate Beta Boundary

README MUST 明确当前只支持 macOS Apple Silicon 与 Codex，且公开 Beta 尚未达到稳定版状态。

#### Scenario: User evaluates whether to install

- **WHEN** 用户查看下载与项目状态
- **THEN** 可以看到系统要求、已签名公证状态、当前版本和未完成的产品验收边界

### Requirement: Bilingual And Contribution-ready

仓库 MUST 提供内容一致的英文与简体中文 README，MUST 明确 Codex 已支持，Claude Code 与
Cursor 为 coming soon，并 MUST 欢迎有边界的 Issue 与 Pull Request。

#### Scenario: International contributor opens the repository

- **WHEN** 英文或中文读者进入仓库
- **THEN** 可以切换语言、识别真实 Agent 支持状态并找到贡献入口

### Requirement: Privacy-safe Product Screenshot

英文与中文 README MUST 分别展示一张基于真实产品界面的本地化、隐私安全截图，突出前端与后端
Agent 通过 Pijoo 跨用户、跨机器协作，且 MUST NOT 暴露真实用户名、任务、消息编号或内部系统信息。

#### Scenario: Visitor evaluates the product experience

- **WHEN** 英文或中文访问者查看对应 README 首屏
- **THEN** 可以用对应语言直观看到 Pijoo 在 Codex 会话中的消息往返，同时不会看到无关或敏感细节
