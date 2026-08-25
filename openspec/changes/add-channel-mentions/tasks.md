# Tasks

## 1. Contract And Service

- [x] 增加 mention 类型、请求校验、active Member 快照和 send/history/SSE 透传
- [x] 保持 `to` 路由、旧消息与未带 mention 客户端兼容
- [x] 覆盖 @所有人、多人、重复、混用、空列表、超过 100 人和失效成员

## 2. Delivery And MCP

- [x] listen-here 在 record_received 与自消息过滤后执行 mentions_only，并记录明确过滤原因
- [x] `send_to_channel` 透传 `mentions`，`list_channels(channel)` 返回当前 task 可用成员
- [x] `{mentions}` 进入 Host 输入和发送成功模板，不改变可靠发送/unknown 语义

## 3. macOS Product

- [x] 消息输入框支持不@、@所有人和多成员选择，成功清空、失败保留
- [x] 消息历史显示提及快照；成员改名或离开不改写历史
- [x] 每条“转发到会话”增加所有消息/仅@我，并兼容旧 App state

## 4. Verification

- [x] 服务端测试、typecheck、build 和 macOS self-test 通过
- [x] 严格 OpenSpec 与 diff 检查通过
- [ ] 两名成员、两个 App/AI endpoint 真实验证多人@、@所有人、不@及仅@我矩阵
