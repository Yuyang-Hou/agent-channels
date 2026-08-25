# Design

## Research Conclusion

| 方案 | 结论 | 原因 |
|---|---|---|
| GitHub OAuth + PKCE | 首版采用 | 目标用户是研发；可用稳定 user id；不需要密码、邮件服务或仓库权限 |
| Sign in with Apple | App Store 前再加 | 原生且隐私友好，但当前 Developer ID DMG 不需要为商店审核提前承担第二套登录 |
| Google | 暂不采用 | 覆盖面更广，但对首批研发用户没有明显增益，且商店分发仍需等价隐私登录 |
| 邮件验证码 | 暂不采用 | 需要 SMTP、送达率、验证码重放和滥用治理，当前没有相应用户价值 |
| Passkey | 暂不采用 | 登录体验好，但首设备注册、恢复和跨平台支持超出当前目标 |
| 托管 Auth 平台 | 暂不采用 | 当前只有一个 provider 和一个原生客户端，不值得引入 SDK、租户和供应商锁定 |

OAuth 原生 App 应使用外部 user-agent 和 PKCE。macOS 已有 `ASWebAuthenticationSession`，因此
不新增 WebView 或本机 HTTP callback server。GitHub OAuth 支持 PKCE；device flow 更适合无浏览器
设备，GitHub 也建议可使用浏览器时优先 authorization code + PKCE。

当前 JSON 文件适合单实例实验，但 Account、唯一 Membership、邀请兑换和所有权转移需要数据库
约束与事务。Railway 已提供同项目私网 PostgreSQL 和 `DATABASE_URL`，因此只增加 PostgreSQL
驱动，不引入 ORM 或通用 auth framework。

调研依据：

- [GitHub OAuth authorization 与 PKCE](https://docs.github.com/en/apps/oauth-apps/building-oauth-apps/authorizing-oauth-apps)
- [GitHub OAuth App 安全建议](https://docs.github.com/en/apps/oauth-apps/building-oauth-apps/best-practices-for-creating-an-oauth-app)
- [RFC 8252: OAuth 2.0 for Native Apps](https://datatracker.ietf.org/doc/html/rfc8252)
- [Apple ASWebAuthenticationSession](https://developer.apple.com/documentation/authenticationservices/aswebauthenticationsession)
- [Apple App Review Guidelines 4.8 与账号删除](https://developer.apple.com/app-store/review/guidelines/)
- [Railway PostgreSQL](https://docs.railway.com/databases/postgresql)

## Product Shape

```text
GitHub
  -> 仅验证稳定 github_user_id
  -> provider token 立即丢弃

Channel Service + PostgreSQL
  -> Account -> Device -> Session credential
  -> Account x Channel = Membership
  -> Invite / ownership / ban / message authorization

Agent Channels.app
  -> ASWebAuthenticationSession
  -> 一个 Keychain Session credential
  -> 云端 Membership 列表
  -> 本机 TaskBinding / Subscription / LocalMessage
```

GitHub Account 不是产品内身份。Agent Channels Account 使用自己的 UUID，其他成员只看到用户设置
的昵称、Membership id、角色和在线状态；看不到 GitHub user id、用户名或邮箱。

## Login Flow

1. App 生成一次性 `client_state`、PKCE `verifier` 和 `challenge`，调用
   `/v1/auth/github/start`，并通过 `ASWebAuthenticationSession` 打开返回的 HTTPS URL。
2. 服务端创建 10 分钟 LoginAttempt，保存 App challenge、回调 scheme、设备名、随机 GitHub
   `state` 和服务端生成的 GitHub PKCE verifier，再重定向到 GitHub。
3. GitHub 回调服务端。服务端校验 `state`，交换 code，调用 GitHub authenticated-user API，读取
   稳定 numeric user id 与公开名称，然后立即丢弃 provider token。
4. 服务端为该 LoginAttempt 生成一次性 exchange code，只保存 hash，并重定向
   `agentchannels://oauth/callback?code=...&state=...`。
5. App 校验 `client_state`，把 exchange code 和原始 App verifier 发送到
   `/v1/auth/device/exchange`。服务端原子消费 LoginAttempt，创建或读取 Account，创建 Device 和
   90 天 Session，只返回一次 Session credential。
6. App 把 Session credential 写入 Keychain，再读取 `/v1/session` 与 `/v1/channels`；任一步失败
   都撤销新 Session 并清理本次 Keychain 写入。

LoginAttempt 的 GitHub PKCE verifier 最多保留 10 分钟，成功、取消或过期后删除。exchange code
只能使用一次。所有登录响应使用 `Cache-Control: no-store`；日志不得记录 provider code/token、
exchange code、PKCE verifier 或 Session credential。

## Session Model

Session credential 是 32 字节随机值，服务端只保存 SHA-256 hash。每个请求先解析 Session，再按
Membership 授权；不使用 GitHub token 调用 Agent Channels API，也不把 credential 放进消息、
本地 JSON、命令行参数或模型上下文。

- 固定有效期 90 天，不做滑动延期；到期重新登录。
- App 启动和网络恢复时读取 `/v1/session`；401 只暂停云端连接并提示重新登录，不删除本机消息、
  TaskBinding 或 Subscription。
- “退出当前设备”撤销当前 Session 并删除 Keychain credential。
- “移除设备”撤销该 Device 的全部 Session，并立即关闭它的 SSE stream；当前设备不能误删自己，
  必须走退出流程。
- “退出其他设备”批量撤销其他 Device Session，不影响当前设备。
- Device 只保存用户可识别名称、平台、创建/最近使用时间和撤销时间，不上传硬件序列号、Host
  会话或系统账号。

首版只用一个不透明 Session credential。JWT、refresh token、token family 和自动轮换只有在出现
第三方 API consumer 或短 access-token 的合规要求后再增加。

## Service Data Model

```text
Account
  id, github_user_id UNIQUE NULL, display_name, status(active|deleted),
  created_at, updated_at, deleted_at

Device
  id, account_id, name, platform, created_at, last_seen_at, revoked_at

Session
  id, account_id, device_id, credential_hash UNIQUE,
  created_at, expires_at, last_seen_at, revoked_at

LoginAttempt
  id, github_state_hash UNIQUE, github_pkce_verifier,
  app_code_challenge, callback_uri, client_state, device_name,
  github_user_id, github_display_name, exchange_code_hash UNIQUE,
  expires_at, authenticated_at, consumed_at

Channel
  id, name, created_at

Membership
  id, channel_id, account_id, role(owner|member),
  status(active|removed|banned), created_at, updated_at,
  UNIQUE(channel_id, account_id)

Invite
  id, channel_id, token_hash UNIQUE, label, max_uses, use_count,
  expires_at, revoked_at, created_by_membership_id, created_at
```

PostgreSQL 使用唯一约束保证一个 GitHub user id 只对应一个 Account、同一 Account 在同一 Channel
只有一个 Membership、每个 Channel 只有一个 active owner。邀请兑换、次数增加与 Membership
创建或恢复必须在同一事务内完成。

`display_name` 属于 Account。首次登录可用 GitHub 公开名称建议默认值，用户确认或修改后不再因
GitHub 名称变化自动覆盖。发送消息时服务端把当时昵称写入 `sender_name` 快照；历史消息不回写。

## Membership And Invitations

创建频道要求 active Session，并在一次事务中创建 Channel 与 owner Membership。服务端不再返回
频道 credential；App 的每个 ChannelProfile 只保存 channel id、membership id 和本机展示状态。

接受邀请也要求 active Session：

- 没有 Membership：创建 active member Membership 并增加邀请使用次数；
- 已 active：幂等返回现有 Membership，不消耗次数；
- 已 removed：使用一份有效新邀请恢复同一个 Membership，并增加次数；
- 已 banned：返回 `account_banned_from_channel`，不消耗次数；
- 是 owner：幂等返回现有 Membership。

因此封禁针对稳定 Account，而不是某份凭证；同一 Account 换设备或换邀请都不能绕过。解除封禁
恢复为 active。移除用于普通离开或 owner 清退，允许以后由新邀请重新加入。它不承诺识别同一
自然人控制的另一个 GitHub 账号。

owner 可以把所有权原子转移给一个 active member；转移后原 owner 变为 member。账号删除前必须
先转移或明确删除全部自有频道，服务端不得留下无 owner Channel。

账号删除后撤销全部 Session、清空 GitHub user id 与账号昵称并把 Membership 置为 removed；已经
投递并保存在其他用户本机的消息副本不能远程删除。以后用同一 GitHub 账号登录会创建全新 Account，
旧封禁不会作为隐形永久标识保留。若公开社区出现需要跨账号或删除后持续封禁的真实滥用，再单独
设计有明确保留期限和隐私说明的 abuse tombstone。

## Endpoint And Message Boundary

Session 证明 Account，active Membership 证明频道权限，Device 区分设备；三者都不能替代本机
TaskBinding。每次 `/join` 继续接收 App 生成的 endpoint key，服务端以
`membership_id + device_id + endpoint_key` 计算稳定不透明 endpoint id。它不保存或解析 Host
provider、conversation id、工作目录或 task 内容。

成员列表、消息与 Host 卡片继续只使用 `membership_id`、昵称、role 和 endpoint id。GitHub 字段、
Account id、Device id 与 Session id 不进入消息正文或来源引用。

设备撤销、Session 过期、Membership 移除/封禁必须关闭对应在线 session 和 stream。App 重新登录
后以云端 Membership 列表恢复 ChannelConnection，再由本机现有 Subscription 使用新 Session
重新建立监听；游标与本机消息仍按原规则恢复。

## Cross-device Experience

登录后的首页自动加载云端频道列表。新设备看到“你已加入的频道”，但每个频道显示“尚未转发到
本机会话”，用户必须在该 Mac 重新选择目标 AI 会话。这样实现 Membership 恢复，同时不上传
TaskBinding 或猜测跨设备 Host 路由。

昵称、频道 Membership、角色和设备列表跨设备同步；以下内容不跨设备：

- LocalMessage 与已读位置；
- TaskBinding、Subscription、模板和默认发送目标；
- Host conversation id、工作目录和 Connector 诊断；
- Keychain Session credential。

## App Information Architecture

登录是进入云端频道前的单独状态，不塞进菜单栏。主窗口设置页新增“账号与设备”：

- 账号昵称与 GitHub 已连接状态；
- 当前设备、其他设备、最近使用时间和撤销；
- 退出当前设备、退出其他设备、删除账号。

菜单栏仍只展示总体连接状态、打开主窗口、暂停/恢复和退出。普通登录取消或输入错误即时反馈，
不作为持久全局健康告警；Session 失效导致全部频道无法连接时才进入需要处理的账号状态。

## Persistence And Cutover

Account 是核心授权数据，不能继续落在多个 JSON 文件。实施时先建立 PostgreSQL schema、事务和
readiness，再切换频道授权；消息环形缓冲与在线 Session 仍可留在单进程内存，直到真实规模要求
共享运行态。

账号版按 clean-slate Beta 发布，不自动把旧 Member credential 猜成 Human。切换前必须只读核对
线上账号版发布范围、频道和成员数量：确认全为测试数据才允许清空；若存在真实用户，暂停并另做
一次性“登录后用旧 credential 认领 Membership”方案。该认领端点在迁移窗口结束后删除，不进入
长期协议。

## Security And Abuse Controls

- `/v1/auth/github/start` 按 IP 限流；LoginAttempt、exchange 和邀请兑换都必须有过期、重放拒绝
  和统一错误响应。
- OAuth `state`、两层 PKCE、固定 HTTPS GitHub callback 与 App callback scheme 全部校验；任何
  return/callback URI 由服务端白名单固定，不能接受任意远程 URL。
- Session、邀请和 exchange credential 只保存 hash；GitHub provider token 不持久化。
- 账号停用、Device 撤销和 Membership 撤权必须在授权查询中实时生效，不能只依赖 App 缓存。
- 安全事件只记录 account/device/session 的不透明 id、操作、结果和时间，不记录消息正文或 secret。

## Rollout Order

1. 在不改变现有 API 的情况下增加 PostgreSQL schema、readiness 和迁移检查。
2. 增加隐藏的 GitHub login/session API 与自动化安全检查。
3. 增加 App 登录、Keychain Session 和账号/设备 UI。
4. 将频道创建、邀请、Membership 和 stream 授权原子切换到 Account Session。
5. 用两个 GitHub 账号、两台 Mac、两个频道完成真实登录、跨设备恢复、移除、封禁、设备撤销和
   所有权转移验收后，才移除旧授权代码并发布账号版。
