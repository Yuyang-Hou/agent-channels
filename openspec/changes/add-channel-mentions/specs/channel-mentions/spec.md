# Channel Mentions Specification

## ADDED Requirements

### Requirement: 普通消息支持可靠的多人提及快照

Channel Service MUST 接受不@、@所有人或 1–100 个当前频道 active Member ID，并把服务端解析的
提及类型、Member ID 与发送时昵称快照写入普通消息。提及 MUST NOT 改变频道消息可见范围。

#### Scenario: 多人提及成功

- **GIVEN** A、B 都是频道中的 active Member
- **WHEN** 发送者提交 `mentions=[A.id,B.id]`
- **THEN** send 回执、history 与 SSE 以相同顺序返回 A、B 的服务端 Member ID 和昵称快照，所有频道监听者仍可看到消息

#### Scenario: @所有人成功

- **WHEN** 发送者提交 `mentions=["all"]`
- **THEN** 消息保存为 @所有人，不展开成当前成员列表

#### Scenario: 无效提及失败关闭

- **WHEN** mentions 为空、重复、混用 all 与 Member、超过 100 人，或任一 Member 已移除、封禁或属于其他频道
- **THEN** 服务端返回明确 400，不分配消息 ID、不保存也不广播消息

#### Scenario: 旧客户端不提及

- **WHEN** 客户端不提交 mentions
- **THEN** 消息按不@保存并继续对全频道广播

### Requirement: App 与当前 task 可选择多人提及

App MUST 提供不@、独占的@所有人和 active Member 多选。Codex MCP MUST 允许当前 task 读取已订阅
频道的可提及成员并通过 `send_to_channel` 提交同一 mentions 契约。

#### Scenario: App 多选发送

- **WHEN** 用户选择两名成员并可靠发送
- **THEN** App 历史显示两名成员的提及快照，并在成功后清空正文和选择

#### Scenario: 发送失败保留草稿

- **WHEN** 选中的成员在发送前失效或结果 unknown
- **THEN** App 保留正文和 mention 选择，不自动重试

#### Scenario: task 查询成员后发送

- **GIVEN** 当前 task 已订阅频道 C
- **WHEN** task 调用 `list_channels(channel=C)` 后用返回的多个 member_id 调用 `send_to_channel`
- **THEN** App 只使用 C 的有效成员和当前 task 的发送路由；未订阅频道失败关闭

### Requirement: 每条转发到会话可仅接收提及自己的消息

每条 Subscription MUST 默认接收所有消息，并可改为仅接收 @所有人或 mentions 中包含该频道本机
Member ID 的消息。过滤 MUST 在保存 LocalMessage 后、调用 Host 前发生。

#### Scenario: 多人列表命中自己

- **GIVEN** Subscription 使用仅@我且其 Member ID 在多人 mentions 中
- **WHEN** sidecar 收到消息
- **THEN** 消息正常进入该 AI 会话

#### Scenario: 未提及自己

- **GIVEN** Subscription 使用仅@我
- **WHEN** 消息不@或只@其他成员
- **THEN** LocalMessage 保留、该 SubscriptionDelivery 标为 filtered 并推进游标，Host 不创建 turn

#### Scenario: @所有人

- **GIVEN** Subscription 使用仅@我
- **WHEN** 消息为 @所有人
- **THEN** 消息正常进入该 AI 会话

#### Scenario: 自己 endpoint 回声

- **WHEN** 当前 task endpoint 发送一条包含自己的 mentions 消息
- **THEN** 精确 endpoint 防回声优先过滤，不创建循环 turn

#### Scenario: App endpoint @自己

- **GIVEN** Subscription 使用默认 include_other_endpoints 和仅@我
- **WHEN** 同一 Member 的 App endpoint @自己发送
- **THEN** 该消息进入 AI 会话

#### Scenario: 重连重放已过滤消息

- **GIVEN** 消息已因未命中提及而 terminally filtered
- **WHEN** Subscription 断线重连并再次看到该 message id
- **THEN** record_received 返回 already_processed，不能补投 Host
