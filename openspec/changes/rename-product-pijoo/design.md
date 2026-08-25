# Design

## Naming Map

| Surface | Value |
|---|---|
| Product | `Pijoo` |
| Slug and protocol label | `pijoo` |
| Environment prefix | `PIJOO` |
| Bundle namespace | `dev.pijoo` |
| App bundle | `Pijoo.app` |
| Distribution image | `Pijoo-<version>-arm64.dmg` |
| Skill and MCP name | `pijoo` |

## Clean-slate Boundary

旧工作名称只存在于已发布产物、GitHub 仓库 slug 和其他外部资源的真实定位中。运行时代码不读取
旧 App Support、Keychain、Skill 或 MCP 配置，也不写双份状态。

GitHub Release 检查继续访问尚未迁移的真实仓库地址。仓库完成外部重命名后，再以独立操作更新
远端和文档链接，避免本次改名使更新检查失效。
