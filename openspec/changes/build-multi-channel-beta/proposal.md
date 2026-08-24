# Proposal: Build Multi-Channel Beta

## Why

0.2 Beta 已证明一个频道、一个 Codex task 可以跨设备双向收发，但它仍把频道、成员身份和
task Binding 压在一个本机配置里，也没有可以日常查看消息和管理成员的主窗口。继续在单
Binding 上叠加入口会让多频道、成员撤权和 task 路由互相污染。

0.3 Beta 需要把稳定频道成员、本机 TaskBinding、每 task 的频道 Subscription 和本地消息记录
拆成独立对象，再以真实双 task、双设备验收证明路由不会串台。

## What Changes

- 交付以主窗口为主要入口的全新 0.3 Beta；不迁移 0.2 的单 `binding.json` 或共享频道凭证。
- App 同时管理多个频道，提供频道列表、简单文本时间线、发送框、未读状态和本地历史。
- 服务端为每个频道成员签发独立凭证；邀请仅用于加入，不再成为所有成员共享的长期凭证。
- owner 可以查看成员，并移除、封禁或解除封禁；撤权立即使该成员的发送和监听失效。
- 本机分别保存 `TaskBinding` 与 `Subscription`，支持一个 task 订阅多个频道、一个频道绑定
  多个 task，并为每条 Subscription 保存独立游标、模板、自消息策略和运行状态。
- App 收到频道消息后先落本地 `received` 记录，再分别更新各 Subscription 的
  `delivered`、`failed`、`unknown` 或 `filtered` 状态。
- Codex MCP 从 `tools/call params._meta.threadId` 取得来源 task，经过本机 socket v2 交给 App
  精确路由；缺失、类型错误或未绑定时失败关闭，不按最近活跃 task 猜测。
- MCP 提供发送、频道列表、订阅/取消订阅和订阅设置六个 task-scoped 工具；频道监听、消息接收、
  本地历史和 Host 投递仍由 App 持有，AI 主动发送不依赖先收到消息。
- App 将每条入站消息渲染为固定 Markdown 外部消息卡片；用户模板只控制正文，固定标题和来源栏
  不可定制或被远端 Markdown 逃逸，信任与回复规则由产品 Skill 解释。
- App 显式安装面向完整产品的 Agent Channels Skill，使 AI 理解收发、订阅、信任和回执语义；
  Skill 不是单一工具说明，也不使用每 turn hook。
- 用户可开启 Beta 自动更新；App 后台下载 GitHub Release 的 arm64 DMG，下次启动校验签名并
  原地替换后自动重新打开，无需用户手动下载或拖拽 App。
- P0 Runtime 继续为每条启用的 task-channel Subscription 管理一个现有 `listen-here`
  sidecar；不在本轮建设 multiplex daemon。

## Capabilities

- **New: `multi-channel-beta`** — 主窗口、多频道、本地消息、TaskBinding × Subscription、模板、
  自消息策略和 Codex 来源 task 路由。
- **Modified: `channel-service`** — 从共享频道 token 升级为邀请与成员独立凭证，并持久化成员
  撤权状态。

## Product Decisions

- 0.3 Beta 是 clean-slate Beta。旧数据不自动导入，也不静默删除；验收使用干净用户目录和
  新频道。
- 主窗口是频道与消息管理入口；菜单栏只保留状态、快速打开和生命周期控制。
- App 与 task 是同一成员下的不同 endpoint。精确来源 endpoint 永不回投自己；Subscription
  可以选择是否接收同一成员其他 endpoint 的消息，因此 App 可以给自己的 task 发消息。
- 每个 TaskBinding 可以接收多个频道。`send_to_channel` 可以显式选择已订阅频道；省略频道时
  必须解析唯一默认出站 Subscription，不能按当前 UI 或最近活跃状态猜测。
- MCP 的 `list_channels`、`subscribe_to_channel`、`unsubscribe_from_channel`、
  `get_channel_settings` 和 `update_channel_settings` 只管理当前来源 task 的本机配置，不承担
  SSE 监听、入站消息消费、本地历史或 Host Connector 调用。
- Skill 是静态产品语义层；App 更新时随包更新，不包含频道凭证、动态状态或 task id。安装与移除
  只发生在用户明确操作 Codex 集成时，同名非受管 Skill 不得覆盖。
- 模板只允许固定变量替换；规则只包含本轮定义的枚举策略，不执行脚本、正则代码、LLM
  判断或自动回复。
- 本地历史用于恢复和可见性，不是永久服务端聊天档案；服务端仍只承担有限恢复窗口。
- 0.3 Beta 继续只支持 Codex Connector。
- 自动更新只接受与当前 App designated requirement 相同的 Beta 包；签名不一致时保留旧 App。

## Non-goals

- 0.2 数据、频道或凭证迁移，以及对 0.2 App 的原地升级兼容。
- 账户体系、跨设备身份恢复、所有权转移、复杂角色和组织目录。
- 附件、富文本、编辑、删除、反应、搜索、线程、永久云历史或消息已读同步。
- 任意规则 DSL、自动回复、Agent 工作流和动态 Connector 平台。
- Claude、Cursor、Windows、Intel Mac、Developer ID 公证或正式商店分发。

## Impact

该 change 会新增服务端成员授权模型、本机版本化存储和主窗口，并替换 0.2 单 Binding 的产品
入口。服务端和本机仍不得保存或上传 Host 会话正文、工作目录或完整 task snapshot；服务端
只能看到不透明 endpoint，不能看到 Codex thread id。
