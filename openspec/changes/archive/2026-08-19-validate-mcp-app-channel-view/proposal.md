# Proposal: Validate MCP App Channel View

## 决策

- 复用现有 RogerThat MCP、REST 与 SSE，不新增消息协议。
- 新增一个 `open_channel_view` Tool，返回 MCP Apps `ui://` View。
- View 只在活跃期间监听当前频道；收到普通消息后自动调用 `ui/message`。
- 外部消息始终标记为不可信输入，由当前 AI 决定是否调用现有 `send` 回复。

## 目标

- 目标 Host 能渲染 View，并允许 View 建立 SSE 连接。
- 无用户点击时，频道消息能够触发 `ui/message`。
- 当前 AI 能在同一个 MCP 会话中使用 `send` 回复。
- View 明确展示连接、消息投递和 Host 拒绝状态。

## 非目标

- 不新增账号、Membership、通知或后台 Runtime。
- 不承诺 View 关闭、Host 退出或设备离线时唤醒 AI。
- 不迁移内存消息、在线会话或游标到持久化存储。
- 不构建完整聊天界面。
