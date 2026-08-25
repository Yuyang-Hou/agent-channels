# Human Account Requirements

## ADDED Requirements

### Requirement: GitHub 只用于验证 Human

App MUST 使用系统浏览器完成 GitHub OAuth authorization code + PKCE 登录。Channel Service MUST
以稳定 GitHub user id 创建或定位 Agent Channels Account，并 MUST NOT 把 GitHub access token、
邮箱、仓库或组织权限暴露给 App、频道成员、消息或 Host。

#### Scenario: 首次登录

- **GIVEN** 用户拥有可用 GitHub 账号且 App 已生成一次性 state 与 PKCE challenge
- **WHEN** 用户在系统浏览器完成授权并由 App 原子兑换一次性 exchange code
- **THEN** 服务创建 Account、Device 和 Session，只向 App 返回 Agent Channels Session credential
- **AND** GitHub provider token 在读取稳定 user id 与公开名称后立即丢弃

#### Scenario: 登录同一 GitHub 账号

- **GIVEN** GitHub user id 已关联一个 active Account
- **WHEN** 用户在另一台 Mac 完成登录
- **THEN** 服务为同一 Account 创建新 Device 和 Session，不创建第二个 Account

#### Scenario: 登录取消或网络中断

- **GIVEN** LoginAttempt 尚未完成
- **WHEN** 用户取消、浏览器回调中断或 10 分钟过期
- **THEN** App 回到可重试登录状态，服务不创建 Session，现有其他设备不受影响

#### Scenario: 回调或 exchange 重放

- **GIVEN** OAuth state、PKCE verifier 或 exchange code 无效、过期或已经使用
- **WHEN** 客户端尝试完成登录
- **THEN** 服务统一拒绝且不泄露 GitHub 身份是否存在，不创建 Account、Device 或 Session

### Requirement: 服务签发可撤销设备 Session

Channel Service MUST 签发随机不透明的 90 天 Session credential，只持久化其 hash，并在每个账号
与频道 API 请求中实时校验 Account、Device 和 Session 状态。

#### Scenario: 正常恢复

- **GIVEN** App Keychain 中有未过期、未撤销的 Session credential
- **WHEN** App 启动或网络恢复并读取 Session
- **THEN** 服务返回当前 Account 与 Device，App 恢复云端 Membership 连接

#### Scenario: Session 到期

- **GIVEN** Session 已超过固定有效期
- **WHEN** App 请求账号或频道 API
- **THEN** 服务返回未认证，App 暂停云端连接并提示重新登录，但保留本机消息和 Host 配置

#### Scenario: 退出当前设备

- **GIVEN** 当前 Device 有 active Session
- **WHEN** 用户确认退出
- **THEN** 服务撤销该 Session 并关闭相关在线 stream，App 删除 Keychain credential
- **AND** 其他 Device Session 与 Membership 保持有效

#### Scenario: 撤销其他设备

- **GIVEN** Account 在两台设备均有 active Session
- **WHEN** 用户从设备 A 撤销设备 B
- **THEN** B 的全部 Session 与现有 stream 立即失效，A 保持在线

### Requirement: Membership 可以跨设备恢复但 Host 数据不能同步

同一 Account 的 active Membership MUST 在新 Device 登录后可见。服务 MUST NOT 保存或同步
LocalMessage、TaskBinding、Subscription、模板、Host conversation id 或工作目录。

#### Scenario: 新设备恢复频道

- **GIVEN** Account 已加入频道 A 且在新 Mac 完成登录
- **WHEN** App 读取账号频道列表
- **THEN** App 展示频道 A 和 Membership 状态，并提示尚未转发到本机会话

#### Scenario: 新设备绑定 Host

- **GIVEN** 新 Device 已恢复频道 A
- **WHEN** 用户要让频道消息进入 AI 会话
- **THEN** 用户必须在该 Device 显式选择本机 Host 会话并创建本地 Subscription
- **AND** 服务端不能从其他 Device 复制或推断目标会话

#### Scenario: 断线后重连

- **GIVEN** Device Session 与 Membership 仍 active，消息仍在有限恢复窗口内
- **WHEN** App 网络恢复并重建 Subscription 监听
- **THEN** 监听按该 Device 本机游标恢复，不读取其他 Device 的本地消息或投递状态

### Requirement: 用户可以管理和删除账号

App MUST 在主窗口设置中提供昵称、设备、退出与账号删除。账号删除 MUST 撤销全部 Session 并清理
或匿名化账号数据；拥有频道的账号 MUST 先转移或删除全部自有频道。

#### Scenario: 修改昵称

- **GIVEN** Account 已登录并加入多个频道
- **WHEN** 用户修改账号昵称
- **THEN** 后续成员列表和消息使用新昵称，既有消息的发送者快照不回写

#### Scenario: owner 请求删除账号

- **GIVEN** Account 仍拥有至少一个频道
- **WHEN** 用户请求删除账号
- **THEN** 服务拒绝删除并列出需要转移或删除的频道，不留下无 owner Channel

#### Scenario: 删除无所有权账号

- **GIVEN** Account 不再拥有频道且用户完成明确确认
- **WHEN** 服务执行账号删除
- **THEN** 全部 Session 和 stream 立即失效，Membership 不再可用，GitHub user id 与公开昵称被清除
- **AND** 本机 App 删除 Keychain credential并保留或清除本地历史由用户另行选择
