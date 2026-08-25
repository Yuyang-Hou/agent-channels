# Tasks

## Contract And Storage

- [x] 冻结 0.3 Channel、Invite、Member、Endpoint、Message 与 OnlineSession 字段和状态机
- [x] 冻结 ChannelConnection、TaskBinding、Subscription、LocalMessage 与 SubscriptionDelivery 本机 schema
- [x] 创建全新版本化本地 store；检测 0.2 数据时只提示，不迁移、不覆盖、不删除
- [x] 定义 member credential、invite token、endpoint id 与 Keychain locator 的信任边界

## Channel Service

- [x] 创建频道时生成 owner Member 独立凭证，而不是共享频道 token
- [x] 使用短期邀请创建独立 Member 凭证，并覆盖过期、次数、撤销和重放
- [x] 邀请支持备注、有效期、使用次数、状态列表和保留记录的幂等撤销
- [x] 所有 join、send、stream、history 和 roster 操作按 Member 授权
- [x] 实现成员列表、移除、封禁与解除封禁；撤权同步失效 session 和现有 stream
- [x] 消息保存 sender member/endpoint，且服务端数据不含 Host/task 私有字段
- [x] 消息附带服务端认证 Member 昵称，UI 与 Host 输入不再展示内部 endpoint callsign
- [x] 覆盖跨频道凭证、普通成员越权、被移除成员和被封禁成员测试

## macOS Main Window

- [x] 以主窗口实现频道侧栏、当前频道时间线/发送框、成员与 task 订阅详情
- [x] 首次使用必须先设置全局昵称并配置 Codex MCP 与 Pijoo Skill，再进入频道工作区
- [x] 提供不生成 DMG、可直接启动并显式配置集成的本地开发 App 入口
- [x] 实现多个 ChannelConnection 的创建、邀请加入、退出、选择、未读和独立状态
- [x] 实现简单 App 文本发送，可靠区分 pending、accepted、failed 和 unknown
- [x] 消息到达先写 LocalMessage `received`，再更新每条 SubscriptionDelivery
- [x] 本地历史在重启后保留、可清空，并以 `channel_id + message_id` 去重
- [x] 实现 owner 成员列表、移除、封禁和解除封禁 UI，并展示 0.3 ban 的身份边界
- [x] owner 可配置创建邀请，并在成员页查看状态、次数、过期时间和撤销活跃邀请
- [x] 菜单栏收敛为总状态、快速打开、启动/退出，不复制主窗口配置流程
- [x] 将 App 设置并入主窗口侧栏，删除独立 Settings Scene，并确保快速打开置前聚焦单实例窗口
- [x] 将侧栏“设置”固定到底部，并与频道列表分隔
- [x] 使用轻量下划线导航，并统一消息时间线、订阅展开区、发送框和状态层级
- [x] 将用户界面的“Task 订阅”改为结果导向的“转发到会话”，内部模型命名保持不变
- [x] 消息页出现时自动拉取最新历史，发送框支持回车发送且不并发重复提交
- [x] 复用 ChannelConnection displayName 支持本机频道昵称，并持续展示原始频道名
- [x] 双击频道详情标题复用现有频道改名流程
- [x] 将添加频道弹窗收敛为创建时只填频道名称、加入时只填邀请口令和单一主操作
- [x] 加入频道前按服务地址和频道 ID 拒绝本机重复 ChannelConnection
- [x] 将用户昵称提升为全局设置，同步各频道 Member 名称，并隐藏 endpoint callsign
- [x] 在服务端持久化频道名称，并在创建、查询和邀请加入结果中返回

## Task Bindings And Runtime

- [x] 实现 TaskBinding 的显式创建、兼容性状态和删除保护
- [x] 支持按 Host 会话标题/id 搜索点选绑定，标题不落盘，同时保留 id/链接直绑与最终 preflight
- [x] 支持选择工作目录后新建持久 Codex user task，打开并通过 owner preflight 后自动连接当前频道
- [x] “转发到会话”只展示已闭环的本机 AI App；单个 Host 不显示选择器，Claude 未支持时不展示
- [x] 实现 TaskBinding × ChannelConnection Subscription 管理及唯一默认出站约束
- [x] 为每条 enabled Subscription 监管独立 listen-here sidecar、游标和错误状态
- [x] 扩展本机 App IPC：sidecar 在 Host delivery 前 `record_received` 并等待持久化 ack，结束后记录 outcome
- [x] App 持久化或 ack 失败时不调用 Host、不推进游标；移除“成功投递后才写 inbox”的旧顺序
- [x] 已完成 delivery 重放返回 `already_processed` 且 Host 零调用；未决状态返回 `unresolved`
- [x] SSE body 异常断开仍保留本连接最新游标，所有持久终态游标只向前推进
- [x] 一个 Subscription 的 failed/unknown/restart 不影响其他 Subscription
- [x] App 重启恢复 enabled Subscription；成员撤权停止对应 feed 和全部 Subscription
- [x] Subscription 列表可通过 `codex://threads/<id>` 启动 ChatGPT 并打开目标会话
- [x] Subscription 添加或恢复监听时读取 Codex 本机会话名称，失败时回退缩短的会话 ID
- [x] 确保空闲频道、filtered 消息和 App 状态事件不创建 Host turn

## Codex MCP Routing

- [x] 将单一本机 App IPC 升级为 v2；七个 MCP 工具只传各自参数与已校验的 source context
- [x] 固定工具表为 send/list/subscribe/unsubscribe/get_settings/update_settings/inspect_message_source，并确认接收链路只在 App
- [x] 从 `tools/call params._meta.threadId` 读取 Codex 来源 task；七项均覆盖合法、缺失、错误类型和非法 UUID
- [x] App 按 provider + conversationId 匹配 TaskBinding，并解析唯一默认出站 Subscription
- [x] missing、unbound 或 ambiguous 路由失败关闭且不访问 Channel Service；暂停接收不阻止主动发送
- [x] 用户主动追问时只读返回当前 task 最近一条成功投递的来源；未命中不推断为用户手动输入
- [x] MCP 启动上报内嵌版本；设置页在版本匹配前持续提示完全重启并在匹配后自动清除
- [x] 重启提示存在时在主窗口设置入口显示提示点，并复用相同状态自动清除
- [ ] 用两个真实 Codex task 验证 `_meta.threadId` 分别精确匹配各自 UUID

## Templates And Policies

- [x] 实现每 Subscription 的完整消息模板、固定变量校验和默认 Markdown 卡片模板
- [x] 增加 `{message_source}`，task 使用 Host 名称与缩短 id、App 使用产品名并兼容旧客户端回退
- [x] 消息保留可扩展 `provider + conversation_id + label` 来源引用并提供来源会话 id 复制入口
- [x] 模板编辑区使用 macOS 原生 Markdown 渲染提供未保存草稿预览
- [x] Connector 仅展开用户模板，多行正文继承占位符的 blockquote 前缀，不再额外包裹固定卡片
- [x] 每条 Subscription 增加发送成功模板，以可靠消息 id 展开回执且不改写频道正文
- [x] 实现精确来源 endpoint 永不回投的安全不变量
- [x] 实现 `include_other_endpoints` 与 `exclude_member` 两种 same-member 策略
- [x] filtered 只更新对应 SubscriptionDelivery，不删除消息、不推进错误游标或影响其他订阅

## Pijoo Skill

- [x] 定义面向完整产品的 Skill，覆盖产品边界、入站信任、回复决策、七项工具与可靠回执
- [x] 把 Skill 作为静态资源打入 App，并由用户显式 Codex 集成操作安装受管理链接
- [x] 拒绝覆盖或删除同名普通目录和外来链接；覆盖首次安装、幂等修复与安全移除自测
- [x] 集成操作对不可读 Codex 配置失败关闭，预检 Skill 归属，并在组合写入失败时回滚

## Acceptance And Release

- [x] 设置页提供 Beta 自动更新开关，开启后启动时及每 24 小时检查并后台下载 arm64 DMG
- [x] 下次启动由原生助手完成版本、Bundle ID、完整签名与 designated requirement 校验后替换并重开
- [ ] 用前后两个固定签名 Beta 包验收成功更新，并用签名不一致包验收旧 App 保留与错误提示
- [x] 自动化通过全量测试、typecheck、build 与 `openspec validate --strict --all`
- [ ] 干净用户目录完成 0.3 安装；确认 0.2 数据未迁移、覆盖或删除
- [ ] 两台 Mac、两个新频道、两个成员完成 App ↔ App 文本收发和本地历史恢复
- [x] owner 移除与封禁后，旧凭证不能 send/stream，其他成员与频道不受影响
- [ ] 至少三个 Subscription 完成 App → task、task → App 和 task → task 精确路由
- [ ] 一个 task 同时订阅两个频道时不串台；一个频道绑定两个 task 时状态和游标独立
- [ ] 模板和 same-member 策略在真实 turn 中生效，filtered 与空闲均为零 turn
- [ ] 新 task 自动加载产品 Skill，默认与自定义 Markdown 卡片均保持完整外部来源边界
- [ ] 断网、App 重启、Host 不可用和 unknown 回执均不静默丢消息或跨 Subscription 扩散
- [x] 构建、签名、校验并发布全新 0.3 Beta prerelease；不改写现有 0.2 Release 事实
