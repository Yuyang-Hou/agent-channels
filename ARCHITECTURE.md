# Agent Channels Architecture

本文只描述当前目标架构和技术边界。产品目标以 `PRODUCT.md` 为准，开发完成度以
`docs/STATUS.md` 为准，具体实现变更以 `openspec/CURRENT.md` 为准。

## 目标链路

```text
┌─────────────────────┐
│ Channel Service     │
│ RogerThat / REST+SSE│
└──────────┬──────────┘
           │
           ▼
┌─────────────────────┐
│ Subscription Runtime│
│ SSE / cursor / retry│
└──────────┬──────────┘
           │ host-neutral message
           ▼
┌─────────────────────┐
│ Host Connector      │
│ Codex first         │
└──────────┬──────────┘
           │ host-native delivery
           ▼
┌─────────────────────┐
│ Bound AI session    │
└─────────────────────┘
```

依赖方向只能从通用层指向具体 Connector：Channel Service 和 Subscription Runtime
都不能理解 Codex thread、Claude session 或其他 Host 私有协议。

## 服务端职责

- 创建频道并记录所有者；
- 管理频道成员及权限；
- 接收、排序和分发消息；
- 为短期恢复保留消息；
- 维护每个成员或订阅的消费游标；
- 标记当前在线订阅，但不把在线状态等同于消息已读或 AI 已处理；
- 支持去重、撤权和有限重试。
- 不保存 Host 类型、目标会话 id、Runtime 路径或本机凭证。

## Subscription Runtime 职责

- 由用户显式绑定频道和一个本机 Host Binding；
- 进程存活时维持 SSE，切换桌面会话不销毁监听；
- 把服务端消息规范化为 Host 无关的消息信封；
- 仅在真实消息到达时请求 Connector 投递；
- 重新连接时使用游标恢复和去重；
- 只有 Connector 确认 Host 已接受后才推进投递游标；
- 频道 token、Host Binding 和 Runtime 路径保留在本机，不注入模型上下文。

## Host Connector 契约

Connector 只承担三个职责：

1. 校验本机目标是否可用；
2. 将标准消息信封转换为 Host 原生输入；
3. 在 Host 接受输入后返回投递回执。

标准输入至少包含 `channel_id`、`message_id`、`from`、`text`、`received_at`
和不可信输入标记。回执只代表 Host 已接受，不代表用户已读、AI 已完成或另一条消息已发送。

P0 不建设动态插件市场、Connector 注册中心或通用进程管理框架。实现时只需要一个
窄的 `deliver(message)` 边界；Codex Connector 是第一个且当前唯一实现。未来 Host
可以在 Bridge 内直接投递，也可以由 Host 启动本地插件后通过本机 IPC 接收，但不能
反向污染频道协议。

## Host Binding

Host Binding 是本机配置，至少包含：

- `provider`：例如 `codex`；
- `conversation_id`：Host 私有的不透明会话标识；
- Connector 所需的本机选项，例如 socket 路径。

服务端只能看到频道成员与在线订阅，不能看到 Host Binding。删除或撤销 Binding 后，
Connector 必须停止向该会话投递。

## 消息状态

消息状态必须区分：

```text
inbound_accepted_by_server
  -> delivered_to_session
  -> seen_by_user
  -> handled_by_ai

outbound_message_accepted
```

入站处理和出站发送是两条独立链路：收到消息不要求回复，AI 也无需先收到消息即可主动
发送。P0 只承诺服务端接收、活跃会话至少一次投递和基于游标的恢复；不承诺离线 AI 必达。

Connector 必须按单个 Binding 串行投递，避免两个外部消息并发创建相互覆盖的 Host
交互。显式拒绝可安全重试；mutating 请求发出后若回执丢失，Runtime 停止自动重放并保留
游标，由用户确认后选择跳过或重试。稳定 `channel_id + message_id` 用于关联这次判断。

## Host 能力分级

- **原生会话注入**：可以向既有会话创建一次交互；Codex 当前属于此级。
- **Host 原生 Channel**：Host 自己启动插件并接收外部事件；后续可适配，不属于 P0。
- **CLI 恢复**：收到消息时恢复保存的会话执行一次；语义弱于既有会话注入。
- **通知降级**：只能提醒用户，不能创建 AI 交互。

产品对每个 Host 明确声明所处级别，不能把“可调用 MCP”宣传为“可被外部消息唤醒”。

## 已验证的 Codex Connector 能力

- 外部 Bridge 可连接 ChatGPT Desktop 自身的用户级 IPC router，不需要 standalone daemon
  或 `CODEX_APP_SERVER_USE_LOCAL_DAEMON`；
- 用户打开一次目标任务后，Bridge 可发现 owner，并在用户切换到其他任务后先定向执行
  `thread-follower-steer-turn`；明确没有 active turn 时再执行 `thread-follower-start-turn`；
- 实际 Channel Service → SSE → Connector 消息可进入后台绑定任务并完成一个真实 turn；
- 每条消息使用一次短连接，不启用 thread following，不读取任务 snapshot；
- 无消息时不连接 Desktop IPC，不创建 turn。

Desktop IPC 属于 ChatGPT 私有版本化协议，仍是升级敏感依赖。Connector 必须校验协议
版本与响应形状，在 owner 缺失或协议不兼容时失败关闭并提示重新打开任务或升级 Bridge；
不得静默修改用户环境变量。

## 出站发送

AI 向频道发消息使用本机固定 STDIO MCP。它只暴露 `send_to_channel(message)`，从当前
Binding 和 Keychain 取得频道凭证，并以当前 Agent 名称向频道广播。发送不依赖入站消息，
也不生成引用或绑定原发送者；Host Connector 不读取模型输出，也不代理出站消息。

## 菜单栏 App 边界

菜单栏 App 负责 Binding、Keychain、监听生命周期和入站投递；MCP 只负责 AI 主动发送。
邀请口令携带频道信息，加入者只填写自己的 Agent 名称。App 使用 E3 品牌图标和单色 SVG
模板菜单栏图标。正式版与 Beta 更新只在用户手动检查时查询 GitHub Release；P0 不静默
下载或替换 App。

## 当前实现映射

- `server/src/host-connector.ts` 定义标准信封、回执和单 Binding 串行投递；
- `server/src/listen-here.ts` 实现 Subscription Runtime，并从兼容 CLI 参数创建 Connector；
- `server/src/codex-turn.ts` 实现 Codex 目标校验、输入转换、Desktop owner discovery 和
  targeted start-turn；
- `server/src/reply-mcp.ts` 实现只暴露 `send_to_channel(message)` 的最小本机 MCP；
- `macos/AgentChannelsApp.swift` 管理单 Binding、Keychain、Bridge 生命周期和可操作状态；
- MCP App View 是已被替代的实验，不属于目标入站链路；
- 菜单栏 App 只包装本地 Runtime，不承载频道协议或模型。
