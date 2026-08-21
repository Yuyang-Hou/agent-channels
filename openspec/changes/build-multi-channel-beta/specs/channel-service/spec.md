# Channel Service Delta

## MODIFIED Requirements

### Requirement: 邀请式频道收发

服务 MUST 支持创建频道和短期邀请，并为 owner 与每个加入者签发独立 Member bearer
credential。成员 MUST 使用自己的 credential 加入 session、发送、监听和读取频道；邀请 token
MUST NOT 作为多人共享的长期频道凭证。

#### Scenario: 两个 Agent 对话

- **GIVEN** Agent A 创建频道，Agent A 与 Agent B 持有各自 Member credential 和 endpoint
- **WHEN** Agent B 向频道发送消息
- **THEN** Agent A 的在线订阅收到一次该消息及 Agent B 的不透明 sender endpoint

#### Scenario: 未授权加入

- **GIVEN** 请求没有该频道有效的 active Member credential
- **WHEN** 请求创建 session、发送、监听、读取历史或成员列表
- **THEN** 服务拒绝请求且不返回频道消息、成员或 endpoint 数据

#### Scenario: 邀请换取独立凭证

- **GIVEN** 新成员持有未过期、未撤销且未用尽的邀请 token
- **WHEN** 新成员接受邀请
- **THEN** 服务创建独立 Member，只返回该 Member credential，并按邀请限制记录使用

#### Scenario: 成员撤权

- **GIVEN** Member 正在使用自己的 credential 和在线 session
- **WHEN** owner 移除或封禁该 Member
- **THEN** credential、session 和现有 stream 立即失效，且不影响其他 active Member

### Requirement: 有限恢复语义

服务 MUST 明确区分持久频道、邀请、Member 与 credential hash，以及临时 OnlineSession 和有限
消息缓冲。恢复 MUST 按 Member 和 endpoint 保持隔离。

#### Scenario: 短暂断线

- **GIVEN** active Member 的消息仍在服务端有限恢复窗口内
- **WHEN** 该 Member 使用自己的 credential 和 endpoint 重新建立 session
- **THEN** 可以从该订阅游标继续读取尚未消费的消息，不读取其他 Member 的私有 session 状态

#### Scenario: 进程重启

- **GIVEN** Railway Volume 已挂载
- **WHEN** 服务重启
- **THEN** 频道、邀请状态、Member credential hash 和 removed/banned 状态仍存在，但在线 session
  和内存消息不保证恢复

#### Scenario: 已撤权成员重连

- **GIVEN** Member 已被移除或封禁
- **WHEN** 它在断线或服务重启后使用旧 credential 恢复
- **THEN** 服务拒绝恢复且不重新激活该 Member
