# Verification

Status: additive login/session source implementation and local checks complete; database provisioning, deployment,
real GitHub login and Membership cutover are not started.

## Implementation Evidence

- Channel Service 在 `DATABASE_URL`、`PIJOO_GITHUB_CLIENT_ID`、`PIJOO_GITHUB_CLIENT_SECRET` 全部存在时
  启用 PostgreSQL Account、Device、Session、LoginAttempt 与 GitHub OAuth；缺少配置时旧频道行为不变。
- 登录使用两层 PKCE、固定 callback、一次性 exchange、90 天不透明 Session 和 hash-only 持久化；
  GitHub 返回非空 scope 时拒绝登录，provider token 不落库。
- macOS 设置页使用 `ASWebAuthenticationSession`，只在完整响应校验后把 Pijoo Session 写入 Keychain；
  登录取消、Session 失效和退出都有可见状态，已有频道与本地 Host 数据不受影响。
- `npm run typecheck` 与账号 Vitest 通过；macOS focused self-test、原生 App 编译和签名通过，未创建 DMG。

## Design Evidence

- 当前代码确认 `member_id`、频道 credential 与 Keychain locator 都按频道保存，没有跨频道 Human
  或 Device 主体；UI 也明确说明当前封禁不能识别持新邀请返回的同一自然人。
- 现有产品模型已经区分 Human、Membership、Endpoint、TaskBinding 和 Subscription，账号设计只把
  Human 与 Membership 落为云端授权，不改变 Host-local 边界。
- GitHub 官方 OAuth 文档支持 authorization code + PKCE、`state` 和桌面 loopback/custom callback；
  device flow 不作为有浏览器桌面的首选。
- OAuth native-app best practice 要求外部 user-agent 和 PKCE；macOS
  `ASWebAuthenticationSession` 提供系统浏览器认证和受控 callback。
- Railway 当前提供同项目私网 PostgreSQL 与 `DATABASE_URL`，可承载账号和 Membership 事务。

## Not Yet Verified

- GitHub OAuth App 注册、callback domain、client id/secret 与真实账号登录；
- PostgreSQL schema 在真实 Railway 数据库上的迁移、事务与重启恢复；
- Railway PostgreSQL 的备份、恢复、连接上限和部署 readiness；
- 两个真实 GitHub 账号、两台 Mac 的 Membership 恢复与设备撤销；
- 生产环境是否仍只有可清理的测试频道和 Member；
- Mac App Store 分发是否进入路线图，及其 Sign in with Apple/账号删除审核要求。
