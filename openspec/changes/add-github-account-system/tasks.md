# Tasks

## 1. Release Gates Before Implementation

- [ ] 完成 0.3 Beta 双用户、双设备、真实 Host 闭环，确认账号工作不会掩盖当前 P0 问题
- [ ] 只读核对生产频道、成员与真实用户范围，决定 clean-slate 或单独的一次性认领 change
- [ ] 确认账号版继续使用 Developer ID DMG；若改走 Mac App Store，先补 Sign in with Apple 设计

## 2. PostgreSQL Authority

- [ ] 建立 Account、Device、Session、LoginAttempt、Channel、Membership、Invite schema 与迁移
- [ ] 用数据库唯一约束和事务覆盖账号创建、邀请兑换、封禁重入和所有权转移
- [ ] 增加数据库 readiness；数据库不可用时账号与频道授权失败关闭，健康信息不泄露连接配置
- [ ] 保留消息缓冲和在线状态的现有单进程边界，不提前引入 Redis 或多副本协调

## 3. GitHub Login And Session

- [ ] 实现 GitHub OAuth code + PKCE broker、state 校验、10 分钟 LoginAttempt 和一次性 exchange
- [ ] 只读取稳定 GitHub user id 与公开名称，不申请仓库、组织或邮箱 scope
- [ ] GitHub token 用后立即丢弃；Session、exchange 与邀请 credential 只持久化 hash
- [ ] 实现 `/v1/session`、退出当前设备、退出其他设备和设备撤销
- [ ] 覆盖取消、超时、state/PKCE 错误、exchange 重放、Session 过期与限流

## 4. Account-scoped Channels

- [ ] 创建频道时原子创建 owner Membership，不再返回 Member credential
- [ ] 邀请兑换要求 active Session，并覆盖 active 幂等、removed 恢复、banned 拒绝和并发次数上限
- [ ] 所有 send/listen/history/member/invite 请求同时校验 Session 与 active Membership
- [ ] 设备撤销、Session 过期、成员移除/封禁时关闭对应在线 session 和 stream
- [ ] 实现 owner 到 active member 的原子所有权转移和账号删除前置检查

## 5. macOS Product

- [ ] 使用 `ASWebAuthenticationSession` 完成 GitHub 登录，App 不嵌入 WebView 或持有 GitHub token
- [ ] Keychain 只保存 Agent Channels Session credential；登录激活失败时回滚本次 Session 与凭证
- [ ] 设置页增加账号昵称、设备、退出与删除入口，不增加菜单栏复杂度
- [ ] 登录新 Mac 后恢复 ChannelConnection，但明确要求用户重新“转发到会话”
- [ ] Session 失效只暂停云端频道连接，不删除本地消息、TaskBinding 或 Subscription

## 6. Acceptance And Cutover

- [ ] 两个独立 GitHub 账号在两台 Mac 首次登录并恢复各自 Membership
- [ ] 同一账号第二台 Mac 可看到频道，但看不到第一台 Mac 的 TaskBinding、LocalMessage 或 Host id
- [ ] owner 封禁账号后，该账号所有设备、现有 stream 和新邀请重入均失败；解除后恢复
- [ ] 撤销单个 Device 后其他设备保持在线；退出和 90 天过期均可重新登录恢复 Membership
- [ ] 所有权转移后新 owner 可管理成员，旧 owner 不再拥有 owner 权限
- [ ] 自动化、严格 OpenSpec、真实 GitHub 回调、双机 Host 路由和安全日志检查全部通过后再发布
