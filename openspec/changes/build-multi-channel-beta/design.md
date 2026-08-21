# Design

## Runtime Shape

```text
Channel Service
  -> Channel / Invite / Member / Endpoint / Message / Session
  -> member-scoped credentials and revocation

Agent Channels.app
  -> main window + local history + Keychain
  -> ChannelConnection[]
  -> TaskBinding[] x Subscription[]
  -> one supervised listen-here sidecar per enabled task-channel Subscription
  -> one user-only app.sock for MCP and supervised sidecar -> App requests

Codex task
  -> send_to_channel / list_channels
  -> subscribe_to_channel / unsubscribe_from_channel
  -> get_channel_settings / update_channel_settings
  -> tools/call params._meta.threadId
  -> local socket v2 -> exact TaskBinding -> App-owned operation
```

App 是本机配置、凭证、消息状态、频道监听、Host 投递和 sidecar 生命周期的唯一 owner。
Channel Service 不理解 TaskBinding；MCP 不读取 Keychain、不直接请求服务端，也不接收频道
消息；sidecar 不决定 UI 中的频道选择。

## Service Data Model

```text
Channel
  id, name, owner_member_id, created_at

Invite
  id, channel_id, created_by_member_id, token_hash, expires_at, max_uses, revoked_at

Member
  id, channel_id, display_name, role(owner|member), status(active|removed|banned),
  credential_hash, created_at, revoked_at

Endpoint
  id, member_id, kind(app|task), label, status

Message
  id, channel_id, sender_endpoint_id, text, created_at

OnlineSession
  id, member_id, endpoint_id, cursor, expires_at
```

邀请 token 是短期加入能力。加入成功后，服务端创建 Member，并只返回该 Member 自己的长期
凭证；owner 和每个加入者使用不同凭证。任何频道 API 都从 member credential 解析
`channel_id + member_id`，不得再接受共享频道 token 代表所有成员。

`removed` 与 `banned` 都撤销当前凭证、终止在线 session 并关闭现有 stream。`removed` 的成员
可以由 owner 通过新邀请重新加入；`banned` 的同一 Member 不能恢复或重新激活。0.3 Beta 没有
账户或设备证明，因此不能承诺阻止同一个自然人在拿到另一份新邀请后创建全新 Member；UI 和
文档必须明确这个边界。

Endpoint 只用于来源和自消息判断。task Endpoint 的 id 是不透明随机值；服务端不得保存
provider、Codex thread id、工作目录或本机路径。

## Local Data Model

0.3 使用全新的版本化本地 store；不读取或改写 0.2 `binding.json`。

```text
ChannelConnection
  id, channel_id, member_id, display_name, credential_ref, app_endpoint_id,
  last_read_message_id, connection_state

TaskBinding
  id, provider, conversation_id, label, compatibility_state

Subscription
  id, channel_connection_id, task_binding_id, task_endpoint_id,
  enabled, is_default_outbound, template_id, same_member_policy,
  last_received_message_id, last_delivered_message_id, runtime_state

DeliveryTemplate
  id, name, body

LocalMessage
  channel_id, message_id, sender_member_id, sender_endpoint_id, sender_label,
  direction, text, server_created_at, local_received_at, outbound_state

SubscriptionDelivery
  subscription_id, channel_id, message_id,
  state(received|filtered|delivered|failed|unknown), detail, updated_at
```

本地 secret 只存 Keychain；store 只保留 Keychain locator。`TaskBinding.conversation_id` 只在本机
使用。`LocalMessage` 以 `channel_id + message_id` 去重；同一服务端消息可以拥有多条不同的
SubscriptionDelivery。

0.3 不迁移旧数据：clean install 创建新 store。若检测到 0.2 数据，App 不导入、不覆盖、不
删除，只提示该 Beta 需要全新配置。

## Main Window

主窗口采用三块最小布局：频道侧栏、当前频道时间线与发送框、成员和 task 订阅详情。菜单栏
继续展示总体状态并快速打开主窗口，但不再承担完整配置流程。

App 为每个已加入频道维护消息 feed。普通消息到达时，必须先 upsert `LocalMessage` 为
`received`，随后才允许 Host delivery。这样即使 task 不可用、模板过滤或投递结果未知，用户
仍能在主窗口看到消息及其真实状态。

该顺序不能依赖异步 stderr 状态。0.3 的单一本机 App IPC 除 MCP 发送外，还提供 sidecar 使用的
`record_received` 与 `record_outcome` 请求：Subscription sidecar 在调用 Connector 前提交标准
消息信封，App 用一个本地事务 upsert LocalMessage 和 `received` SubscriptionDelivery 并返回
ack；只有拿到 ack 才能继续 Host delivery。投递结束后 sidecar 再记录 filtered、delivered、
failed 或 unknown。App 无法持久化或 IPC 不可用时，sidecar 不调用 Host、不推进游标。频道 feed
与多个 Subscription 重复看到同一消息时仍由本地唯一键合并。

App 手工发送使用当前选中的 ChannelConnection 和 app endpoint。发送状态区分
`pending`、`accepted`、`failed` 与 `unknown`；只有可靠服务端回执才能标记 `accepted`。本地
历史在重启后保留并可由用户清空，但不宣称跨设备同步或永久保存。

## TaskBinding And Subscription

TaskBinding 只描述一个本机 Host 会话；Subscription 才表达“这个 task 接收这个频道”。删除
TaskBinding 必须先停掉相关 Subscription，删除 ChannelConnection 也必须停止其全部运行态。

P0 每条启用的 Subscription 监管一个现有 `listen-here` sidecar，保持独立 session、游标、
错误和不确定投递状态。一个 Subscription 失败不得暂停其他 Subscription。App 可以为频道
时间线维护独立 feed；重复抵达由本地消息唯一键去重。本轮不把这些进程合并为 daemon。

每个 TaskBinding 最多有一条 `is_default_outbound=true` 的启用 Subscription。AI 主动发送时，
若指定频道，App 只允许使用当前 task 已启用的对应 Subscription；若省略频道，App 只使用唯一
默认项。没有默认项或存在多个默认项都必须失败关闭并提示用户在主窗口修复。Subscription 的
`enabled` 只控制接收监听；暂停接收不得阻止 task 通过该 Subscription 主动发送。

## Codex Source Routing

0.3 MCP 工具表固定暴露六项：

- `send_to_channel`：当前 task 随时主动发送，可使用显式已订阅频道或唯一默认出站频道；
- `list_channels`：列出 App 中当前 task 可见的频道及订阅状态；
- `subscribe_to_channel` / `unsubscribe_from_channel`：请求 App 创建或移除当前 task 的订阅；
- `get_channel_settings` / `update_channel_settings`：读取或修改当前 task 某条订阅的模板、
  自消息策略和默认发送设置。

频道 SSE、消息接收、本地历史、sidecar 与 Host Connector 全部由 App 持有。MCP 只把当前工具的
已校验参数和 source context 交给 App；它不会因为消息到达而自动运行，也不把“收到消息”解释
为“必须回复”。普通 Codex MCP 调用当前可在 `tools/call params._meta.threadId` 提供来源 task
id，但它属于 Host 能力而非 Agent Channels 稳定协议，因此必须做能力探测和实机验收。

例如发送工具在校验 `_meta.threadId` 后，通过 App IPC v2 提交：

```json
{
  "version": 2,
  "operation": "send",
  "message": "...",
  "channel": "optional-channel-id",
  "source": { "provider": "codex", "conversationId": "..." }
}
```

其余五项使用相同 source context，只附带各自需要的 `channel` 或 `settings`；所有频道凭证、网络
请求和接收状态都留在 App 内。

App 用 `provider + conversationId` 精确匹配 TaskBinding，再解析唯一默认出站 Subscription。
缺少 `_meta.threadId`、类型错误、未绑定、无默认 Subscription 或歧义时，不请求 Channel
Service，不回退到最近活跃 task、当前 UI 频道或全局 active channel。thread id 不进入工具正文、
服务端请求或频道消息。

能力探测必须覆盖两个同时打开的真实 Codex task，并记录 A/B `tools/call` 的 `_meta.threadId`
是否分别等于各自 UUID。源码观察只算设计依据，不能代替该实机门槛。

## Templates And Self-Message Policy

每条 Subscription 选择一个本地 DeliveryTemplate。模板只支持以下变量：

- `{channel_name}`
- `{sender_name}`
- `{message_text}`
- `{message_id}`

保存时拒绝未知变量、空模板和超过本地上限的结果。远端正文只作为 `{message_text}` 数据插入，
仍明确标记为不可信外部输入，不能成为模板指令或选择目标 Binding。

精确 `sender_endpoint_id == subscription.task_endpoint_id` 的消息永远过滤，避免 task 自回声循环。
每条 Subscription 另有 `same_member_policy`：

- `include_other_endpoints`（默认）：接收同一 Member 下 App 或其他 task endpoint 的消息；
- `exclude_member`：过滤同一 Member 的所有消息。

过滤只把对应 SubscriptionDelivery 标为 `filtered`，不删除 LocalMessage，也不影响其他
Subscription。0.3 不提供“回投精确来源 endpoint”、脚本规则或自动回复。

## Recovery And State

- Channel feed、Subscription sidecar、TaskBinding 兼容性和每条 delivery 分别展示状态。
- 每条 Subscription 只有 Host 明确接受后才推进 `last_delivered_message_id`。
- `failed` 可按原语义重试；`unknown` 必须停住该 Subscription 并等待人工选择，不能拖停其他项。
- App 重启后恢复所有 enabled Subscription；空闲频道不创建 Codex turn。
- 成员撤权后清除对应 Keychain credential、停止该 ChannelConnection 的 feeds 和所有
  Subscription，但保留本地历史供用户查看或清空。

## Beta Boundary

0.3 验收只针对干净安装、新建频道和 Apple Silicon。旧 0.2 数据继续留在原位置但不参与运行。
只有完成两台设备、两个频道、两个真实 Codex task 的路由与撤权验收后，才构建并发布 0.3
Beta；源码、API 200 或单机 UI 演示都不算完成。
