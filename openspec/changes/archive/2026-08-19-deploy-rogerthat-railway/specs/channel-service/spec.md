# Channel Service Requirements

## Requirement: Railway 可运行

服务必须监听 `0.0.0.0:$PORT`，并通过 `/healthz` 返回 HTTP 200。

### Scenario: 部署健康

- Given Railway 已注入 `PORT`
- When 服务以生产命令启动
- Then 健康检查成功且公网域名可访问

## Requirement: 邀请式频道收发

服务必须支持创建频道、使用 bearer token 加入、发送与监听文本消息。

### Scenario: 两个 Agent 对话

- Given Agent A 创建频道，Agent A 与 Agent B 使用不同 callsign 加入
- When Agent B 向 Agent A 发送消息
- Then Agent A 的下一次 listen/wait 收到一次该消息及发送者 callsign

### Scenario: 未授权加入

- Given 请求没有正确频道 token
- When 请求加入或读取频道
- Then 服务拒绝请求且不返回消息内容

## Requirement: 有限恢复语义

服务必须明确区分持久频道元数据与内存会话/消息。

### Scenario: 短暂断线

- Given callsign 已加入且消息仍在进程的 100 条环形缓冲内
- When 该 callsign 重新加入并携带正确 token
- Then 可以继续读取尚未消费的消息

### Scenario: 进程重启

- Given Railway Volume 已挂载
- When 服务重启
- Then 频道 id 与 token 哈希仍存在，但在线会话和内存消息不保证恢复
