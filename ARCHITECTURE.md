# Pijoo Architecture

产品目标以 `PRODUCT.md` 为准，完成度以 `docs/STATUS.md` 为准，当前变更以
`openspec/CURRENT.md` 为准。

## 唯一模型

```text
Channel
  Membership[]
  Invite[]
  Message(author_kind = human | channel_ai)

本机 ChannelRuntimeConfig
  channelID
  taskID                 # App 内部运行句柄
  instructions
  allowedHistoryTaskIDs[]
```

不存在助理、好友、联系人或按人数派生的频道类型。用户主动创建 Channel；邀请只增加 Membership。

## 消息链路

```text
App/Web/成员 human 消息 -> Channel Service -> App SSE/账本
  -> 该 Channel 的 Codex task -> send_to_channel(channel_ai)
  -> Channel Service -> App/Web 时间线
  -> listener 按 author_kind 过滤，不再投递给 Codex
```

服务端将 endpoint 的 `author_kind` 绑定在认证会话上。只有 Channel owner 能建立 `channel_ai`
endpoint；客户端提交消息时不能覆盖作者。所有 human 消息使用同一投递链路，不再按 member id 或
“本账户”过滤。

## 本机运行边界

App 为每个本机 owner Channel 创建一个 Codex task，cwd 固定为：

```text
~/Pijoo/accounts/<account-digest>/channels/<channel-id>/
  AGENTS.md
  MEMORY.md
```

`AGENTS.md` 组合用户编辑的 Channel 指令与固定安全规则；`MEMORY.md` 是该 Channel 的可编辑记忆。
App 在监听和投递前复验 task id、cwd 与受管权限。不匹配时停止投递。加入者不创建第二个 task，
用户也不能选择已有 task 作为运行 task。

## 历史读取

- `thread/list` 只用于展示可授权 task；
- `thread/read(includeTurns: true)` 只读取当前 Channel allowlist；
- 结果限制任务数、片段数和文本长度，并标记 `untrusted_history`；
- 撤销在下一次检索立即生效；
- 不扫描 Codex 私有数据库，不启动、恢复或修改来源 task。

## Web

Web 与 API 同源托管，复用 Account Session、Membership、Invite、History 和 send/stream 接口。
邀请 token 放在 URL Fragment，登录后只在尚未加入时兑换。Web 依据 `author_kind` 分别展示本人、
其他 human 与 Channel AI；AI 消息永远不使用 human 的头像或连续分组。

## 权限边界

- 当前传输是 TLS + 鉴权，不是 E2EE；
- `@` 是提醒范围，不是私信或授权；
- Channel 正文是不可信输入，不能扩大历史 allowlist 或授予工具权限；
- 文件目录、联网、脚本和部署的标准化授权只保留为后续设计，等底层有可验证的强制能力再实现；
- 只有可靠回执后才能声称发送成功，未知结果不得自动重试。

## 暂不建设

联系人模型、成员身份字段、人数派生 UI、通用权限 DSL、向量数据库、第二个 Host、独立 Web 后端和
永久云端聊天历史。
