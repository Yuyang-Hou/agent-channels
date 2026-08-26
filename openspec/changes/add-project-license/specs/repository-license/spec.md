# Repository License Specification

## ADDED Requirements

### Requirement: Clear Open Source License

仓库 MUST 在根目录提供标准 MIT License，并 MUST 保留第三方代码已有的版权声明。

#### Scenario: User checks reuse terms

- **WHEN** 用户从仓库首页查看项目授权
- **THEN** 可以找到根目录 MIT License，并确认 `server/` 中 RogerThat 上游版权声明仍被保留
