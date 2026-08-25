# Design

## Message Contract

发送请求使用一个可选字符串数组：

```json
{ "message": "正文" }
{ "message": "正文", "mentions": ["all"] }
{ "message": "正文", "mentions": ["member-a", "member-b"] }
```

服务端把请求解析为可选 `Mention`：`all`，或按请求顺序保存的成员快照列表
`[{member_id, member_name}]`。`all` 只能单独出现；成员列表须为 1–100 个非空、唯一 ID。
服务端必须在同一频道的成员权威数据中确认全部目标仍为 active，再构造并持久化消息。

`to` 继续只表示历史 callsign 路由。Pijoo App 和 task MCP 仍以 `to=all` 广播消息；mention
不会改变 Channel feed、history 或 SSE 的可见范围。

## Local App And MCP

App 的输入框维护未持久化的 composer mention 选择。成员菜单复用 `/members`，只展示 active
成员并允许多选；“所有人”是独占选择。可靠发送成功后清空正文和 mention，明确失败或 unknown
保留二者。历史中的 mention 使用消息快照展示，不依赖当前成员列表。

MCP 保持七个工具。`send_to_channel` 增加 `mentions?: string[]`；`list_channels` 增加可选
`channel`，指定时只为当前 task 已订阅的该频道读取 active Member，并返回 `member_id`、`name`
和 `is_self`。MCP 不监听频道、不保存 roster。

## Subscription Filtering

`ChannelSubscription.receiveScope` 取 `all_messages` 或 `mentions_only`，默认前者。App 启动
listen-here 时把它作为参数传给该 Subscription 的独立 sidecar。

普通消息处理顺序保持：

1. `record_received` 先保存 LocalMessage 与 received delivery；
2. 精确 sender endpoint 防回声和现有 same-member policy；
3. `mentions_only` 判断 mention 是 `all` 或成员快照包含当前 `self_member_id`；
4. 未命中记录 `filtered` 和 `mention_not_matched`，推进该 Subscription 游标，不调用 Host；
5. 命中才进入 `attempting` 和 Host Connector。

这样 App 从其他 endpoint @自己可以唤起自己的 AI 会话，而 task 自己发送的消息仍由精确 endpoint
规则阻止回投。过滤属于正常接收策略，不改变全局健康状态，也不影响同一消息的其他 Subscription。

## Templates And Compatibility

模板增加 `{mentions}`：不@展开为“无”，@所有人展开为“@所有人”，成员列表按发送顺序展开为
“@张三、@李四”。自定义旧模板没有该变量时继续可用。

Message、LocalMessage、sidecar event 和 ledger 中的新字段全部可选。旧服务端消息等同不@；旧
Subscription 解码时 `receiveScope` 默认 `all_messages`。无需迁移现有消息 JSONL 或 App state。

## Failure And Reconnect

成员在选择后、发送前被移除或封禁时，服务端返回明确 400，App/MCP 不自动重试。服务端可靠接收
后沿用现有 accepted/unknown 边界。断线重连和历史 replay 继续使用 message id；terminal
`filtered` 仍由 `record_received` 幂等保护，不会在恢复时补投 Host。
