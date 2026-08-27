# Proposal: Add GitHub Account System

## Why

0.3 Beta 的 `member_id` 和 Member credential 只证明“持有某个频道凭证”，不能证明多个频道、
多台设备上的成员属于同一稳定账号。因此 owner 封禁一个 Member 后，同一账号仍可用新邀请创建
另一个 Member；用户更换 Mac 后也无法恢复已有 Membership。

账号体系要解决的是稳定 Human、设备撤权和跨设备 Membership，不是增加一个登录页。GitHub 是
首批研发用户已经使用的身份提供方，且无需自建密码、邮件投递或仓库授权。

## What Changes

- 增加 GitHub OAuth authorization code + PKCE 登录；macOS App 使用系统
  `ASWebAuthenticationSession`，不嵌入 WebView。
- GitHub 只用于验证稳定 user id。服务端短暂使用并立即丢弃 GitHub access token，不申请仓库
  scope，不把 GitHub token、邮箱或用户名作为 Pijoo API 凭证。
- Channel Service 签发自己的随机不透明 Session credential；App 只在 Keychain 保存这一份账号
  credential，服务端只保存 hash。
- 增加 Account、Device、Session 和账号级 Membership；频道、邀请、成员、设备与会话统一持久化
  到 Railway PostgreSQL。
- 创建和接受邀请都要求登录。Membership 对 `channel_id + account_id` 唯一：移除后可凭新邀请恢复，
  封禁后任何新邀请都不能绕过。
- 登录新 Mac 后同步频道 Membership，但不同步本地消息、TaskBinding、Subscription、Host 会话 id
  或工作目录；用户在每台设备独立选择“转发到会话”。
- 设置页增加账号、设备和退出入口；账号 owner 可转移频道所有权，账号删除前必须先转移或删除
  自己拥有的频道。

## Capabilities

- **New: `human-account`** — GitHub 登录、Pijoo Session、设备管理、账号删除和跨设备
  Membership 恢复。
- **Modified: `channel-service`** — 从频道 Member credential 改为 Account Session 认证和
  account-scoped Membership 授权。

## Product Decisions

- 首版只提供 GitHub 登录。GitHub 身份与 Pijoo Account 分离，未来增加其他登录方式时
  再迁移，不提前建设通用身份提供方框架。
- 使用 OAuth code + PKCE，不使用 device flow；App 通过系统浏览器完成登录。
- GitHub 登录不申请仓库、组织或邮箱 scope；只读取认证用户的稳定 GitHub user id 和公开名称，
  公开名称仅作为首次昵称建议。
- 服务端使用可立即撤销的不透明 Session credential，不引入 JWT、access/refresh 双 token 或
  客户端持有的 GitHub token。Session 固定 90 天，到期重新登录。
- 账号与 Membership 是云端稳定授权；消息历史、TaskBinding、Subscription 和 Host 私有数据
  继续只在本机。
- 0.3 Beta 已进入外部试用，登录能力先以服务端配置开关增量上线，不立即替换现有 Member credential。
  Membership 切换前必须再次核对线上真实用户和频道数据；若已有真实用户，
  单独设计一次性认领，而不是把兼容逻辑塞进常规请求。
- 当前公开分发方向是 Developer ID 公证 DMG。若改为 Mac App Store，发布前必须补充符合 Apple
  Review Guideline 4.8 的等价隐私登录选项，并在 App 内提供账号删除。

## Non-goals

- 密码、短信、邮件验证码、passkey、GitHub 之外的登录方式或账号合并。
- GitHub 仓库、组织、issue、PR 权限或 GitHub App 安装。
- 组织、工作区、团队目录、好友、公开用户搜索、复杂角色或 SSO。
- 云端消息历史、TaskBinding、Subscription、Host 会话或工作目录同步。
- 识别或阻止同一自然人改用另一个 GitHub 账号，或在删除账号后以全新账号重新加入。
- 为旧 Beta 长期保留 Member credential 与 Account Session 双认证。
- 本 change 不在未经生产数据核对和真实登录验收时切换频道授权、部署或迁移线上数据。

## Impact

首个实现切片只增加可关闭的登录与 Session API，不改变既有频道。最终账号体系会把服务端授权主语
从“频道 credential”改为“Account Session + active Membership”，并把
当前 JSON 文件中的频道授权数据迁到关系数据库。Channel Service 仍不知道本机 TaskBinding；
GitHub 身份也不会进入消息正文、成员列表或 Host 输入。
