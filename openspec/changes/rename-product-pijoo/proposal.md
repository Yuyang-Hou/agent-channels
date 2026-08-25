# Proposal: Rename Product to Pijoo

## Why

`Agent Channels` 是工作名称，无法作为正式 Beta 的最终产品标识。产品名称现确定为 `Pijoo`，
品牌域名为 `pijoo.dev`。

## What Changes

- App、DMG、菜单、错误提示、文档和产品 Skill 统一显示 `Pijoo`。
- 源码类型、MCP 名称、环境变量、协议标签、资源和文件名统一使用 `Pijoo`、`pijoo` 或 `PIJOO`。
- Bundle ID、Keychain service 与本机队列标识采用域名反写命名空间 `dev.pijoo`。
- 旧工作名称的 App Support、Keychain、MCP 与 Skill 不迁移；正式 Beta 按新 App clean-slate 安装。
- 现有 GitHub 仓库和 Railway 资源尚未迁移，本 change 保留它们的真实外部地址。

## Product Decisions

- 产品名精确写作 `Pijoo`，不保留“暂定名”。
- Skill 名、MCP server 名和本机配置段使用 `pijoo`。
- 不增加旧名称别名、双读路径或迁移脚本。

## Non-goals

- 注册或部署 `pijoo.dev` 网站。
- 重命名 GitHub 仓库、Railway 项目、服务或已发布的历史构建产物。
- 构建、签名、公证、上传或发布 Beta。

## Impact

Bundle ID、本机数据路径和 Keychain service 改变后，旧内测 App 不会自动继承状态或原地升级。
当前尚无正式 Beta 用户，因此新 Beta 以全新身份安装。
