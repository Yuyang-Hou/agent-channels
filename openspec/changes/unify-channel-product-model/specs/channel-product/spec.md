# Channel Product Requirements

## ADDED Requirements

### Requirement: Channel 是唯一用户可见会话模型

App 和 Web MUST 只使用 Channel 表达一人、两人或多人对话，不得按成员人数产生助理、好友或群聊类型，
也不得用成员昵称替换服务器 Channel 名称。

#### Scenario: 不同人数的频道

- **WHEN** Channel 的 active Membership 数量变化
- **THEN** Channel 名称、导航结构和功能保持一致

### Requirement: 用户创建频道时自动建立 owner 运行 task

App MUST 在 owner 主动创建 Channel 后自动建立一个 Channel 隔离的 Codex task。执行 task MUST NOT
成为用户可选择或绑定的独立产品对象；加入他人 Channel MUST NOT 创建第二个 task。

#### Scenario: owner 创建频道

- **WHEN** 用户创建 Channel
- **THEN** App 建立该 Channel 专属工作区、Codex task 和消息 Subscription

#### Scenario: 成员加入频道

- **WHEN** 用户通过邀请加入其他 owner 的 Channel
- **THEN** App 只恢复 Channel Membership，不创建或绑定本机 Codex task

### Requirement: 消息来源决定模型路由

Channel Service MUST 从认证 endpoint 写入 `human` 或 `channel_ai` 来源。监听器 MUST 把所有 `human`
内容消息交给 Channel Codex task，并 MUST NOT 把 `channel_ai` 消息再次交给该 task。

#### Scenario: owner 从 Web 发送消息

- **WHEN** owner 从 Web endpoint 发送 `human` 消息
- **THEN** 消息与其他成员的人类消息一样进入 Channel Codex task

#### Scenario: Channel AI 回复

- **WHEN** owner 受管 task 发送 `channel_ai` 消息
- **THEN** 消息进入 Channel 历史并推送 App/Web
- **AND** 监听器记录后过滤该消息，不创建新的 Codex turn

#### Scenario: 非 owner 声明 AI 来源

- **WHEN** 普通成员 endpoint 请求 `channel_ai`
- **THEN** Channel Service 拒绝该 endpoint join

### Requirement: 人类与 AI 消息独立展示

App 和 Web MUST 使用 `author_kind` 参与消息展示与分组。AI MUST 使用独立图标和标签，且 MUST NOT
成为 Membership。

#### Scenario: 人类消息后紧邻 AI 回复

- **WHEN** 两条消息时间间隔小于五分钟且 Member id 相同
- **BUT** 第一条为 `human`、第二条为 `channel_ai`
- **THEN** App/Web 使用两个独立作者样式展示，不合并头像或气泡组

### Requirement: 频道本地上下文按 Channel 隔离

App MUST 按 Channel 保存用户指令、AI 记忆、受管 task id 和只读历史 allowlist。一个 Channel 的配置
MUST NOT 被其他 Channel 读取或修改。

#### Scenario: 两个 owner Channel

- **WHEN** owner 创建 Channel A 和 Channel B
- **THEN** 两者使用不同工作区、Codex task、记忆和历史 allowlist

#### Scenario: 撤销历史授权

- **WHEN** owner 从 Channel A 撤销一个历史 task
- **THEN** Channel A 后续查询不再读取该 task
- **AND** Channel B 的配置不受影响
