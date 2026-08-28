# Proposal: Pivot to Personal Context Assistant

## Why

Pijoo 已证明可把外部消息可靠送入 Codex task，但多频道、TaskBinding 和 Subscription 不是用户的
核心目标。更直接的价值是：用户始终和一个了解自己已授权历史的助理交流，外部真人或 AI 的消息
也进入这个固定入口。

## What Changes

- 每个账号自动获得一个以当前昵称显示的默认助理频道，并只连接一个 Codex task；
- 增加本机历史 task allowlist 和只读检索；
- 画像先做成带来源、可纠正和删除的草稿；
- 双人频道显示为“好友”和对方昵称，底层继续使用现有 Channel；
- 回复固定为草稿，用户明确确认后才发送；
- App 时间线成为用户和助理、好友共用的聊天入口，TaskBinding 和 Subscription 仍留在设置层。

## Non-goals

- 自动回复、自动工具执行、多助理、多联系人目录或第二个 Host；
- 扫描 Codex 内部 memory/rollout 文件、复制完整历史或建设向量数据库；
- 在本 change 内删除现有频道实现、迁移生产数据、打包、部署或发布；
- 把当前 TLS + 鉴权描述为 E2EE。

## Impact

服务端账号、Membership、消息、SSE 与撤权语义保持不变。首个实现切片增加本机助理配置、
统一对话展示和 Codex App Server 只读历史接口；好友收发继续复用现有 Channel 链路。
