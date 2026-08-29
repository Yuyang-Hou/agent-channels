# Web Shared Channel Requirements

## ADDED Requirements

### Requirement: 网页恢复账号频道并支持切换

Web MUST 使用 Account Session 恢复所有 active Membership，并允许用户切换当前频道。不同频道 MUST
使用独立 endpoint session，首版 MUST 只监听当前频道。

#### Scenario: 再次登录

- **GIVEN** 账号已有多个 active Membership
- **WHEN** 用户登录 Web
- **THEN** 频道列表显示这些频道，用户可逐个切换并交流

#### Scenario: 撤权

- **GIVEN** 用户正在查看一个频道
- **WHEN** Membership 被移除或封禁
- **THEN** Web 停止监听并移除该频道，且不允许旧 Session 继续收发

### Requirement: 邀请加入省略冗余步骤

邀请链接 MUST 使用 `/join/<channel>#invite=<token>`。Web MUST 在登录后先检查 active Membership，只有
缺少 Membership 时才显示一次加入确认并兑换邀请。

#### Scenario: 已登录且已加入

- **GIVEN** 用户已有目标频道 active Membership
- **WHEN** 打开邀请链接
- **THEN** 直接打开频道，不展示登录或加入确认，不消耗邀请次数

#### Scenario: 未登录但已加入

- **GIVEN** 用户已有目标频道 active Membership 但 Web Session 已失效
- **WHEN** 打开邀请链接并完成登录
- **THEN** 直接打开频道，不兑换邀请

#### Scenario: 尚未加入

- **GIVEN** 用户没有目标频道 active Membership
- **WHEN** 登录后确认加入
- **THEN** Web 兑换一次邀请、刷新频道列表并打开目标频道

#### Scenario: 邀请失效但 Membership 有效

- **GIVEN** 邀请已过期或撤销，但用户 Membership 仍 active
- **WHEN** 用户打开旧链接
- **THEN** Web 仍直接进入频道

### Requirement: 浏览器凭证不暴露给 JS

Web Account Session MUST 只保存在 HttpOnly、Secure、SameSite=Lax Cookie。邀请 token 在客户端 MUST 只
暂存于 Fragment 与当前标签页 Session Storage，并在解析后从地址栏清除；只有确认加入时才提交兑换。

#### Scenario: 登录完成

- **WHEN** GitHub OAuth 回跳成功
- **THEN** 服务端完成 session exchange 并设置 HttpOnly Cookie，页面脚本不接收 credential

### Requirement: 消息收发保留可靠结果边界

Web MUST 复用现有 join/listen/send API。发送只有在服务端返回 message id 后才显示为已发送；请求结果
未知时 MUST NOT 自动重试。

#### Scenario: 切换频道

- **WHEN** 用户从频道 A 切换到频道 B
- **THEN** Web 取消 A 的长轮询，以 B 的独立 Session 和游标继续

#### Scenario: 发送回执未知

- **GIVEN** mutating 请求可能已到达服务端但响应丢失
- **WHEN** Web 无法确认结果
- **THEN** 显示“发送结果未知”，不重复提交原消息
