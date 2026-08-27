# Beta Release Pipeline Specification

## ADDED Requirements

### Requirement: Unprivileged merge candidate

PR 与 `main` CI MUST 不读取发布凭据，并 MUST 在 server、OpenSpec、Swift 与 package 校验通过后才成功；
`main` push MAY 保存短期候选包，但 MUST NOT 创建公开 Release。候选包与正式 Beta 的 App 可执行文件
MUST 由 macOS 26 或更新 SDK 编译，避免 macOS 26 使用旧兼容外观。

#### Scenario: Pull request validation succeeds

- **WHEN** PR 以不含发布凭据的 workflow 完成全部检查
- **THEN** 维护者可以合并，且 PR 代码不能读取 Developer ID 或 notarization secret

#### Scenario: Main candidate build is interrupted

- **WHEN** `main` 候选构建失败或被新的 push 取消
- **THEN** 不创建 tag 或 GitHub Release，也不把候选包声明为正式 Beta

#### Scenario: Hosted image uses an old SDK

- **WHEN** 打包后的 App 可执行文件记录的 SDK 主版本小于 26
- **THEN** package 校验失败，且不得上传候选包或继续正式发布

#### Scenario: Untrusted PR requests release access

- **WHEN** PR 修改 workflow 或构建代码并尝试读取发布凭据
- **THEN** PR job 仍只有只读仓库权限且没有 `release` Environment secrets

### Requirement: Authorized notarized beta

正式 Beta MUST 由维护者人工触发，从当时 `origin/main` 精确提交计算下一 Beta tag，并对同一 DMG
完成 Developer ID 签名、公证、staple、Gatekeeper、内容校验、draft 上传和公开回下载校验。

#### Scenario: Maintainer releases the next beta

- **WHEN** 有权限的维护者批准 `release` Environment job
- **THEN** workflow 发布下一 `beta.N` GitHub prerelease，App build、MCP 版本、文件名和 tag 一致，
  Release Notes 汇总上一版本以来的合并 PR 并附带源码、SHA-256、文件大小和 Apple 公证编号

#### Scenario: Notarization or verification fails

- **WHEN** Apple 未接受产物，或本地、draft、公开资产任一摘要/签名/内容校验失败
- **THEN** workflow 失败且不得把未通过 draft 校验的产物公开

#### Scenario: Caller lacks release authorization

- **WHEN** 未获 Environment 授权的调用者尝试发布
- **THEN** job 无法取得签名与 notarization secrets，因而不能生成正式 Beta
