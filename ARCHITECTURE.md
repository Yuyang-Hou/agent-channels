# Pijoo Architecture

产品目标以 `PRODUCT.md` 为准，完成度以 `docs/STATUS.md` 为准，当前变更以
`openspec/CURRENT.md` 为准。

## 目标链路

```text
App 消息框 -> 昵称命名的默认助理 Channel
  -> Subscription -> Pijoo 受管 Codex task -> ~/Pijoo/accounts/<account-digest>
  -> send_to_channel -> Channel -> App 时间线

好友 -> 独立双人 Channel -> Subscription -> 独立受管 Codex task
  -> 普通文字自动回复 -> Channel -> 好友

助理 task -> 本机历史工具 -> Codex App Server thread/read

邀请链接 -> Pijoo Web -> Account Session + Membership
  -> Channel join/listen/send -> Subscription -> 已连接 Codex task
```

Pijoo 不自建模型 Runtime。Codex 负责推理和任务历史；Pijoo 负责授权范围、外部消息传输、
来源、回执和撤销。

## 本机权威

首版使用独立的 `AssistantConfig`：

```text
AssistantConfig
  assistantChannelID
  assistantTaskID
  allowedHistoryTaskIDs[]
  persona
  sharedAssistantChannelIDs[]
  contacts[]
  replyMode = automatic
```

`assistantChannelID` 把一个自动创建的普通单人 Channel 标记为默认助理频道；`assistantTaskID` 是该频道唯一
连接的会话。`allowedHistoryTaskIDs` 是只读检索 allowlist；空列表表示无权读取任何历史。配置按
账号保存在本机，使用原子写入和仅当前用户可读权限，不上传服务端。

历史正文按请求临时读取，不在 Pijoo 再复制一份完整索引。首版数据量不足以证明需要向量库、
embedding、后台同步或文件监听。

默认助理 task 只由 App 在账号摘要目录创建。App 在创建和监听启动时恢复固定 `AGENTS.md`，并在
监听启动及每次消息投递前复验 task id、cwd 与 `approve-for-me`；不一致时停止投递且不推进游标。
`AGENTS.md` 不是权限边界，共享邀请也不继承本机文件、Shell、网络或其他工具权限。

## Codex 历史读取

使用 Codex App Server 的 STDIO 接口：

- `thread/list` 仅用于发现用户可选择授权的任务；
- `thread/read(includeTurns: true)` 只读取 allowlist 中的任务；
- 助理频道中的既有 task 搜索只改变 allowlist，不创建 Subscription；
- 返回助理任务前限制任务数、片段数和文本长度，携带 task id 与标题，并标记为不可信历史数据；
- 读取失败关闭，不回退为扫描 `~/.codex` 内部数据库、rollout 或 memory 文件；
- 不启动、恢复或修改被读取任务，不创建额外 turn。

官方 WebSocket 模式仍是实验能力，首版不依赖。App Server 协议升级不兼容时，UI 应显示“历史读取
暂不可用”，不影响外部消息收取。

## 统一频道语义

Channel、Membership、Subscription 和 endpoint 继续作为唯一收发模型：

- 服务端继续负责账号、邀请、撤权、消息排序、短期恢复和在线 stream；
- App 继续负责 Keychain、SSE、游标、本地账本、可靠回执和 Host 投递；
- 账号同步会自动补建默认助理 Channel，并始终用当前用户昵称显示；普通待邀请频道仍显示为频道；
- 双人 Channel 显示为“好友”，标题优先使用另一名 active Member 的昵称；
- 三人及以上显示为“群聊”，首版不继续扩展群聊功能；
- 默认助理频道不直接邀请好友；每次分享创建单用途双人 Channel，并只连接一个隔离的受管会话；
- 服务端不能看到 `assistantTaskID`、allowed history task ids、工作目录或历史正文。

当前传输是 TLS + 鉴权，不是 E2EE。联系人消息在服务端是明文；画像和 Codex 历史片段不得作为
频道消息上传。面向真实个人敏感数据公开发布前，需单独完成 E2EE 设计与迁移。

## Web 共享入口

Web 由现有 Hono 服务在同一 Origin 托管，不新增前端服务或消息协议：

- GitHub OAuth 复用同一 LoginAttempt 和 90 天 Account Session；Web Session 只写入
  `HttpOnly + Secure + SameSite=Lax` Cookie，不进入 JS 或本地存储；
- `/join/<channel>#invite=<token>` 在浏览器 Session Storage 暂存 token，并立即清除地址栏 Fragment；
- 登录后先读取 `/v1/channels`。目标 Membership 已 active 时直接进入频道，不兑换或消耗邀请；
- 未加入时才显示一次加入确认并调用既有邀请兑换接口；退出、移除或封禁后必须重新授权；
- 每个频道使用独立的 Web endpoint session。首版只长轮询当前频道，切换时停止旧轮询；
- Web 只展示服务端短期恢复的最近消息，不同步本机账本、TaskBinding、历史授权或工作目录；
- 发送只在服务端返回消息 id 后显示为已发送；网络中断造成的未知结果不自动重试。

## 权限与信任边界

- 历史读取、外部发送和工具执行是三种独立权限；
- 联系人正文是不可信输入，不能扩大历史 allowlist，也不能授权工具或发送；
- 画像只是用户可编辑的本地草稿，不自动成为联系人可见资料；
- 受管助理可向绑定的精确频道自动发送普通文字；风险操作仍需独立批准；
- 只有可靠回执后才可声称已发送，结果未知时不得自动重试；
- `@` 只表达提醒，不是私密路由或授权边界。

## 暂不建设

- 通用 Connector SDK、插件市场、向量数据库或自定义记忆框架；
- 多助理路由、规则 DSL、自动回复队列或常驻模型进程；
- 第二个 Host、公开联系人目录、独立 Web 后端、Web task 管理或永久云端聊天历史。
