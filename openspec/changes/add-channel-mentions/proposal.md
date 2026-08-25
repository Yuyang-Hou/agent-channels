# Proposal: Add Channel Mentions

## Why

频道消息当前只有广播正文。每条启用的 Subscription 都会收到所有非自消息，用户无法在多人频道中
只让与自己有关的消息进入 AI 会话，也无法从 App 或 AI 明确提醒一名或多名成员。

## What Changes

- 普通频道消息增加可选 mention 元数据，支持不@、@所有人和@一至多名 active Member。
- App 发送框提供成员多选；消息历史显示服务端确认的提及快照。
- `send_to_channel` 接受可选 `mentions`，`list_channels(channel)` 返回该频道可选成员。
- 每条 Subscription 增加“所有消息 / 仅@我”接收范围；未命中只过滤 Host 投递，仍保留本地历史。
- 默认收发模板增加 `{mentions}`，让 AI 输入和可靠发送回执都能看到提及范围。

## Product Decisions

- @ 是频道内提醒，不是私信或授权边界；所有频道成员仍能看到消息。
- 成员目标按稳定 `member_id` 匹配，昵称只保存发送时服务端快照，不解析正文中的 `@昵称`。
- `@所有人` 与成员列表互斥；第一版成员列表最多 100 个且必须去重。
- 任一目标不是当前频道 active Member 时整条发送失败，不静默删除无效目标。
- 旧消息没有 mention，按“不@”处理；现有 Subscription 默认继续接收所有消息。

## Non-goals

- 私信、隐藏消息、服务端按 mention 裁剪频道历史或 SSE。
- `@会话`、`@endpoint`、用户组、角色或模糊昵称解析。
- 富文本编辑器、正文内联 mention token、提醒通知或已读回执。
- 为超过 100 个精确成员的消息增加分页发送；此时使用 @所有人。

## Impact

Channel Service、listen-here sidecar、本机 IPC、Codex MCP、macOS App、本地消息 ledger、模板与
产品 Skill 都需要透传 mention。消息 ID、`to` 路由、自消息防回声、投递幂等和 unknown 处理保持不变。
