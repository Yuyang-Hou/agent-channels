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

Host Connector 拥有目标校验、Host 私有格式转换和投递。当前 Codex Connector 负责
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

现有 `--codex-thread` 和 `--codex-socket` 作为 Codex P0 入口保留；后者只用于覆盖 Desktop
IPC endpoint。默认发现 `${CODEX_HOME:-~/.codex}/ipc/ipc.sock`，并仅在属主和目录权限安全
时尝试旧版临时目录 endpoint。Connector 不删除 stale socket，也不自行启动 IPC router。
未来出现第二个 Connector 时，再把 CLI 表达升级为显式 `--host` 配置；在此之前不提前
增加通用配置层。

用户执行带 `--codex-thread` 的监听命令即表示绑定该 task。ChatGPT Desktop 必须运行，
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

## 信任边界

标准信封必须保留来源并标记正文为不可信外部输入。Connector 可以使用 Host 原生来源
元数据，但不能把远端提供的会话 id 当成可信来源或跳过 Host 权限。高风险工具行为仍由
目标 Host 的权限模型决定。P0 每条消息先尝试 steer-turn，明确没有 active turn 时才发送
start-turn；不启用 `following`，因此不接收、持久化或上传目标 task 的 snapshot。频道凭证、
IPC endpoint 和 Binding 不进入模型正文。

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
接受、Host 不可用时如何失败。当前只隔离 `deliver` 调用点；只有第二个 Connector
真正实现时才提取 Connector 间共享帮助代码或引入 registry、通用配置与 SDK。
