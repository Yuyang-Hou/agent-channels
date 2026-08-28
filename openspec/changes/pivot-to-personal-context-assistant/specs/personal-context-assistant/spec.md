# Personal Context Assistant Requirements

## ADDED Requirements

### Requirement: 每个账号自动拥有一个默认助理频道

App MUST 在账号同步时自动保证存在一个只有自身 active Membership 的普通 Channel，并在本机把它标记为
默认助理频道。该频道 MUST 使用用户当前昵称显示，MUST 无需用户手动创建，并且 MUST 只保留一个启用的 Codex task Subscription。App 与 task 作为同一
Membership 的不同 endpoint 通过现有频道链路双向收发。

#### Scenario: 建立助理

- **GIVEN** 当前账号尚未配置默认助理频道
- **WHEN** App 完成账号同步
- **THEN** App 自动创建频道、保存稳定 channel id，并用用户昵称显示
- **AND** 用户无需执行创建频道操作

#### Scenario: App 与助理聊天

- **GIVEN** 默认助理频道已连接一个 task，接收策略允许同 Membership 其他 endpoint
- **WHEN** 用户在 App 时间线发送消息
- **THEN** 消息进入该 task，task 的频道回复回到同一 App 时间线

#### Scenario: 更换助理会话

- **GIVEN** 默认助理频道已连接 task A
- **WHEN** 用户连接 task B
- **THEN** App 停止并移除该频道到 A 的 Subscription，只保留 B

#### Scenario: 用户修改昵称

- **GIVEN** 默认助理频道已经存在
- **WHEN** 用户保存新昵称
- **THEN** 该频道标题立即显示新昵称

#### Scenario: 助理 task 不可用

- **GIVEN** 已配置 task 被归档、删除或 Host 不可用
- **WHEN** 外部消息到达
- **THEN** App 保留消息并显示需要重新连接，不向其他 task 投递

### Requirement: 新建专属会话使用稳定的默认工作目录

App MUST 自动创建用户私有的 `~/Pijoo` 目录，并把它作为新建专属 Codex 会话的工作目录；用户连接已有会话时，MUST 保留已有会话原本的工作目录。

#### Scenario: 新建专属会话

- **WHEN** 用户在 App 中新建专属会话
- **THEN** App 不要求用户选择目录
- **AND** 新会话的工作目录为 `~/Pijoo`

### Requirement: 频道按成员数量呈现为用户对话

App MUST 保持 Channel 为唯一数据模型。默认助理频道 MUST 显示当前用户昵称；恰有两名
active Member 的频道 MUST 显示为“好友”，标题优先使用对方昵称；其他频道保持频道或群聊语义。

#### Scenario: 双人好友频道

- **GIVEN** 当前账号所在 Channel 恰有两名 active Member
- **WHEN** App 恢复账号频道或刷新成员
- **THEN** 列表将其标记为“好友”并显示另一名 Member 的昵称

#### Scenario: 成员数量变化

- **GIVEN** 一个好友频道增加第三名 active Member，或其中一人被移除
- **WHEN** App 刷新成员摘要
- **THEN** 该频道不再显示为“好友”，且不引入另一套私信数据模型

### Requirement: 历史读取默认无权并按 task 授权

App MUST 只读检索本机 allowlist 中的 Codex task。授权列表 MUST 按账号保存在本机，默认为空，
且 MUST NOT 由联系人消息或模型输出修改。

#### Scenario: 读取已授权 task

- **GIVEN** 用户已在 owner UI 授权 task A
- **WHEN** 助理检索与 A 匹配的历史
- **THEN** App 返回有界文本片段及 A 的 task id 和标题，不修改 A 或创建 turn

#### Scenario: 读取未授权 task

- **GIVEN** task B 不在 allowlist
- **WHEN** 任意调用请求读取 B
- **THEN** App 拒绝请求，且不返回 B 的标题、正文或存在性细节

#### Scenario: 撤销历史授权

- **GIVEN** task A 曾被授权
- **WHEN** 用户撤销 A 后再次检索
- **THEN** App 立即拒绝读取 A，不依赖后台索引清理

### Requirement: 历史结果有来源且有界

历史读取 MUST 限制 task 数、片段数和总文本长度，并为每段提供来源 task。Pijoo MUST NOT 上传
历史正文、allowlist 或工作目录到 Channel Service。

#### Scenario: 大量匹配

- **GIVEN** 多个已授权 task 含有大量匹配内容
- **WHEN** 助理执行检索
- **THEN** 只返回配置上限内的片段，并明确结果已截断

#### Scenario: App Server 断开

- **GIVEN** Codex App Server 不可用或响应不兼容
- **WHEN** 助理检索历史
- **THEN** 读取失败关闭并显示可重试错误，不扫描 Codex 内部文件兜底

### Requirement: 外部回复必须由用户确认

助理 MUST 把面向联系人的回复作为草稿。没有当前用户的明确确认，App MUST NOT 调用发送链路；
可靠回执前 MUST NOT 把草稿标记为已发送。

#### Scenario: 只生成草稿

- **GIVEN** 联系人消息已进入助理 task
- **WHEN** 助理形成回复但用户没有确认发送
- **THEN** 联系人端不收到消息，草稿保持未发送状态

#### Scenario: 用户确认发送

- **GIVEN** 用户已查看草稿并明确确认
- **WHEN** App 调用现有发送链路且收到可靠回执
- **THEN** 草稿转为已发送并保留对应消息 id

#### Scenario: 回执未知

- **GIVEN** mutating 请求已发出但回执丢失
- **WHEN** App 无法确定结果
- **THEN** 状态为 unknown，App 不自动重试或声称已发送
