# Channel Service Account Delta

## MODIFIED Requirements

### Requirement: 邀请式频道收发

服务 MUST 要求 active Account Session 创建频道或接受邀请，并通过该 Account 在目标频道中的
active Membership 授权 session、send、listen、history、member 和 invite 请求。服务 MUST NOT
继续把 Member credential 作为账号版的常规频道授权。

#### Scenario: 创建频道

- **GIVEN** 请求持有 active Account Session
- **WHEN** 用户创建频道
- **THEN** 服务在同一事务中创建 Channel 与该 Account 的 owner Membership，不返回频道 credential

#### Scenario: 接受邀请

- **GIVEN** active Account 持有未过期、未撤销且未用尽的邀请
- **WHEN** 它接受邀请
- **THEN** 服务在同一事务中增加使用次数并创建或恢复该 Account 的唯一 Membership

#### Scenario: 已加入账号重复接受

- **GIVEN** Account 已有 active Membership
- **WHEN** 它再次提交有效邀请
- **THEN** 服务幂等返回现有 Membership，不消耗邀请次数或创建重复成员

#### Scenario: removed 账号重新加入

- **GIVEN** Account 的 Membership 为 removed
- **WHEN** 它使用一份有效新邀请加入
- **THEN** 服务恢复同一个 Membership 并消耗一次邀请次数

#### Scenario: banned 账号绕过邀请

- **GIVEN** Account 的 Membership 为 banned
- **WHEN** 它从任意 Device 使用任意新邀请加入
- **THEN** 服务拒绝且不消耗邀请次数，直到 owner 解除封禁

#### Scenario: 未授权访问

- **GIVEN** 请求缺少 active Session、Device 已撤销或 Account 没有目标频道 active Membership
- **WHEN** 请求 session、send、listen、history、members 或 invites
- **THEN** 服务拒绝且不返回频道消息、成员、endpoint 或邀请数据

#### Scenario: 所有权转移

- **GIVEN** owner 选择一个 active member
- **WHEN** owner 确认转移频道
- **THEN** 服务原子地把目标 Membership 设为 owner、原 owner 设为 member，频道始终只有一个 owner

### Requirement: 有限恢复语义

服务 MUST 持久化 Account、Device、Session hash、Channel、Membership、Invite 和撤权状态；在线
session、SSE stream 和有限消息缓冲仍可保留在单进程运行态。恢复 MUST 同时校验 Session、Device
与 Membership。

#### Scenario: 账号设备短暂断线

- **GIVEN** Account Session、Device 和 Membership 都 active，消息仍在有限恢复窗口
- **WHEN** 同一 Device 使用新在线 session 与本机 endpoint 重连
- **THEN** 服务允许从本机游标继续读取，且不返回其他 Device 的本机投递状态

#### Scenario: Device 撤销期间断线

- **GIVEN** Device 已被撤销
- **WHEN** 旧进程在网络恢复后尝试重连
- **THEN** 服务拒绝并保持 stream 关闭，不因旧 Session 尚未到期而恢复

#### Scenario: 服务重启

- **GIVEN** PostgreSQL 可用
- **WHEN** Channel Service 重启
- **THEN** Account、Device、Session、Membership、Invite 和 removed/banned 状态恢复
- **AND** 在线 session 与内存消息不保证恢复
