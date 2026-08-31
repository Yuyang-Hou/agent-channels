# Design

服务端继续从已认证 join endpoint 写入 `sender_member_id`、`sender_endpoint_id`、`sender_name` 和
`author_kind`。区别仅是把 `channel_ai` 权限从 owner 扩展到所有 active Membership；公开 band 仍拒绝。

每个 App 仍用账号与 Channel ID 隔离本机 workspace、task、指令、记忆和只读历史。创建者自动连接；加入者
在 AI 页签主动连接。现有 task 仍只能作为只读历史，避免新增绑定模型。

展示直接使用 `sender_name` 形成“成员名的 AI”。macOS 的连续分组键对 AI 使用 member + endpoint，防止
同一成员的不同 AI 或不同成员 AI 被合并；AI 页签外层 frame 使用顶部对齐，避免短内容垂直居中。
