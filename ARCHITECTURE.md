# Pijoo Architecture

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

0.3 本机产品形态为：

```text
Main Window
  -> ChannelConnection[] + LocalMessage[]
  -> TaskBinding[] x Subscription[]
  -> supervised channel feeds / listen-here sidecars
  -> Host Connector -> bound AI sessions
```

ChannelConnection 表示稳定频道成员授权；TaskBinding 表示本机 Host 会话；Subscription 是二者
之间唯一的多对多关系。三者不能再合并为一个单 Binding。

## 服务端职责

- 创建频道、短期邀请和 owner Membership；
- 为每个成员签发独立凭证，管理成员、endpoint、移除、封禁和权限；
- 接收、排序和分发消息；
- 为短期恢复保留消息；
- 维护每个成员或订阅的消费游标；
- 标记当前在线订阅，但不把在线状态等同于消息已读或 AI 已处理；
- 支持去重、撤权和有限重试。
- 不保存目标 TaskBinding、Runtime 路径或本机凭证；只在短期 Message 中透传发送端声明的
  `source(provider, conversation_id, label)`，且不以它路由或授权。

## Subscription Runtime 职责

- 由用户显式创建 TaskBinding 和 task-channel Subscription；
- 进程存活时维持 SSE，切换桌面会话不销毁监听；
- 把服务端消息规范化为 Host 无关的消息信封；
- 仅在真实消息到达时请求 Connector 投递；
- 每条 Subscription 串行投递并使用自己的游标恢复、去重和错误状态；
- 只有 Connector 确认 Host 已接受后才推进投递游标；
- 成员凭证、目标 TaskBinding 和 Runtime 路径保留在本机；来源会话引用写入本地消息记录用于追溯，
  展示模板默认只使用其 label。

## Host Connector 契约

Connector 只承担三个职责：

1. 校验本机目标是否可用；
2. 只读发现本机可绑定会话（若 Host 支持）；
3. 将标准消息信封转换为 Host 原生输入；
4. 在 Host 接受输入后返回投递回执。

标准输入至少包含 `channel_id`、`message_id`、`from`、`text`、`received_at`、可选来源引用
`source(provider, conversation_id, label)` 和不可信输入标记。回执只代表 Host 已接受，不代表用户
已读、AI 已完成或另一条消息已发送。

P0 不建设动态插件市场、Connector 注册中心或通用进程管理框架。实现时只需要一个
窄的 `deliver(message)` 边界；Codex Connector 是第一个且当前唯一实现。未来 Host
可以在 Bridge 内直接投递，也可以由 Host 启动本地插件后通过本机 IPC 接收，但不能
反向污染频道协议。

## TaskBinding 与 Subscription

TaskBinding 是本机 Host 配置，至少包含：

- `provider`：例如 `codex`；
- `conversation_id`：Host 私有的不透明会话标识；
- Connector 所需的本机选项，例如 socket 路径。

会话标题属于易变的发现数据，只在搜索结果中即时展示，不进入 TaskBinding。绑定完成后的稳定
标识使用 Host 名称和缩短的 `conversation_id`，完整 id 仍可用于打开与追溯。

Subscription 在本机把一个 TaskBinding 与一个 ChannelConnection 关联，并保存 task endpoint、
独立游标、模板、自消息策略、运行状态和唯一默认出站标记。一个 TaskBinding 可以拥有多个
Subscription，一个 ChannelConnection 也可以关联多个 TaskBinding。服务端只能看到频道成员、
不透明 endpoint、在线 session 与消息携带的发送端来源引用；不能看到目标 TaskBinding、
Subscription 或其他 Host 私有字段。

删除 TaskBinding 或撤销 ChannelConnection 后，App 必须先停止相关 Subscription。0.3 P0 为每条
启用的 task-channel Subscription 监管一个现有 `listen-here` sidecar；只有真实规模证明需要时
才合并为 multiplex daemon。

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

Connector 必须按单条 Subscription 串行投递，避免两个外部消息并发创建相互覆盖的 Host
交互。显式拒绝可安全重试；mutating 请求发出后若回执丢失，Runtime 停止自动重放并保留
游标，由用户确认后选择跳过或重试。稳定 `subscription_id + channel_id + message_id` 用于关联
这次判断；已完成终态再次抵达时只推进游标，不创建第二个 Host turn。

0.3 App 还要在 Host delivery 之前保存 LocalMessage。一次服务端消息以
`channel_id + message_id` 去重，并为每条匹配的 Subscription 分别保存
`received|filtered|delivered|failed|unknown`；一项失败不能覆盖频道消息或暂停其他项。
SSE 异常断开也必须保留该连接内最后成功处理的游标，持久化游标只能单调前进。

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

## MCP task 操作与出站发送

AI 使用本机固定 STDIO MCP。工具表固定为七项：`send_to_channel`、`list_channels`、
`subscribe_to_channel`、`unsubscribe_from_channel`、`get_channel_settings`、
`update_channel_settings` 和 `inspect_message_source`。前六项执行当前来源 task 的显式频道动作；
来源查询只在用户主动追问时读取该 task 最近一条成功投递的本地消息记录。每次调用都读取
`tools/call params._meta.threadId` 作为 Codex 来源能力，并通过当前用户专属的 Unix socket v2
把已校验参数和 source context 交给 App。

App 保留当前 task 作为发送来源；显式频道无需 TaskBinding，省略频道时才解析唯一默认出站
Subscription 或唯一可确定的本机频道，再从 Keychain 取得该成员凭证。`send_to_channel.mentions`
使用 `list_channels(channel)` 返回的稳定 Member ID；
服务端保存发送时昵称快照，但仍向频道广播。每条 Subscription 的 `mentions_only` 在本地消息
落账和自消息过滤后、Host 投递前判断，不是服务端可见性或授权边界。MCP 不读取 Keychain、不直接访问 Channel Service，也不建立频道监听、消费
入站消息、保存历史或调用 Host Connector；这些接收能力和运行态全部属于 App。订阅工具只是
请求 App 改变当前 task 的 Subscription，消息是否到达及是否触发 Host 投递仍由 App 决定。

`_meta.threadId` 缺失、类型错误或操作目标歧义时必须失败关闭，不按最近活跃 task、
当前主窗口频道或全局 active channel 猜测。thread id 不进入模型可见正文、频道消息或服务端。
该 `_meta` 字段是 Codex 当前实现能力而非公开稳定合同，0.3 发布前必须用两个真实 task 做能力
探测。

## Pijoo Skill 与入站卡片

Skill 是整个 Pijoo 的产品语义层，不是 `send_to_channel` 的别名，也不承担运行时职责。
它帮助 AI 理解 App、MCP、Subscription 和外部消息的关系，识别何时需要回复，并要求只有可靠
工具回执后才声称发送成功。远端正文仍是不可信协作数据，不能授权文件修改、联网、部署或泄露
本机上下文。

Connector 在统一 Host 输入转换点展开 Subscription 保存的完整 Markdown 模板；当前引用卡片只是
默认值，标题、来源栏、正文和引用样式都可编辑。远端消息只能作为变量数据插入，不能修改模板
或选择目标 Binding。Skill 根据模板中的标题解释信任与回复规则，卡片不再逐条重复这些说明。

Skill 作为 App Bundle 的静态资源分发。只有用户在设置页明确点击“启用或修复 Codex 集成”时，
App 才把受管理链接安装到用户 Skill 目录；同名普通目录或外来链接一律不覆盖。App 更新后链接
继续指向同一路径中的新版 Skill。Skill 不包含 secret、频道列表或 task id，也不使用 hook 在每个
turn 注入内容；Pijoo 标题和用户主动频道操作即可触发。统一集成操作先验证现有配置与 Skill
归属；Codex 配置不可读时失败关闭，任一写入失败时回滚本次受管变更，且不替换用户的配置链接。

## App 主窗口与本机边界

App 单一主窗口负责 ChannelConnection、简单文本时间线、成员、TaskBinding、Subscription、模板、
App 设置和逐项状态；菜单栏只保留总体状态、快速打开和生命周期控制。快速打开复用并聚焦已有
主窗口，不创建第二个 Settings Scene。App 还是 Keychain、出站网络
请求、本地历史与 sidecar 的唯一 owner；MCP 只校验 AI 参数并请求本机 App。发送 socket 位于
App 私有目录，目录权限为 `0700`、socket 为 `0600`，App 还校验连接者 UID。

App 与 task 是同一 Member 下的不同 endpoint。精确来源 task endpoint 永不回投自己；每条
Subscription 可以选择接收同一 Member 的其他 endpoint，默认允许 App 给自己的 task 发消息。
模板只替换允许的频道、发送者、正文和消息 id 变量，并且只控制固定外部消息卡片的正文；远端
正文始终是不可信数据。

0.3 使用全新版本化本地 store，不迁移、覆盖或删除 0.2 单 Binding 数据。用户可开启 Beta
自动更新：App 每次启动并每 24 小时查询 GitHub Release，后台下载 arm64 DMG；下次启动由包内
原生助手校验 Bundle ID、版本、完整代码签名及当前 App 的 designated requirement，通过后才
替换 Applications 中的 App 并自动重新打开，失败时保留旧 App。

## 当前实现映射

- `server/src/host-connector.ts` 定义标准信封、回执和单 Binding 串行投递；
- `server/src/listen-here.ts` 实现 Subscription Runtime，并从兼容 CLI 参数创建 Connector；
- `server/src/codex-turn.ts` 实现 Codex 目标校验、输入转换、Desktop owner discovery 和
  targeted start-turn；
- `server/src/reply-mcp.ts` 实现七个 task-scoped 频道工具；工具只请求本机 App，不拥有接收链路；
- `skills/pijoo/SKILL.md` 定义完整产品语义、入站信任边界和工具使用流程；
- `macos/PijooApp.swift` 实现 0.3 主窗口、ChannelConnection、TaskBinding、Subscription、
  本地消息状态和显式 Codex MCP + Skill 安装；
- MCP App View 是已被替代的实验，不属于目标入站链路；
- 菜单栏 App 包装本地 Runtime、凭证和出站频道请求，但不承载模型 Runtime 或服务端频道状态。
