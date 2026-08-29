# Proposal: Isolate Channel Assistant Workspace

## Why

PR #17 允许 Owner 把默认助理频道分享给 Web 用户。当前频道可以连接任意既有 Codex task；远端不可信消息
因此可能进入用户原 task，并继承该 task 的工作目录和权限。用户需要的是一个由 Pijoo 控制的频道助理，
不是让分享者或加入者间接操作任意项目会话。

## What Changes

- 每个本机账号只有一个 Pijoo 管理的助理工作区，位于 `~/Pijoo` 下的账号隔离目录；
- App 在创建助理 task 前写入内置 `AGENTS.md` 身份卡，并把该目录作为唯一执行工作区；
- 默认助理频道只向这个受管 task 投递消息，不再绑定既有 Codex task 作为执行目标；
- 既有 task 只能经显式 allowlist 通过 `thread/read` 提供有界、带来源的只读内容；
- 频道投递前复验 task 的工作目录和 sandbox 档位，状态漂移时失败关闭；
- 当前会话搜索能力保留，后续在默认助理频道中复用为“授权只读资料源”，不新增第二套选择器。

## Non-goals

- 用 `AGENTS.md` 代替 sandbox、审批、历史 allowlist 或发送确认；
- P0 提供身份卡编辑器、多个助理、每频道独立人格或通用权限 DSL；
- 迁移、修改或在用户既有 Codex task 中创建 turn；
- 把身份卡、task id、工作目录、历史正文或权限配置上传到 Channel Service；
- 在本 change 中打包、部署或发布。

## Impact

Channel、Membership、邀请、Web 客户端、消息协议与可靠回执保持不变。主要改动位于 macOS 的本机路径、
助理配置与 Subscription 路由，以及 Codex Connector 的投递前校验。当前没有存量用户，本 change 不设计
旧助理 task 或旧工作目录迁移。
