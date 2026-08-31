# Channel Product Delta Requirements

## MODIFIED Requirements

### Requirement: 用户可为自己的 Membership 连接 Channel AI

App MUST 为创建者自动连接一个隔离 AI，并允许其他 active Channel 成员主动连接自己的一个本机隔离 AI。
运行 task MUST 继续由 App 管理，不得成为用户选择的独立产品对象。

#### Scenario: 普通成员连接 AI

- **GIVEN** 用户已作为 active Member 加入 Channel
- **WHEN** 用户在自己的 App 中选择“连接我的 AI”
- **THEN** App 建立该账号与 Channel 隔离的 workspace、task 和 Subscription
- **AND** 该 AI 可向 Channel 发送认证 `channel_ai` 消息

#### Scenario: 公开 band 声明 AI

- **WHEN** 公开 band endpoint 请求 `channel_ai`
- **THEN** Channel Service 拒绝请求

### Requirement: 多个成员 AI 独立展示与分组

App 和 Web MUST 将 AI 消息显示为“成员名的 AI”。macOS 连续分组 MUST 同时匹配 Member id 与 endpoint id。

#### Scenario: 两个 AI 连续回复

- **WHEN** 两条相邻 `channel_ai` 消息来自不同 Member 或不同 endpoint
- **THEN** App 分别显示头像和“成员名的 AI”标题，不合并消息组

#### Scenario: 同一个 AI 连续回复

- **WHEN** 两条五分钟内的 `channel_ai` 消息具有相同 Member id 与 endpoint id
- **THEN** App 可以把第二条作为连续消息展示

### Requirement: AI 页签内容顶部对齐

AI 页签 MUST 从可用内容区顶部展示连接状态和设置，不得因内容不足而垂直居中。

#### Scenario: 宽屏窗口中的短设置内容

- **WHEN** AI 页签内容高度小于窗口可用高度
- **THEN** 第一项紧邻页签栏下方显示，剩余空白位于内容底部

### Requirement: 仅已连接的成员 AI 可被提及

App 与 MCP MUST 只为当前保持已认证接收流的 Channel AI 暴露提及目标，并以发送时的 Member ID 与昵称
快照保存 AI mention。AI mention MUST NOT 改变频道消息对其他成员的可见性。

#### Scenario: 频道中没有已连接 AI

- **WHEN** 所有 active Member 都没有在线 Channel AI 接收流
- **THEN** App 的 @ 菜单不显示任何 AI 目标，MCP 也不返回 `ai_mention`

#### Scenario: 成员 AI 连接与断开

- **WHEN** 某成员的认证 `channel_ai` SSE 接收流建立
- **THEN** 该成员出现“@成员名的 AI”目标且发送可以成功
- **WHEN** 接收流断开
- **THEN** 该目标立即消失，旧目标发送失败关闭

### Requirement: Channel AI 可配置回复范围

每条 Channel AI Subscription MUST 默认回复所有 human 消息，并允许改为仅回复 @所有人或明确 @自己的 AI。
过滤 MUST 在保存本机消息之后、创建 Host turn 之前执行。

#### Scenario: 仅回复提及自己的 AI

- **GIVEN** Subscription 为 `mentions_only`
- **WHEN** human 消息的 AI mention 包含该 Subscription 的 Member ID，或消息为 @所有人
- **THEN** 消息进入对应 AI task

#### Scenario: 未命中 AI mention

- **GIVEN** Subscription 为 `mentions_only`
- **WHEN** 消息不@、仅@成员本人或仅@其他成员的 AI
- **THEN** 消息保留在本机历史并标记 filtered，不创建 Host turn
