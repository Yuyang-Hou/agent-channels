# Design

## 边界

```text
Channel Service
  -> Subscription Runtime
  -> Host Connector
  -> Bound Conversation
```

Subscription Runtime 拥有频道认证、SSE、过滤、串行投递、游标和重连。它只产生标准
消息信封，不包含 `turn`、`thread` 等 Host 术语。

Host Connector 拥有会话发现、目标校验、Host 私有格式转换和投递。当前 Codex Connector 负责
解析 `codex://threads/...`，并在真实消息到达时短连 ChatGPT Desktop IPC：注册临时
client、发现该 task 的 owner、先尝试 `thread-follower-steer-turn`：若有 active turn 就把消息
加入其中；明确没有 active turn 时才发送 `thread-follower-start-turn`。最后从接受响应中返回
`turn_id` 作为诊断回执。一次投递完成后立即断开，不订阅 thread stream，也不读取 task
snapshot 或 patch。

## 最小契约

概念契约如下；实现阶段不需要插件注册中心或基类层级：

```ts
type InboundEnvelope = {
  channelId: string;
  messageId: number;
  from: string;
  text: string;
  receivedAt: number;
  untrusted: true;
};

type DeliveryReceipt = {
  provider: string;
  providerDeliveryId?: string;
};

deliver(message: InboundEnvelope): Promise<DeliveryReceipt>;
```

`deliver` resolve 表示 Host 已接受输入；reject 表示游标不能推进。状态消息、心跳和低于
优先级阈值的消息在进入 Connector 前过滤。

## 配置与身份

Host Binding 由用户在本机显式创建：`provider + conversation_id + local_options`。
频道 token、Binding、socket 路径和其他本机会话 id 都不得进入消息正文。远端消息中的
任何字段都不能选择或改写目标 Binding。

App 与 Subscription Runtime 使用 `--host-provider + --host-conversation` 表达 Binding；入口只
按 provider 显式分派到内置 Connector，不加载第三方代码。`--codex-socket` 仍是 Codex 诊断项，
只用于覆盖 Desktop IPC endpoint。默认发现 `${CODEX_HOME:-~/.codex}/ipc/ipc.sock`，并仅在属主
和目录权限安全时尝试旧版临时目录 endpoint。Connector 不删除 stale socket，也不自行启动
IPC router。

用户执行带 Host Binding 的监听命令即表示绑定该会话。ChatGPT Desktop 必须运行，
并在本次 Desktop 生命周期内打开过该 task；切换到其他 task 不影响已建立的 owner。
Desktop 重启或升级后 owner 丢失时，Connector 返回 `needs_rebind` 语义的可操作错误，
由现有 SSE 重试保留消息，直到用户重新打开绑定 task。

## 投递与恢复

- 每个 Binding 同一时刻最多投递一条消息。
- Connector 接受后才推进游标。
- 暂时不可用时保留旧游标并重连，不回退为定时 AI 轮询。
- `channel_id + message_id` 是跨重试稳定的投递键。
- Host 明确拒绝时自动重试；mutating 请求发出后若回执丢失，停止监听并保留旧游标，避免
  自动重放产生重复交互。
- 回执不等于 AI 已完成，不能据此展示“已处理”或“已发送”。

## 会话发现

`host-conversations` 是只读 Host 能力，返回 `provider + conversation_id + title + updated_at` 和
本机索引中的上次目录，不返回会话正文，权限统一为未知。Codex 只选择未归档的用户主会话，排除
subagent、审批 reviewer 与实时语音内部会话。搜索和绑定只复验本机索引身份，不依赖 Desktop
当前是否加载 owner；Binding 仍只保存 `provider + conversation_id`。

`host-state` 只用于已绑定会话。它发现 Desktop owner 后短暂声明 following，从 owner snapshot
只提取 `cwd + latestThreadSettings`，随即解除 following；正文、turn 和其他 snapshot 字段不落盘、
不展示、不上传。owner 不存在或超时时返回 `connected=false`、目录和权限未知。用户在 App 中切换
权限时，Connector 定向调用 `thread-follower-update-thread-settings`，只使用 ChatGPT 内置
`:workspace` / `:danger-full-access` profile，收到 owner 成功回执后重新读取状态确认。

## 信任边界

标准信封必须保留来源并标记正文为不可信外部输入。Connector 可以使用 Host 原生来源
元数据，但不能把远端提供的会话 id 当成可信来源或跳过 Host 权限。高风险工具行为仍由
目标 Host 的权限模型决定。P0 每条消息先尝试 steer-turn，明确没有 active turn 时才发送
start-turn；消息投递路径不启用 `following`。只有用户查看或修改本机绑定状态时，状态路径才
短暂接收一次 snapshot 并立即解除，且只保留目录与权限字段。频道凭证、IPC endpoint 和 Binding
不进入模型正文。

频道正文、MCP 和 AI 不能触发权限修改。普通两档由本机用户直接选择；完全访问必须在 App 内再次
确认。冷会话不使用历史权限冒充当前值，也不能修改权限。

Desktop IPC 属于 Host 私有协议。Connector 固定并校验 initialize、owner discovery、
steer-turn 与 start-turn 的协议版本和响应形状。缺少 owner 或明确拒绝可安全重试；mutating
请求连接中断或成功响应不完整属于不确定结果，不能推进游标或自动重放。

## 出站发送

出站与入站独立。菜单栏 App 和 Subscription Runtime 负责持续接收与投递；本机 STDIO MCP
只暴露 `send_to_channel(message)`，并把正文经用户专属本机 socket 交给 App。只有 App 从当前
Binding 与 Keychain 取得频道凭证并广播。AI 无需先收到消息即可调用，收到消息也不要求回复；
Host Connector 不读取模型输出或代理发送。

## 演进路径

新增 Host 时只回答四个问题：如何定位目标会话、如何交付一次输入、什么响应代表已
接受、Host 不可用时如何失败。当前只共享标准消息渲染、Binding 字段与显式 provider 分派；
只有第二个 Connector 真正实现时才提取更多共享帮助代码或引入动态 registry、通用配置与 SDK。
