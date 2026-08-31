# Design

服务端继续从已认证 join endpoint 写入 `sender_member_id`、`sender_endpoint_id`、`sender_name` 和
`author_kind`。区别仅是把 `channel_ai` 权限从 owner 扩展到所有 active Membership；公开 band 仍拒绝。

每个 App 仍用账号与 Channel ID 隔离本机 workspace、task、指令、记忆和只读历史。创建者自动连接；加入者
在 AI 页签主动连接。现有 task 仍只能作为只读历史，避免新增绑定模型。

展示直接使用 `sender_name` 形成“成员名的 AI”。macOS 的连续分组键对 AI 使用 member + endpoint，防止
同一成员的不同 AI 或不同成员 AI 被合并；AI 页签外层 frame 使用顶部对齐，避免短内容垂直居中。

可 @ AI 复用既有 mention 数组，以 `ai:<member_id>` 区分成员本人和该成员的 AI。服务端仅在 active
Membership 同时存在已认证 `channel_ai` SSE 接收流时返回 `ai_connected=true` 并接受该目标；断流后
立即不可 @。App 和 MCP 都从 `/members` 派生目标，不保存第二份 AI 名单。

Subscription 复用既有 `receive_scope`：`all_messages` 为默认值，`mentions_only` 只让 `@所有人` 或
mention 的 `ais` 快照包含本 Membership 的 human 消息进入 Host。所有消息仍先写入本机历史，AI 作者
消息仍优先过滤，mention 不改变频道可见性。
