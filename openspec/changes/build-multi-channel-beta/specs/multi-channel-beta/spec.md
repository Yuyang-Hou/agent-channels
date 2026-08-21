# Multi-Channel Beta Requirements

## ADDED Requirements

### Requirement: 0.3 使用全新本地模型

0.3 Beta MUST 使用独立、版本化的多频道本地 store，MUST NOT 自动迁移、覆盖或删除 0.2 的
单 Binding 数据。

#### Scenario: 干净启动

- **GIVEN** 用户目录没有 0.3 store
- **WHEN** 0.3 App 首次启动
- **THEN** App 创建空的 0.3 store 并进入新频道引导

#### Scenario: 检测到 0.2 数据

- **GIVEN** 用户目录存在 0.2 `binding.json` 或凭证
- **WHEN** 0.3 App 启动
- **THEN** App 明确提示该 Beta 不支持迁移，且不读取、覆盖、删除或用于运行该数据

### Requirement: 主窗口管理多个频道

App MUST 以主窗口展示多个 ChannelConnection，并为当前频道提供简单文本时间线、发送框、
未读状态、成员和 task 订阅管理。

#### Scenario: 频道隔离

- **GIVEN** 用户同时加入频道 A 和频道 B
- **WHEN** 两个频道分别收到消息
- **THEN** 侧栏分别更新未读，时间线、发送目标和成员列表不串频道

#### Scenario: 重启保留本地历史

- **GIVEN** App 已接收两个频道的消息
- **WHEN** App 完全退出并重新打开
- **THEN** 两个频道的本地历史与未读位置仍可见，且消息按 `channel_id + message_id` 去重

### Requirement: 每个成员拥有独立凭证

Channel Service MUST 为 owner 和每个加入者创建独立 Member 凭证；邀请 token MUST 只用于创建
Membership，MUST NOT 作为多人共享的长期频道凭证。

#### Scenario: 接受邀请

- **GIVEN** owner 创建一份有效且未用尽的邀请
- **WHEN** 新成员接受邀请
- **THEN** 服务端创建独立 Member 与 endpoint，并只返回该成员自己的凭证

#### Scenario: 跨频道使用凭证

- **GIVEN** 成员持有频道 A 的有效凭证
- **WHEN** 它用该凭证访问频道 B 的 send、stream、history 或 roster
- **THEN** 服务端拒绝请求且不泄露频道 B 数据

### Requirement: owner 可以移除和封禁成员

owner MUST 可以移除、封禁和解除封禁普通成员；撤权 MUST 立即使该 Member 的凭证、session 和
现有 stream 失效。普通成员 MUST NOT 执行这些操作。

#### Scenario: 移除在线成员

- **GIVEN** 普通成员正在发送并监听频道
- **WHEN** owner 移除该成员
- **THEN** 其现有 stream 关闭，旧凭证后续 send 和 stream 均失败，其他成员不受影响

#### Scenario: 封禁成员

- **GIVEN** owner 封禁一个 Member
- **WHEN** 该 Member 尝试恢复、重新加入或创建 session
- **THEN** 服务端拒绝该 Member，直到 owner 解除封禁

#### Scenario: Beta 身份边界

- **GIVEN** 0.3 没有账户或设备身份恢复
- **WHEN** owner 查看封禁说明
- **THEN** UI 明确封禁针对当前 Member，不能承诺识别持新邀请创建全新 Member 的同一自然人

### Requirement: App 消息先落本地再投递 Host

App MUST 在尝试任何 Host delivery 前保存普通频道消息，并按 Subscription 单独记录后续状态。

#### Scenario: Host 不可用

- **GIVEN** 消息已到达 App 但目标 task 不可用
- **WHEN** Subscription 投递失败
- **THEN** 主窗口仍显示该 LocalMessage，且仅对应 SubscriptionDelivery 标为 `failed`

#### Scenario: 本地持久化失败

- **GIVEN** Subscription sidecar 已收到普通消息但 App 未能提交 `received` 事务或返回 ack
- **WHEN** Runtime 准备投递 Host
- **THEN** Runtime 不调用 Connector、不推进游标，并保留消息等待本地存储恢复后重试

#### Scenario: 不确定投递

- **GIVEN** Host mutating 请求已发出但回执未知
- **WHEN** App 更新消息状态
- **THEN** 对应 Subscription 标为 `unknown` 并暂停等待人工选择，其他 Subscription 继续运行

### Requirement: App 可以直接收发简单文本消息

用户 MUST 可以在主窗口向当前频道发送文本，并看到来自 App 或 task endpoint 的频道消息及
可靠发送状态。

#### Scenario: App 主动发送

- **GIVEN** 用户选中一个已授权频道
- **WHEN** 用户在主窗口发送非空文本
- **THEN** App 使用该频道的 Member 凭证和 app endpoint 发送，并仅在可靠回执后标记 `accepted`

#### Scenario: 发送结果未知

- **GIVEN** App 已发出频道 mutation 但没有可靠回执
- **WHEN** 用户查看时间线
- **THEN** 消息显示 `unknown`，App 不自动重复发送

### Requirement: TaskBinding 与频道 Subscription 分离

本机 MUST 分别保存 TaskBinding 和 Subscription；每条 Subscription MUST 拥有独立 endpoint、
游标、模板、自消息策略和运行状态。

#### Scenario: 一个 task 订阅两个频道

- **GIVEN** TaskBinding T 分别订阅频道 A 和 B
- **WHEN** A 和 B 同时收到消息
- **THEN** 两条 Subscription 独立串行投递并维护各自游标，不把 A 的消息标成 B 的来源

#### Scenario: 一个频道绑定两个 task

- **GIVEN** 频道 A 同时绑定 TaskBinding T1 和 T2
- **WHEN** A 收到一条普通消息
- **THEN** App 为 T1、T2 分别记录 delivery 状态，一个失败不暂停另一个

#### Scenario: 重启恢复

- **GIVEN** 多条 Subscription 已启用
- **WHEN** App 重启
- **THEN** App 恢复每条 Subscription 的 sidecar 和游标，空闲期间不创建 Host turn

### Requirement: Codex MCP 提供六个 task-scoped 频道工具

Codex MCP MUST 暴露 `send_to_channel`、`list_channels`、`subscribe_to_channel`、
`unsubscribe_from_channel`、`get_channel_settings` 和 `update_channel_settings` 六个工具。每个工具
MUST 从 `tools/call params._meta.threadId` 读取来源 task，并通过本机 socket v2 交给 App 精确
匹配 TaskBinding。App 和 MCP MUST NOT 使用最近活跃 task 或当前 UI 频道兜底。

MCP MUST NOT 读取 Keychain、直接访问 Channel Service、建立频道监听、消费入站消息、保存历史
或调用 Host Connector；这些消息接收能力 MUST 由 App 持有。`send_to_channel` MUST 可以在没有
入站消息的情况下主动调用，收到消息 MUST NOT 隐含自动回复。

#### Scenario: 工具表与接收边界

- **GIVEN** Codex 加载 Agent Channels MCP
- **WHEN** Codex 请求工具表
- **THEN** 只返回上述六项，且频道空闲或消息到达都不会由 MCP 自行轮询或创建 Host turn

#### Scenario: 当前 task 管理订阅

- **GIVEN** `_meta.threadId` 精确匹配 TaskBinding T
- **WHEN** T 调用频道列表、订阅、取消订阅或设置工具
- **THEN** App 只查询或修改 T 的本机 Subscription，凭证、网络监听和消息历史仍留在 App

#### Scenario: 两个 task 分别发送

- **GIVEN** Codex task A、B 分别绑定不同默认出站 Subscription
- **WHEN** 两个 task 调用相同的 `send_to_channel(message)`
- **THEN** 两次 `_meta.threadId` 分别匹配 A、B UUID，消息进入各自默认频道且不串台

#### Scenario: 来源能力缺失

- **GIVEN** `_meta.threadId` 缺失、类型错误或不是合法 UUID
- **WHEN** AI 调用发送工具
- **THEN** MCP 失败关闭并提示不兼容，App 不发起频道网络请求

#### Scenario: 来源尚未绑定

- **GIVEN** `_meta.threadId` 合法但本机没有对应 TaskBinding 或唯一默认 Subscription
- **WHEN** AI 调用发送工具
- **THEN** App 明确拒绝并提示用户在主窗口配置，不选择其他频道兜底

#### Scenario: 暂停接收后主动发送

- **GIVEN** 当前 task 的 Subscription 已暂停接收，但仍是合法的显式或唯一默认发送目标
- **WHEN** task 调用 `send_to_channel`
- **THEN** App 仍允许主动发送；接收开关不成为出站路由条件

### Requirement: 每条 Subscription 使用受限模板

Subscription MUST 使用本地模板把频道消息转换为 Host 输入，模板只允许
`channel_name`、`sender_name`、`message_text` 和 `message_id` 四个变量。

#### Scenario: 保存模板

- **GIVEN** 用户编辑 Subscription 模板
- **WHEN** 模板为空、超过上限或包含未知变量
- **THEN** App 拒绝保存并保留上一份有效模板

#### Scenario: 渲染不可信正文

- **GIVEN** 远端 message text 包含类似系统指令或模板标记的文本
- **WHEN** App 渲染 Host 输入
- **THEN** 该文本只作为 `message_text` 数据并继续标记不可信，不能选择 Binding 或改变模板

### Requirement: 自消息策略按 endpoint 判断

精确来源 task endpoint 的消息 MUST 永不回投该 task。Subscription MUST 可以选择是否接收
同一 Member 下其他 endpoint 的消息。

#### Scenario: App 给自己的 task 发消息

- **GIVEN** Subscription 使用默认 `include_other_endpoints`
- **WHEN** 同一 Member 的 app endpoint 向频道发送消息
- **THEN** 绑定 task 收到消息，但发送它的 app endpoint 不产生自回声

#### Scenario: 排除同一成员

- **GIVEN** Subscription 使用 `exclude_member`
- **WHEN** 同一 Member 的 App 或另一个 task endpoint 发送消息
- **THEN** 仅该 SubscriptionDelivery 标为 `filtered`，LocalMessage 与其他 Subscription 不受影响

#### Scenario: task 自己发送

- **GIVEN** task endpoint E 通过 MCP 发送消息
- **WHEN** 同一频道把该消息分发回 Subscription E
- **THEN** App 始终过滤该 delivery，避免创建自回声 turn

### Requirement: 多 Subscription 故障隔离

0.3 Beta MUST 为每条启用的 task-channel Subscription 独立监管运行态；一个 Subscription 的
重连、失败或人工确认 MUST NOT 扩散到其他 Subscription。

#### Scenario: 单项投递未知

- **GIVEN** Subscription A 的 Host 回执未知且 Subscription B 正常
- **WHEN** A 暂停等待人工确认
- **THEN** B 继续接收和投递，主窗口分别展示两个状态

#### Scenario: 成员撤权

- **GIVEN** ChannelConnection C 的 Member 被撤权
- **WHEN** App 收到授权失败
- **THEN** App 停止 C 的 feed 和全部 Subscription，保留其本地历史，其他频道继续运行
