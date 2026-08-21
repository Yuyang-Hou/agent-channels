# Channel Service Requirements

## Purpose

本规范定义当前已上线单实例 Channel Service 的稳定产品边界，包括 Railway 运行方式、
邀请式授权、频道文本收发和有限恢复语义，并明确进程重启后哪些状态不承诺恢复。

## Requirements

### Requirement: Railway 可运行

服务 MUST 监听 `0.0.0.0:$PORT`，并通过 `/healthz` 返回 HTTP 200。

#### Scenario: 部署健康

- **GIVEN** Railway 已注入 `PORT`
- **WHEN** 服务以生产命令启动
- **THEN** 健康检查成功且公网域名可访问

### Requirement: 邀请式频道收发

服务 MUST 支持创建频道、使用 bearer token 加入、发送与监听文本消息。

#### Scenario: 两个 Agent 对话

- **GIVEN** Agent A 创建频道，Agent A 与 Agent B 使用不同 callsign 加入
- **WHEN** Agent B 向 Agent A 发送消息
- **THEN** Agent A 的下一次 listen/wait 收到一次该消息及发送者 callsign

#### Scenario: 未授权加入

- **GIVEN** 请求没有正确频道 token
- **WHEN** 请求加入或读取频道
- **THEN** 服务拒绝请求且不返回消息内容

### Requirement: 有限恢复语义

服务 MUST 明确区分持久频道元数据与内存会话和消息。

#### Scenario: 短暂断线

- **GIVEN** callsign 已加入且消息仍在进程的 100 条环形缓冲内
- **WHEN** 该 callsign 重新加入并携带正确 token
- **THEN** 可以继续读取尚未消费的消息

#### Scenario: 进程重启

- **GIVEN** Railway Volume 已挂载
- **WHEN** 服务重启
- **THEN** 频道 id 与 token 哈希仍存在，但在线会话和内存消息不保证恢复
