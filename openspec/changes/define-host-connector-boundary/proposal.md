# Proposal: Define Host Connector Boundary

## Why

现有 P0 已证明 RogerThat 消息可以进入 Codex 会话，但共享 App Server daemon 需要额外
安装 Codex CLI、修改 Desktop 运行方式，并可能与已打开会话争夺 active writer。与此同时，
`listen-here` 的配置、消息格式和投递动作直接引用 Codex。继续沿该结构增加 Host，会让
频道传输、恢复逻辑和 Host 私有协议混在一起。

## What Changes

- Channel Service 保持 Host 无关，不保存任何目标会话信息。
- 本地接收链路拆成 Subscription Runtime 与 Host Connector 两个职责边界。
- Codex 是第一个且当前唯一 Connector，不把“架构允许”表述成“产品已支持”。
- Host Binding 只保存在本机，目标会话 id 和 Runtime 路径不进入服务端或模型正文。
- Connector 只保证 Host 接受一次输入；AI 完成、用户已读和另一条消息发送是不同状态。
- 出站发送继续走 MCP/REST，不经过 Host Connector；当前本机 MCP 只暴露
  `send_to_channel(message)`，且不依赖入站消息。
- Codex 默认通过 ChatGPT Desktop 自身的本地 IPC owner/follower 路由投递，不安装
  standalone daemon，也不修改 `CODEX_APP_SERVER_USE_LOCAL_DAEMON`。
- 用户只需显式绑定一个 task；Desktop 重启后 owner 尚未恢复时，Connector 明确提示用户
  打开该 task 一次，并保留消息等待重试。

## 非目标

- 不实现 Claude、Cursor 或其他 Host。
- 不建设动态插件加载、注册中心、SDK、菜单栏 UI 或进程守护。
- 不重写已经工作的 SSE、游标和重连代码。
- 不实现菜单栏 UI、自动选择当前 task 或读取 task 完整历史。
- 不承诺 Host 关闭、Bridge 停止或设备离线后仍能唤醒 AI。

## Impact

每个 Connector 必须明确自己属于原生会话注入、Host 原生 Channel、CLI 恢复或通知
降级中的哪一级。只有 Host 对一次输入给出明确接受回执，Subscription Runtime 才能
推进本地投递游标。Codex Desktop IPC 是私有、版本化协议，Connector 必须失败关闭并给出
可操作错误，不能静默切换 Desktop 环境变量或回退为 AI 轮询。
