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
