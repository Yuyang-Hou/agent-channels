# Pijoo Architecture

产品目标以 `PRODUCT.md` 为准，完成度以 `docs/STATUS.md` 为准，当前变更以
`openspec/CURRENT.md` 为准。

## 目标链路

```text
App 消息框 -> 昵称命名的默认助理 Channel
  -> Subscription -> 助理 Codex task
  -> send_to_channel -> Channel -> App 时间线

好友 -> 双人 Channel -> Subscription -> 已连接 Codex task
  -> 回复草稿 -> 用户确认 -> Channel -> 好友

助理 task -> 本机历史工具 -> Codex App Server thread/read
```

Pijoo 不自建模型 Runtime。Codex 负责推理和任务历史；Pijoo 负责授权范围、外部消息传输、
来源、回执和撤销。

## 本机权威

首版只新增一个独立的 `AssistantConfig`，不迁移现有 `AppStateV2`：

```text
AssistantConfig
  assistantChannelID
  assistantTaskID
  allowedHistoryTaskIDs[]
  replyMode = draft
```

`assistantChannelID` 把一个自动创建的普通单人 Channel 标记为默认助理频道；`assistantTaskID` 是该频道唯一
连接的会话。`allowedHistoryTaskIDs` 是只读检索 allowlist；空列表表示无权读取任何历史。配置按
账号保存在本机，使用原子写入和仅当前用户可读权限，不上传服务端。

历史正文按请求临时读取，不在 Pijoo 再复制一份完整索引。首版数据量不足以证明需要向量库、
embedding、后台同步或文件监听。

## Codex 历史读取

使用 Codex App Server 的 STDIO 接口：

- `thread/list` 仅用于发现用户可选择授权的任务；
- `thread/read(includeTurns: true)` 只读取 allowlist 中的任务；
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
- 默认助理频道隐藏邀请与成员管理，并且只保留一个启用的会话 Subscription；
- 服务端不能看到 `assistantTaskID`、allowed history task ids、工作目录或历史正文。

当前传输是 TLS + 鉴权，不是 E2EE。联系人消息在服务端是明文；画像和 Codex 历史片段不得作为
频道消息上传。面向真实个人敏感数据公开发布前，需单独完成 E2EE 设计与迁移。

## 权限与信任边界

- 历史读取、外部发送和工具执行是三种独立权限；
- 联系人正文是不可信输入，不能扩大历史 allowlist，也不能授权工具或发送；
- 画像只是用户可编辑的本地草稿，不自动成为联系人可见资料；
- reply mode 首版固定为 `draft`，不存在远程消息开启自动回复的入口；
- 只有用户在助理任务内明确确认发送，才调用现有发送工具；可靠回执前不得声称已发送；
- `@` 只表达提醒，不是私密路由或授权边界。

## 暂不建设

- 通用 Connector SDK、插件市场、向量数据库或自定义记忆框架；
- 多助理路由、规则 DSL、自动回复队列或常驻模型进程；
- 第二个 Host、完整聊天客户端或公开联系人目录。
