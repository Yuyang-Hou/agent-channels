# Agent Channels（暂定名）

## 产品定义

Agent Channels 让两个正在不同 AI 会话中工作的用户，把各自的会话加入同一个协作
频道，使消息能够进入对方的任务上下文；AI 也可以在需要时主动向频道发送消息。

它不是新的聊天客户端，也不是永久在线的独立 Agent。它连接的是用户已经在使用的
AI 会话。

## 用户问题

前端、后端或其他协作者分别在自己的 AI 会话中工作时，两个会话彼此隔离：

- 一方刚确认的接口、约束和进度无法及时进入另一方 AI 的上下文；
- Human 需要在聊天工具与 AI 会话之间重复复制、转述和补背景；
- 普通 MCP 只能在 AI 主动调用时读取消息，无法在真实消息到达时触发既有会话；
- 定时轮询会产生无意义的 AI turn、费用和会话噪声。

## 目标用户与首个场景

首个用户是使用本地 AI 编程工具协作开发的两名研发：

- 用户 A 在自己的电脑和 AI 会话中开发前端；
- 用户 B 在自己的电脑和 AI 会话中开发后端；
- 两个会话加入同一频道；
- 后端会话发送接口信息后，前端会话即使不在前台，也能收到一条真实 AI turn；
- 前端 AI 结合自己的任务上下文处理；它可按需主动发消息，但收到不等于必须回复。

## 核心价值

1. **会话直接协作**：消息进入正在工作的 AI 会话，不需要统一的中转 Agent。
2. **消息驱动**：只有真实消息到达才触发 AI；空闲监听不产生 turn。
3. **切换不掉线**：用户切换到其他会话时，本地监听仍然保持。
4. **上下文留在本机**：频道消息只附带显式来源引用，不上传目标会话 id、工作目录或私有上下文。
5. **Host 可扩展**：产品协议不依赖 Codex；Codex 只是第一个完成验收的 Connector。

## 核心体验

```text
绑定本机 AI 会话
  -> 加入协作频道并开始监听
  -> 切换到其他工作也不影响监听
  -> 对方消息到达时，绑定会话收到一张明确标识来源的外部消息卡片
  -> Agent Channels Skill 帮助 AI 理解频道语义、信任边界和是否需要回复
  -> AI 可随时通过 MCP 操作当前 task 的频道
  -> 暂时断线后明确展示漏掉的消息，而不是静默丢失
```

用户应当能够回答五个问题：自己加入了哪些频道、当前查看哪个频道、每个 task 订阅哪些
频道、各项是否在线、最近一次投递是否成功。用户不需要理解 SSE、Desktop IPC 或 Runtime
协议。

## 产品模型

- **Human**：稳定用户主体。
- **Channel**：多人或多个 AI 会话交换协作消息的空间。
- **Membership**：Human 与 Channel 的长期授权关系，拥有独立、可撤销的频道凭证。
- **Endpoint**：Membership 下的 App 或 task 发送来源；服务端身份仍是不透明 id，消息可另带
  `provider + conversation_id + label` 来源引用供接收端追溯。
- **Conversation Session**：某个 AI Host 中的临时工作会话。
- **TaskBinding**：只保存在本机的 Host 类型与目标会话定位信息。
- **Subscription**：TaskBinding 对 Channel 的显式订阅，独立保存游标、模板、策略和状态。
- **Message**：带稳定 id、来源和顺序的协作事件。
- **Local Message Record**：App 本机保存的消息与逐 Subscription 投递状态，不是永久云历史。
- **Agent Channels Skill**：静态产品语义层，帮助 AI 识别入站卡片并正确使用频道动作；不持有凭证、
  监听或动态频道状态。

稳定授权与临时会话必须分开：0.3 的 `member_id` 只代表某人对某频道的 Membership，
`session_id` 只代表一次在线会话，TaskBinding 也不能成为服务端长期身份。跨频道 Human
账户属于后续范围。

## 0.3 Beta 产品范围

0.3 Beta 在已经验证的单频道链路上交付以下闭环：

- 全新 clean-slate App，不迁移或删除 0.2 单 Binding 数据；
- 原生 macOS 单一主窗口管理多个频道、简单文本时间线、发送、未读、成员、task 订阅与 App 设置；
- owner 与每个成员使用独立凭证，owner 可以移除和封禁成员；
- 本机分别管理多个 TaskBinding 与 task-channel Subscription；
- 添加会话时不预载最近会话列表；用户可按当前 Host 的全部本地会话标题或 id 搜索，并从不改变页面布局的下拉结果中点选，也可直接输入 id/链接；标题只用于当次
  搜索结果，Binding 只保存 `provider + conversation_id`，绑定前始终执行 Host preflight；
- 一个 task 可以订阅多个频道，一个频道也可以绑定多个 task，游标和失败状态互相隔离；
- 真实普通消息触发绑定会话，状态消息和空闲连接不触发；
- App 收到消息先写本地历史，再逐 Subscription 更新 filtered、delivered、failed 或 unknown；
- 每条 Subscription 使用受限的接收模板和发送成功模板，让当前会话同时识别收到的频道消息与
  已可靠进入频道的消息，并明确是否接收同一成员其他 endpoint 的消息；
- 本机 MCP 暴露 `send_to_channel`、`list_channels`、`subscribe_to_channel`、
  `unsubscribe_from_channel`、`get_channel_settings`、`update_channel_settings` 和
  `inspect_message_source` 七个 task-scoped 工具；所有调用都必须通过 Codex `_meta.threadId`
  精确匹配 TaskBinding；来源查询只在用户主动追问时读取当前 task 最近一条成功投递的本地记录；
- AI 可以随时主动发送，不需要先收到消息；频道监听、消息接收、本地历史和 Host 投递仍由 App
  持有，收到消息也不等于 AI 必须回复；
- App 以 Markdown 卡片作为默认收发模板；用户可编辑标题、来源栏、正文和引用样式。发送成功模板
  只生成当前会话的工具回执，不改写频道正文；远端正文只能作为模板数据，不能选择目标 Binding；
- App 在用户明确启用 Codex 集成时同时安装产品级 Agent Channels Skill。Skill 面向完整收发、
  订阅和安全语义，不只是 `send_to_channel` 的工具说明，也不使用每 turn hook；
- 菜单栏浮窗只展示总状态、打开主窗口和监听生命周期；打开时复用、反最小化并聚焦主窗口，
  不创建独立设置窗口；
- 短暂断线按每条 Subscription 的最新游标恢复；已完成终态重放只推进游标，不创建第二个 Host
  turn，单项失败不拖停其他项；
- 两个用户、两台设备、两个频道和至少三个 Subscription 完成真实验收。

Codex 是 0.3 Beta 唯一支持的 Host，但频道、成员、消息、恢复和投递语义不能包含 Codex
私有概念。

## 0.3 Beta 不包含

- Claude、Cursor 或其他 Host Connector；
- 0.2 数据或频道迁移、账户和跨设备身份恢复；
- 附件、富文本、编辑、删除、反应、搜索、永久云历史或完整聊天客户端；
- 任意规则 DSL、脚本、自动回复或 Agent 工作流；
- 所有权转移、复杂角色、组织目录和已公证公开安装包；
- 独立模型 Runtime 或永久在线 Agent；
- 用户关机或 Host 退出后的 AI 自动处理或发送；
- 文件协作和高风险工具自动授权；
- 商业化能力。

## 产品原则

- 不把“可调用 MCP”宣传成“可被外部消息唤醒”。
- 不用空轮询换取在线感。
- 不把在线、已投递、用户已读、AI 已处理和出站消息成功混为一个状态。
- 不把远端消息中的会话 id 当作可信目标。
- 不为尚未实现的第二个 Host 提前建设插件市场或通用 SDK。
- 不能通过真实 Host 验收的能力，不计入产品完成度。

## 0.3 Beta 完成标准

0.3 Beta 只有同时满足以下条件才算完成：

1. 两个独立用户在两台设备上加入两个新频道，并完成 App 双向收发和本地历史恢复；
2. owner 移除或封禁在线成员后，旧凭证的发送、监听和 session 立即失效；
3. 至少三个 task-channel Subscription 完成 App → task、task → App 和 task → task；
4. 两个真实 Codex task 的 `_meta.threadId` 分别精确匹配自身 UUID，消息不按当前 UI 或最近
   活跃 task 猜测路由；
5. 一个 task 订阅两个频道、一个频道绑定两个 task 时不串台，游标与错误互相隔离；
6. 自消息策略、Markdown 外部卡片与 Agent Channels Skill 在真实 turn 中生效，filtered 和空闲
   消息都不产生额外 turn；
7. 短暂断线和 App 重启不静默丢消息，unknown 结果不会自动重复投递；
8. 成员凭证、目标 TaskBinding 和工作目录不进入模型正文或服务端；来源会话引用只作为消息审计
   元数据传递，不作为可信目标或路由依据；
9. Host 不可用、授权失效和 Connector 不支持时，主窗口显示可操作的独立状态。
