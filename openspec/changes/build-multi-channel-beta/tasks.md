# Tasks

## Contract And Storage

- [x] 冻结 0.3 Channel、Invite、Member、Endpoint、Message 与 OnlineSession 字段和状态机
- [x] 冻结 ChannelConnection、TaskBinding、Subscription、LocalMessage 与 SubscriptionDelivery 本机 schema
- [x] 创建全新版本化本地 store；检测 0.2 数据时只提示，不迁移、不覆盖、不删除
- [x] 定义 member credential、invite token、endpoint id 与 Keychain locator 的信任边界

## Channel Service

- [x] 创建频道时生成 owner Member 独立凭证，而不是共享频道 token
- [x] 使用短期邀请创建独立 Member 凭证，并覆盖过期、次数、撤销和重放
- [x] 所有 join、send、stream、history 和 roster 操作按 Member 授权
- [x] 实现成员列表、移除、封禁与解除封禁；撤权同步失效 session 和现有 stream
- [x] 消息保存 sender member/endpoint，且服务端数据不含 Host/task 私有字段
- [x] 覆盖跨频道凭证、普通成员越权、被移除成员和被封禁成员测试

## macOS Main Window

- [x] 以主窗口实现频道侧栏、当前频道时间线/发送框、成员与 task 订阅详情
- [x] 实现多个 ChannelConnection 的创建、邀请加入、退出、选择、未读和独立状态
- [x] 实现简单 App 文本发送，可靠区分 pending、accepted、failed 和 unknown
- [x] 消息到达先写 LocalMessage `received`，再更新每条 SubscriptionDelivery
- [x] 本地历史在重启后保留、可清空，并以 `channel_id + message_id` 去重
- [x] 实现 owner 成员列表、移除、封禁和解除封禁 UI，并展示 0.3 ban 的身份边界
- [x] 菜单栏收敛为总状态、快速打开、启动/退出，不复制主窗口配置流程

## Task Bindings And Runtime

- [x] 实现 TaskBinding 的显式创建、兼容性状态和删除保护
- [x] 实现 TaskBinding × ChannelConnection Subscription 管理及唯一默认出站约束
- [x] 为每条 enabled Subscription 监管独立 listen-here sidecar、游标和错误状态
- [x] 扩展本机 App IPC：sidecar 在 Host delivery 前 `record_received` 并等待持久化 ack，结束后记录 outcome
- [x] App 持久化或 ack 失败时不调用 Host、不推进游标；移除“成功投递后才写 inbox”的旧顺序
- [x] 一个 Subscription 的 failed/unknown/restart 不影响其他 Subscription
- [x] App 重启恢复 enabled Subscription；成员撤权停止对应 feed 和全部 Subscription
- [x] 确保空闲频道、filtered 消息和 App 状态事件不创建 Host turn

## Codex MCP Routing

- [x] 将单一本机 App IPC 升级为 v2；六个 MCP 工具只传各自参数与已校验的 source context
- [x] 固定工具表为 send/list/subscribe/unsubscribe/get_settings/update_settings，并确认接收链路只在 App
- [x] 从 `tools/call params._meta.threadId` 读取 Codex 来源 task；六项均覆盖合法、缺失、错误类型和非法 UUID
- [x] App 按 provider + conversationId 匹配 TaskBinding，并解析唯一默认出站 Subscription
- [x] missing、unbound 或 ambiguous 路由失败关闭且不访问 Channel Service；暂停接收不阻止主动发送
- [ ] 用两个真实 Codex task 验证 `_meta.threadId` 分别精确匹配各自 UUID

## Templates And Policies

- [x] 实现每 Subscription 的模板选择、固定变量校验和默认不可信输入模板
- [x] 实现精确来源 endpoint 永不回投的安全不变量
- [x] 实现 `include_other_endpoints` 与 `exclude_member` 两种 same-member 策略
- [x] filtered 只更新对应 SubscriptionDelivery，不删除消息、不推进错误游标或影响其他订阅

## Acceptance And Release

- [x] 自动化通过全量测试、typecheck、build 与 `openspec validate --strict --all`
- [ ] 干净用户目录完成 0.3 安装；确认 0.2 数据未迁移、覆盖或删除
- [ ] 两台 Mac、两个新频道、两个成员完成 App ↔ App 文本收发和本地历史恢复
- [ ] owner 移除与封禁后，旧凭证不能 send/stream，其他成员与频道不受影响
- [ ] 至少三个 Subscription 完成 App → task、task → App 和 task → task 精确路由
- [ ] 一个 task 同时订阅两个频道时不串台；一个频道绑定两个 task 时状态和游标独立
- [ ] 模板和 same-member 策略在真实 turn 中生效，filtered 与空闲均为零 turn
- [ ] 断网、App 重启、Host 不可用和 unknown 回执均不静默丢消息或跨 Subscription 扩散
- [ ] 完成上述证据后再构建、签名、校验并发布全新 0.3 Beta；发布前不改写现有 0.2 Release 事实
