# Design

## Minimal Product Shape

```text
Default assistant (title = user nickname) = designated one-member Channel
  -> App endpoint + one Codex task endpoint

Friend = two-member Channel
  -> existing account/channel/SSE transport

Codex task -> allowlisted local history reader
```

## Local Authorization

`AssistantConfig` 按账号本机保存 `assistantChannelID`、`assistantTaskID`、`allowedHistoryTaskIDs` 和固定 `draft` 模式。
默认 allowlist 为空。新增授权必须由本机 owner UI 发起；联系人消息和模型文本不能修改授权。
撤销后下一次读取立即失败，不保留后台索引或完整历史副本。

## History Reader

读取器通过 Codex App Server STDIO 初始化后调用 `thread/read(includeTurns: true)`。调用前先解析并
校验 task id，再验证它存在于 allowlist。输出只保留用户与助理的文本内容，按当前查询做简单的
大小写不敏感匹配，并限制任务、片段和字符数。每段带 task id 与 task 标题；找不到结果明确返回空。

P0 不引入 embedding。线性扫描是刻意上限；当真实授权历史规模导致可测延迟时再增加索引。

## Relay Boundary

现有 Channel Service 同时传递 App、助理会话与好友消息，不接触 Codex 历史、画像、task id 或
工作目录。默认助理只是一个由 App 自动指定、以用户昵称显示的单人频道；好友是两人频道。远端消息是不可信输入，
不能扩大读取、发送或执行权限。

## Outbound Boundary

助理可以生成草稿，但 P0 不保存或执行自动回复规则。只有用户明确确认后才调用现有
`send_to_channel`，并以可靠回执作为“已发送”的唯一依据。

## Failure Behavior

- App Server 不可用或协议不兼容：历史读取失败关闭，频道收发继续工作；
- task 未授权或已撤销：不读取标题或正文；
- 外部投递回执未知：保留 unknown，不自动重试；
- 本机配置损坏：回到默认无授权，不猜测助理 task。
