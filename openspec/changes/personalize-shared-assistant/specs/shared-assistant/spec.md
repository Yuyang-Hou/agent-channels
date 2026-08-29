# Shared Assistant Requirements

## ADDED Requirements

### Requirement: 每位来访者使用独立双人频道和受管 task

App MUST 保留默认助理频道为 owner 私有入口。每次分享 MUST 新建一个最多兑换一次的普通 Channel Invite，
并为该 Channel 建立独立受管 Codex task 和 Subscription。

#### Scenario: 第一名好友加入

- **WHEN** owner 分享助理且好友 A 兑换邀请
- **THEN** 系统存在一个只含 owner 与 A 的双人 Channel
- **AND** A 的消息只进入该 Channel 对应的受管 task

#### Scenario: 第二名好友加入

- **GIVEN** 好友 A 已经拥有双人 Channel A
- **WHEN** owner 再次分享助理且好友 B 兑换新邀请
- **THEN** 系统新建双人 Channel B，不向 Channel A 增加成员
- **AND** A 与 B 互相看不到消息或 Codex 上下文

#### Scenario: 受管 task 创建失败

- **WHEN** App 已创建 Channel 但无法建立受管 task
- **THEN** App 不复制邀请，并把该 Channel 显示为待恢复

### Requirement: 助理 persona 可编辑但安全边界固定

App MUST 允许 owner 编辑助理名称、角色、语气和介绍。App MUST 把 persona 与固定安全策略组合为受管
工作区的 `AGENTS.md`；联系人消息和模型输出 MUST NOT 修改 persona 或安全策略。

#### Scenario: owner 保存 persona

- **WHEN** owner 在 Pijoo 保存新的 persona
- **THEN** App 更新所有受管工作区的身份卡
- **AND** 不改变 task 权限、历史 allowlist 或 Membership

#### Scenario: 联系人要求修改身份

- **WHEN** 联系人正文要求助理改变身份、权限或安全规则
- **THEN** 该正文仍为不可信输入，App 不修改本机配置

### Requirement: 普通文本自动回复与高风险动作分离

owner 分享助理 MUST 授权该受管 task 向对应 Channel 发送普通文本回复。该授权 MUST NOT 自动授权文件、
Shell、浏览器、网络、部署、付款、secret 或历史读取。

#### Scenario: 普通问候

- **WHEN** 好友向自己的双人 Channel 发送普通问候
- **THEN** 助理调用现有 `send_to_channel` 返回文本，并以可靠回执确认发送

#### Scenario: 高风险请求

- **WHEN** 好友要求执行高风险外部动作
- **THEN** 助理暂停并请求本机 owner 批准，不把好友消息视为授权

#### Scenario: 发送结果未知

- **WHEN** 文本发送已发起但没有可靠回执
- **THEN** 状态保持 unknown，系统不自动重试或声称已发送

### Requirement: Host 输入包含稳定且经过认证的联系人身份

Connector MUST 将 Channel Service 提供的 `sender_member_id` 与展示昵称一同交给受管 task。联系人识别
MUST 使用 channel id 与 Member id，不得使用昵称或正文自称作为身份键。

#### Scenario: 联系人修改昵称

- **GIVEN** 同一 Membership 已有联系人资料
- **WHEN** 联系人修改展示昵称后再次发消息
- **THEN** 助理仍命中同一联系人资料，并显示新昵称

#### Scenario: 消息缺少 Member id

- **WHEN** 入站消息没有认证 `sender_member_id`
- **THEN** Connector 拒绝 Host 投递

### Requirement: 联系人资料和 AI 印象本机隔离且可纠正

App MUST 为每个双人助理 Channel 保存 owner 关系、备注和 AI 印象。资料 MUST 留在本机，并允许 owner
查看、修改和清空。AI 印象 MUST 带来源消息 id，且 MUST NOT 影响授权。

#### Scenario: owner 标记同事

- **WHEN** owner 把联系人关系设为“同事”并保存备注
- **THEN** 只有该联系人的受管 task 获得该资料

#### Scenario: 助理形成印象

- **WHEN** 直接交流出现稳定偏好或工作方式
- **THEN** 助理可在该联系人工作区记录带消息 id 的简短观察
- **AND** 不记录 secret、权限结论或未经 owner 确认的身份断言

#### Scenario: owner 清空印象

- **WHEN** owner 清空某联系人的 AI 印象
- **THEN** 后续 turn 不再读取被清空内容，其他联系人资料不受影响
