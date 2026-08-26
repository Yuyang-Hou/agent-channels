# Multi-Channel Beta Requirements

## ADDED Requirements

### Requirement: 0.3 使用全新本地模型

0.3 Beta MUST 使用独立、版本化的多频道本地 store，MUST NOT 自动迁移、覆盖或删除 0.2 的
单 Binding 数据。

#### Scenario: 干净启动

- **GIVEN** 用户目录没有 0.3 store
- **WHEN** 0.3 App 首次启动
- **THEN** App 创建 0.3 store，生成并持久化不读取系统或硬件标识的随机本机昵称，并展示频道工作区
- **AND** 默认昵称可编辑但不参与身份或鉴权

#### Scenario: 完成首次使用设置

- **GIVEN** 用户使用自动生成或自行修改的全局昵称
- **WHEN** 用户创建或加入频道
- **THEN** App 使用该昵称且不要求先配置 Codex

#### Scenario: 首次使用设置未完成

- **GIVEN** Codex MCP 与 Pijoo Skill 未配置或尚未加载当前版本
- **WHEN** 用户打开 Pijoo 主窗口
- **THEN** App 仍提供频道和 App 内消息操作，只在“转发到会话”中门禁 AI 会话操作

#### Scenario: 检测到 0.2 数据

- **GIVEN** 用户目录存在 0.2 `binding.json` 或凭证
- **WHEN** 0.3 App 启动
- **THEN** App 明确提示该 Beta 不支持迁移，且不读取、覆盖、删除或用于运行该数据

### Requirement: 主窗口管理多个频道

App MUST 以主窗口展示多个 ChannelConnection，并为当前频道提供简单文本时间线、发送框、
未读状态、成员和 task 订阅管理。App 设置 MUST 作为同一主窗口的侧栏目的地呈现；菜单栏 MUST
只保留总体状态、主窗口入口和监听生命周期操作，不得打开独立设置窗口。

#### Scenario: 频道隔离

- **GIVEN** 用户同时加入频道 A 和频道 B
- **WHEN** 两个频道分别收到消息
- **THEN** 侧栏分别更新未读，时间线、发送目标和成员列表不串频道

#### Scenario: 添加频道

- **GIVEN** 用户打开添加频道弹窗
- **WHEN** 用户选择创建频道或加入频道
- **THEN** 创建路径只填写频道名称，加入路径只粘贴 `ac2:` 邀请口令，并以单一底部主按钮提交
- **AND** 两个路径都使用设置中保存的全局用户昵称，不在频道弹窗重复填写

#### Scenario: 添加频道入口位置稳定

- **GIVEN** 用户调整主窗口或侧栏宽度
- **WHEN** 用户查看频道侧栏
- **THEN** 带“添加频道”辅助功能标签的 `+` 按钮始终显示在“频道”标题旁，不进入窗口工具栏或溢出菜单

#### Scenario: 拒绝重复加入频道

- **GIVEN** 本机已有同一服务地址和频道 ID 的 ChannelConnection
- **WHEN** 用户再次提交该频道的邀请口令
- **THEN** App 在兑换邀请前拒绝操作，不创建重复 ChannelConnection 或新 Member

#### Scenario: 修改我的昵称

- **GIVEN** 用户已经加入多个频道
- **WHEN** 用户在设置中修改“我的昵称”
- **THEN** App 保存唯一全局昵称并同步各频道的 Member 名称
- **AND** 后续从 App 或 task endpoint 发出的消息都以该昵称展示，内部 callsign 不出现在产品界面

#### Scenario: 邀请加入保留频道名称

- **GIVEN** owner 使用自定义频道名称创建频道并生成邀请
- **WHEN** 另一用户通过邀请加入
- **THEN** 服务端返回该频道名称，双方看到相同名称，网络路由继续使用不可变频道 ID

#### Scenario: 创建和管理邀请

- **GIVEN** 当前成员是频道 owner
- **WHEN** owner 配置备注、有效期和可加入人数并创建邀请
- **THEN** App 复制一次 `ac2:` 口令，并在成员页展示状态、已用次数、上限与过期时间

#### Scenario: 撤销邀请

- **GIVEN** owner 查看一份活跃邀请
- **WHEN** owner 确认撤销
- **THEN** App 明确撤销只阻止后续加入，服务端保留撤销记录，已经加入的成员不受影响

#### Scenario: 设置本机频道昵称

- **GIVEN** ChannelConnection 保留服务端原始频道名
- **WHEN** 用户双击详情标题或点击编辑按钮设置或清空本机频道昵称
- **THEN** 侧栏和频道标题使用昵称或恢复原始名称，同时详情持续展示不可变的原始频道名，网络路由仍只使用原始频道名

#### Scenario: 重启保留本地历史

- **GIVEN** App 已接收两个频道的消息
- **WHEN** App 完全退出并重新打开
- **THEN** 两个频道的本地历史与未读位置仍可见，且消息按 `channel_id + message_id` 去重

#### Scenario: 从菜单栏打开主窗口

- **GIVEN** 主窗口已隐藏或最小化，菜单栏浮窗处于前台
- **WHEN** 用户点击“打开 Pijoo”
- **THEN** App 复用、反最小化并聚焦单一主窗口，且不创建独立设置窗口

#### Scenario: 普通操作失败不污染总体状态

- **GIVEN** App 核心服务和频道连接正常
- **WHEN** 用户输入无效名称或其他普通操作失败
- **THEN** App 即时说明失败原因，但菜单栏不保留该消息、不变更总体状态或图标

#### Scenario: 打开 App 设置

- **GIVEN** 用户正在 Pijoo 主窗口
- **WHEN** 用户选择侧栏“设置”
- **THEN** “设置”作为与频道列表分隔的固定底部目的地，内容在当前主窗口详情区显示，频道、
  订阅和设置不会分散到两个窗口

#### Scenario: 查看频道消息

- **GIVEN** 当前频道已有多条本机或服务端消息
- **WHEN** 用户打开“消息”
- **THEN** App 自动拉取最新服务端历史并与本机消息合并，相邻同发送者消息按时间聚合显示，正文
  优先，发送框固定在底部，普通接收状态不逐条强调，失败或结果未知保持可见

#### Scenario: 未选中的频道实时收到消息

- **GIVEN** 用户停留在频道 A、其他页面或隐藏窗口，且频道 B 已加入
- **WHEN** 频道 B 收到普通消息
- **THEN** App 通过 B 的独立 feed 立即写入本地历史并更新未读，不需要切换到 B 或手动刷新

#### Scenario: 当前频道实时刷新消息

- **GIVEN** 用户停留在当前频道的消息页
- **WHEN** App、AI 会话或其他成员发送的新消息到达
- **THEN** 当前消息列表立即显示该消息，不需要切换频道、切出 App、重新聚焦或手动刷新

#### Scenario: 生命周期恢复补齐

- **GIVEN** App 从系统休眠、网络中断或后台挂起恢复
- **WHEN** App 回到可运行状态
- **THEN** App 拉取各频道完整服务端保留窗口并按本地消息 id 统一去重，在线长轮询显式携带本地 cursor

#### Scenario: 回车发送消息

- **GIVEN** 发送框包含非空文本且当前没有消息正在发送
- **WHEN** 用户按下回车
- **THEN** App 复用发送按钮的发送流程提交消息，并阻止并发重复发送

#### Scenario: 管理成员与会话转发

- **GIVEN** 当前频道已有成员和已连接的 AI 会话
- **WHEN** 用户切换到对应 Tab
- **THEN** 邀请与成员行使用相同宽度的前导状态栏并对齐标题；成员危险操作收敛在行尾菜单，会话页命名为“转发到会话”，明确频道消息将作为新输入
  发送到具体 AI 会话，并按需展开接收、默认回复频道、模板等低频设置

### Requirement: 每个成员拥有独立凭证

Channel Service MUST 为 owner 和每个加入者创建独立 Member 凭证；邀请 token MUST 只用于创建
Membership，MUST NOT 作为多人共享的长期频道凭证。

#### Scenario: 接受邀请

- **GIVEN** owner 创建一份有效且未用尽的邀请
- **WHEN** 新成员接受邀请
- **THEN** 服务端创建独立 Member 与 endpoint，并只返回该成员自己的凭证

#### Scenario: 跨频道使用凭证

- **GIVEN** 成员持有频道 A 的有效凭证
- **WHEN** 它用该凭证访问频道 B 的 send、stream、history 或 roster
- **THEN** 服务端拒绝请求且不泄露频道 B 数据

### Requirement: owner 可以移除和封禁成员

owner MUST 可以移除、封禁和解除封禁普通成员；撤权 MUST 立即使该 Member 的凭证、session 和
现有 stream 失效。普通成员 MUST NOT 执行这些操作。

#### Scenario: 移除在线成员

- **GIVEN** 普通成员正在发送并监听频道
- **WHEN** owner 移除该成员
- **THEN** 其现有 stream 关闭，旧凭证后续 send 和 stream 均失败，其他成员不受影响

#### Scenario: 封禁成员

- **GIVEN** owner 封禁一个 Member
- **WHEN** 该 Member 尝试恢复、重新加入或创建 session
- **THEN** 服务端拒绝该 Member，直到 owner 解除封禁

#### Scenario: Beta 身份边界

- **GIVEN** 0.3 没有账户或设备身份恢复
- **WHEN** owner 查看封禁说明
- **THEN** UI 明确封禁针对当前 Member，不能承诺识别持新邀请创建全新 Member 的同一自然人

### Requirement: App 消息先落本地再投递 Host

App MUST 在尝试任何 Host delivery 前保存普通频道消息，并按 Subscription 单独记录后续状态。
App 与 Runtime MUST 以 `subscription_id + channel_id + message_id` 对已完成投递进行幂等处理，
并在 Subscription SSE 异常断开后从本连接最后成功处理的消息继续。

#### Scenario: Host 不可用

- **GIVEN** 消息已到达 App 但目标 task 不可用
- **WHEN** Subscription 投递失败
- **THEN** 主窗口仍显示该 LocalMessage，且仅对应 SubscriptionDelivery 标为 `failed`

#### Scenario: 本地持久化失败

- **GIVEN** Subscription sidecar 已收到普通消息但 App 未能提交 `received` 事务或返回 ack
- **WHEN** Runtime 准备投递 Host
- **THEN** Runtime 不调用 Connector、不推进游标，并保留消息等待本地存储恢复后重试

#### Scenario: 不确定投递

- **GIVEN** Host mutating 请求已发出但回执未知
- **WHEN** App 更新消息状态
- **THEN** 对应 Subscription 标为 `unknown` 并暂停等待人工选择，其他 Subscription 继续运行

#### Scenario: 已完成消息被历史重放

- **GIVEN** 同一 Subscription 的消息已经是 `delivered`、`filtered` 或 `skipped`
- **WHEN** 服务端或旧游标再次送达相同 `channel_id + message_id`
- **THEN** App 返回 `already_processed`，Runtime 不调用 Connector并推进到该消息之后

#### Scenario: 未决消息被再次送达

- **GIVEN** 同一 Subscription 的消息处于 `attempting` 或 `unknown`
- **WHEN** Runtime 再次提交该消息
- **THEN** App 返回 `unresolved`，Runtime 停止且不推进游标，等待人工确认

#### Scenario: SSE 异常断开

- **GIVEN** Runtime 已在本次 SSE 连接中成功处理至少一条消息
- **WHEN** body stream 因网络或代理错误异常结束
- **THEN** Runtime 使用本连接最后成功处理的 message id 重连，不退回连接开始前的游标

#### Scenario: Subscription 连接短暂中断

- **GIVEN** 已启用的 Subscription 因网络或代理错误开始自动重连
- **WHEN** 连接在 60 秒内恢复
- **THEN** App 仅在对应 Subscription 展示重连状态，不改变菜单栏总体状态或图标；持续中断达到
  60 秒时才升级为全局连接异常，并在恢复后清除

#### Scenario: Railway SSE 定期轮换

- **GIVEN** Subscription 已在 Railway 上健康连接接近 15 分钟请求上限
- **WHEN** Railway 关闭该 SSE 请求
- **THEN** 客户端保留游标、把退避恢复为 1 秒并自动续接，将该次关闭记录为正常轮换而非全局异常

#### Scenario: 休眠积压等待确认

- **GIVEN** App 进入系统休眠超过 60 秒并在唤醒后发现 Subscription 积压
- **WHEN** App 收到积压消息
- **THEN** App 先保存消息并暂停对应 Host 投递，展示待恢复数量，未经用户同意不创建 turn

#### Scenario: 用户同意恢复

- **GIVEN** 一条 Subscription 有一条或多条 `recovery_pending` 消息
- **WHEN** 用户在 App 选择“发送到会话”
- **THEN** App 恢复对应 Subscription，并按既有模板、过滤和顺序投递积压消息
- **AND** failed 不推进游标，unknown 暂停且不自动重试

### Requirement: App 可以直接收发简单文本消息

用户 MUST 可以在主窗口向当前频道发送文本，并看到来自 App 或 task endpoint 的频道消息及
可靠发送状态。产品展示和 Host 输入 MUST 使用服务端按认证 Member 解析的成员昵称，不得把
内部 endpoint callsign 当作成员昵称；sender member/endpoint id 继续用于身份与自消息判断。

#### Scenario: App 主动发送

- **GIVEN** 用户选中一个已授权频道
- **WHEN** 用户在主窗口发送非空文本
- **THEN** App 使用该频道的 Member 凭证和 app endpoint 发送，并仅在可靠回执后标记 `accepted`

#### Scenario: 发送状态延迟展示

- **GIVEN** 用户已发起一条 App 消息
- **WHEN** 1 秒内收到可靠回执
- **THEN** 时间线不展示短暂的发送状态
- **WHEN** 1 秒后仍在等待结果
- **THEN** 时间线展示“发送中”，直到进入 `accepted`、`failed` 或 `unknown`

#### Scenario: 发送结果未知

- **GIVEN** App 已发出频道 mutation 但没有可靠回执
- **WHEN** 用户查看时间线
- **THEN** 消息显示 `unknown`，App 不自动重复发送

#### Scenario: 展示发送者昵称

- **GIVEN** 成员昵称为 `frontend`，其 App 或 task endpoint 使用内部 callsign 发送消息
- **WHEN** 其他 App 展示消息或 Subscription 生成 Host 输入
- **THEN** 发送者显示为 `frontend`，内部 callsign 只保留为路由信息且不作为产品名称展示

### Requirement: TaskBinding 与频道 Subscription 分离

本机 MUST 分别保存 TaskBinding 和 Subscription；每条 Subscription MUST 拥有独立 endpoint、
游标、模板、自消息策略和运行状态。

#### Scenario: 一个 task 订阅两个频道

- **GIVEN** TaskBinding T 分别订阅频道 A 和 B
- **WHEN** A 和 B 同时收到消息
- **THEN** 两条 Subscription 独立串行投递并维护各自游标，不把 A 的消息标成 B 的来源

#### Scenario: 一个频道绑定两个 task

- **GIVEN** 频道 A 同时绑定 TaskBinding T1 和 T2
- **WHEN** A 收到一条普通消息
- **THEN** App 为 T1、T2 分别记录 delivery 状态，一个失败不暂停另一个

#### Scenario: 从 Subscription 打开目标会话

- **GIVEN** 用户查看已绑定 Codex task 的 Subscription
- **WHEN** 用户点击“打开会话”
- **THEN** App 启动 ChatGPT 并通过该 TaskBinding 的 `codex://threads/<id>` 打开目标会话

#### Scenario: 已启用的关联会话未连接

- **GIVEN** 一条或多条 enabled Subscription 的 Host 会话当前没有可用 owner
- **WHEN** App 检查会话状态或启动对应监听
- **THEN** App 保持接收开关开启，将运行态显示为红色“会话未连接”而不是“已暂停”，并在主窗口集中显示未连接会话数量
- **AND** 受影响的频道列表入口与该频道“转发到会话”入口显示红点，每条 Subscription 在“打开会话”旁提供独立的状态刷新操作，不提供全局“连接全部”操作
- **AND** 会话卡右侧的打开、刷新和展开操作只显示同规格图标，通过悬浮标题和无障碍标签说明用途
- **AND** App 首次检测到未连接时通过对应 TaskBinding 的精确深链在后台请求连接，不激活 Host App、不重复打扰用户
- **AND** owner 状态重新可用后，App 无需用户操作即可继续对应监听并移除未连接提示

#### Scenario: 已绑定会话不缓存标题

- **GIVEN** Codex 本机元数据包含可能被用户修改的目标会话名称
- **WHEN** App 添加会话或恢复该会话的监听
- **THEN** Subscription 只展示 Host 名称与缩短的会话 ID，不持久化或展示缓存标题

#### Scenario: 搜索或直接输入会话

- **GIVEN** 用户进入“转发到会话”且当前 Host 支持会话发现
- **WHEN** 用户按标题或 id 搜索，或直接输入会话 id/链接
- **THEN** App 不自动展示最近会话，仅在用户输入非空关键词后从全部未归档用户主会话索引中匹配，并排除 subagent/reviewer；匹配项在搜索框下方以不透出底层内容的系统实色浮层按内容高度展开，浮层位于同一区域的说明文字之上，整行点选即绑定且不改变页面布局；用户也可直接发起绑定，创建 Subscription 前执行 Host preflight，搜索标题不写入 Binding

#### Scenario: Codex 集成未就绪时阻止绑定试错

- **GIVEN** MCP 或 Skill 未配置，当前 App 版本未收到 `mcp_ready`，或 ChatGPT 仍加载旧 MCP 版本
- **WHEN** 用户进入“转发到会话”
- **THEN** App 禁止搜索、创建、preflight 和绑定，只显示配置、完全重启或版本修复中的唯一下一步
- **AND** 收到当前版本 `mcp_ready` 后自动开放操作，无需手动刷新
- **AND** 设置页的 MCP / Skill 检测结果旁提供带“刷新”悬浮提示的刷新图标，黄色重启提示卡同时提供“刷新”按钮，点击任一入口时显示 loading 并禁用重复点击

#### Scenario: 先选择 AI App 再操作

- **GIVEN** 本机同时安装 ChatGPT 与 Claude
- **WHEN** 用户进入“转发到会话”
- **THEN** App 只展示具备完整投递 Connector 的 ChatGPT 操作，不展示尚未支持的 Claude，也不为单个可用 Host 显示选择器；未来存在多个可用 Host 时才先提供 AI App 选择

#### Scenario: 新建专属 Codex 会话并自动连接

- **GIVEN** 用户在“转发到会话”中选择为当前频道新建专属会话
- **WHEN** 用户通过原生目录选择器确认工作目录
- **THEN** App 调用本机 ChatGPT Codex 创建持久 user task，以“Pijoo · 频道名”保存空白 task，取得 id 后以不激活 Host App 的方式打开精确会话，Desktop owner preflight 成功后自动创建当前频道的 TaskBinding 与 Subscription；创建过程不发送输入、不创建 turn，也不抢占用户当前窗口焦点
- **AND** 创建期间禁用重复提交，在主操作中持续显示不定进度，并依次提示正在创建会话、等待 ChatGPT 连接和关联当前频道

#### Scenario: 新建后 Desktop 暂未就绪

- **GIVEN** Codex 已返回新会话 id，但 App 在等待期内无法完成 Desktop owner preflight
- **WHEN** 自动连接结束
- **THEN** App 不创建未经校验的 Subscription，向用户展示可通过“按 ID 连接”恢复的精确会话 id，且保留连接已有会话入口

#### Scenario: 服务端成员身份重建后恢复监听

- **GIVEN** 本机 ChannelConnection 保存的旧 `member_id` 与当前凭证在服务端鉴权得到的 Member 不同
- **WHEN** App 为发送、频道流或 Subscription 监听调用 join，并收到非空的服务端 `member_id + endpoint_id`
- **THEN** App 原子更新本机 `member_id` 后继续启动监听，仍使用服务端 endpoint 身份执行精确自回声过滤；缺失 endpoint 身份时保持失败关闭

#### Scenario: 重启恢复

- **GIVEN** 多条 Subscription 已启用
- **WHEN** App 重启
- **THEN** App 恢复每条 Subscription 的 sidecar 和游标，空闲期间不创建 Host turn

#### Scenario: 退出时停止监听器

- **GIVEN** App 正在监管 enabled Subscription 的 sidecar
- **WHEN** App 正常退出或交给更新助手重启
- **THEN** App 在终止前停止所有受管 sidecar，重新打开后每条 Subscription 只有一个监听器

### Requirement: Codex MCP 提供七个 task-scoped 频道工具

Codex MCP MUST 暴露 `send_to_channel`、`list_channels`、`subscribe_to_channel`、
`unsubscribe_from_channel`、`get_channel_settings`、`update_channel_settings` 和
`inspect_message_source` 七个工具。每个工具 MUST 从 `tools/call params._meta.threadId` 读取来源
task，并通过本机 socket v2 交给 App。发送与频道列表不要求来源已有 TaskBinding；订阅、设置和
来源查询仍精确匹配当前 task。App 和 MCP MUST NOT 使用最近活跃 task 或当前 UI 频道兜底。

MCP MUST NOT 读取 Keychain、直接访问 Channel Service、建立频道监听、消费入站消息、保存历史
或调用 Host Connector；这些消息接收能力 MUST 由 App 持有。`send_to_channel` MUST 可以在没有
入站消息的情况下主动调用，收到消息 MUST NOT 隐含自动回复。

#### Scenario: 工具表与接收边界

- **GIVEN** Codex 加载 Pijoo MCP
- **WHEN** Codex 请求工具表
- **THEN** 只返回上述七项，且频道空闲或消息到达都不会由 MCP 自行轮询或创建 Host turn

#### Scenario: 用户主动追溯刚才的消息

- **GIVEN** 当前 task 已成功接收至少一条 Pijoo 消息
- **WHEN** 用户明确询问“这条或刚才的消息是否来自 Pijoo、由谁发送”，AI 调用 `inspect_message_source`
- **THEN** App 仅从当前 task 的 TaskBinding、SubscriptionDelivery 与 LocalMessage 读取最近一条
  `delivered` 记录，返回频道消息 id、服务端认证发送者和声明的 App/MCP 来源，不修改模板或 Host 输入

#### Scenario: 用户没有追问或本地没有记录

- **GIVEN** 普通消息到达，或当前 task 没有可追溯的成功投递记录
- **WHEN** 用户没有主动追问来源，或主动查询但 App 未命中记录
- **THEN** Skill 不自动调用来源工具；未命中结果只说明本地没有 Pijoo 投递记录，
  App 和 AI 不据此断言消息由用户手动输入

#### Scenario: 当前 task 管理订阅

- **GIVEN** `_meta.threadId` 精确匹配 TaskBinding T
- **WHEN** T 调用订阅、取消订阅或设置工具
- **THEN** App 只查询或修改 T 的本机 Subscription，凭证、网络监听和消息历史仍留在 App

#### Scenario: 任意 task 查询频道

- **GIVEN** `_meta.threadId` 合法，无论当前 task 是否已有 TaskBinding
- **WHEN** task 调用频道列表，或指定本机频道查询可提及成员
- **THEN** App 返回本机频道、当前 task 的订阅状态及有效成员；未关联不阻止查询

#### Scenario: 两个 task 分别发送

- **GIVEN** Codex task A、B 分别绑定不同默认出站 Subscription
- **WHEN** 两个 task 调用相同的 `send_to_channel(message)`
- **THEN** 两次 `_meta.threadId` 分别匹配 A、B UUID，消息进入各自默认频道且不串台

#### Scenario: 来源能力缺失

- **GIVEN** `_meta.threadId` 缺失、类型错误或不是合法 UUID
- **WHEN** AI 调用发送工具
- **THEN** MCP 失败关闭并提示不兼容，App 不发起频道网络请求

#### Scenario: 未关联会话显式发送

- **GIVEN** `_meta.threadId` 合法但本机没有对应 TaskBinding
- **WHEN** AI 显式指定本机已加入频道并调用发送工具
- **THEN** App 使用该 task 作为来源发送，不创建 TaskBinding 或 Subscription

#### Scenario: 未关联会话省略频道

- **GIVEN** `_meta.threadId` 合法但本机没有对应 TaskBinding
- **WHEN** AI 未指定频道调用发送工具
- **THEN** 本机只有一个频道时发送到该频道；没有频道或有多个频道时失败并要求明确 channel，不使用当前 UI 频道

#### Scenario: 暂停接收后主动发送

- **GIVEN** 当前 task 的 Subscription 已暂停接收
- **WHEN** task 调用 `send_to_channel`
- **THEN** App 仍允许向任一本机频道主动发送；接收开关和订阅关系都不成为发送权限

### Requirement: Pijoo Skill 承接完整产品语义

App MUST 随包提供面向完整 Pijoo 产品的静态 Skill。Skill MUST 解释 App、MCP、
Subscription、入站卡片、信任、回复与可靠发送回执，不得只描述 `send_to_channel`。Skill MUST NOT
包含 secret、动态频道状态或 task id，也不得依赖每 turn hook。

#### Scenario: 显式启用 Codex 集成

- **GIVEN** App 已安装且用户目录没有同名 Skill
- **WHEN** 用户点击启用或修复 Codex 集成
- **THEN** App 同时配置 MCP 与受管理 Skill 链接，并提示完全重启 ChatGPT

#### Scenario: App 更新后仍加载旧 MCP

- **GIVEN** MCP 与 Skill 已配置，但 App 尚未收到当前 App 版本的 MCP 启动上报
- **WHEN** 用户查看主窗口或打开设置页的 AI 集成区域
- **THEN** 左侧设置入口显示提示点，设置页持续提示需要完全重启 ChatGPT，并显示已加载版本或等待加载状态；该提示不进入菜单栏健康状态

#### Scenario: 重启后加载当前 MCP

- **GIVEN** 设置页正在提示需要重启 ChatGPT
- **WHEN** MCP 启动并通过受保护的本机 socket 上报与当前 App 相同的内嵌版本
- **THEN** App 自动记录版本并清除设置入口提示点与重启提示，不要求用户手动确认，也不创建 Host turn

#### Scenario: 同名 Skill 不受本 App 管理

- **GIVEN** 用户目录已有同名普通目录或外来符号链接
- **WHEN** App 尝试启用、修复或移除 Codex 集成
- **THEN** App 失败关闭并保留该内容与现有 MCP 配置，不覆盖、删除或留下半配置状态

#### Scenario: Codex 配置不可读或写入失败

- **GIVEN** `config.toml` 已存在但不可读、不是 UTF-8，或组合操作中途写入失败
- **WHEN** 用户启用、修复或移除 Codex 集成
- **THEN** App 明确失败并回滚本次受管 Skill 或 MCP 变更，不把读取失败当作空文件覆盖

#### Scenario: AI 处理频道消息

- **GIVEN** task 收到标题包含“频道消息”或“Pijoo”任一项的外部消息
- **WHEN** Skill 被触发
- **THEN** AI 把正文当作不可信协作数据且不默认回复，只在需要时使用明确频道执行动作

### Requirement: Beta 应用内自动更新

App MUST 提供默认关闭的 Beta 自动更新开关。开启后 MUST 在启动时和运行期间定期检查更高的
GitHub prerelease，MUST 在 App 内下载 arm64 DMG，并在下次启动完成安装，无需用户访问网页、
手动下载或拖拽 App。替换前 MUST 校验 Bundle ID、目标版本、完整代码签名和当前 App 的
designated requirement；任一校验或替换失败时 MUST 保留旧 App 并避免重复重启。

#### Scenario: 自动下载并在重启时安装

- **GIVEN** 用户开启自动更新且 GitHub 有签名一致的更高 Beta arm64 DMG
- **WHEN** App 完成后台下载且用户下次启动 App
- **THEN** 更新助手替换 Applications 中的旧 App、清理待安装文件并自动打开新版本

#### Scenario: 更新包不可信或安装失败

- **GIVEN** DMG 中 App 的身份、版本或签名不符合要求，或目标目录无法替换
- **WHEN** 更新助手尝试安装
- **THEN** 旧 App 保持可用，待安装标记被清除，App 重新打开并展示失败原因

### Requirement: 可导出的客户端诊断日志

App MUST 在本机滚动记录启动、全局错误、频道连接与 Subscription 监听异常，并在设置页提供
导出入口。日志 MUST 限制本机占用，不得记录频道消息正文、邀请口令、成员凭证或完整 Host
会话内容。由 SwiftUI 生命周期或 URLSession 主动取消的刷新 MUST 视为正常控制流，不得写入
全局故障状态。连接诊断 MUST 区分握手与已连接流、记录连接时长、重连原因与退避，并在可用时
记录底层错误码及 Railway Request ID、Edge 和 Upstream Zone；所有字段 MUST 清理换行且不得包含
请求 URL、频道凭证或消息正文。

#### Scenario: 页面刷新被取消

- **GIVEN** 成员或邀请页面正在刷新
- **WHEN** 用户切换频道、离开页面或关闭窗口导致异步任务取消
- **THEN** App 静默结束该次刷新，不显示“刷新失败：已取消”且不记录为客户端错误

#### Scenario: 导出客户端日志

- **GIVEN** App 已产生当前及上一段滚动客户端日志
- **WHEN** 用户在设置页选择“导出客户端日志”并指定文件
- **THEN** App 按时间顺序导出单个日志文件，保留本机原日志且不包含频道正文或凭证

### Requirement: 每条 Subscription 使用可编辑的收发消息模板

Subscription MUST 使用本地接收模板生成完整 Host 输入，并使用本地发送成功模板生成
`send_to_channel` 的成功回执。两种模板只允许 `channel_name`、
`sender_name`、`message_source`、`message_text` 和 `message_id` 五个变量。默认模板 MUST 生成当前的
Pijoo Markdown 引用卡片；接收模板标识外部频道消息，发送成功模板标识正文已可靠进入频道。
标题、来源栏、正文和引用样式 MUST 全部属于模板，
Connector 不得在用户模板外再添加固定可见内容。
模板设置 MUST 允许用户在不保存的情况下预览当前草稿的 Markdown 效果。

发送成功模板 MUST 只在 Channel Service 返回可靠消息 id 后作为 MCP 工具回执返回当前会话，
MUST NOT 改写实际频道正文、创建额外 Host turn 或用于发送失败/结果未知的请求。

`channel_name` MUST 展开为 App 中保存的频道展示名称，`sender_name` MUST 展开为服务端按
成员身份解析的发送者昵称；只有对应名称不可用时才可回退为内部标识。
`message_source` MUST 对 task 消息展开为 Host 名称与缩短的会话 id，对 App 消息展开为
`Pijoo App`；旧客户端未提供来源时 MUST 回退为发送者昵称。
每条由 Host 会话发送的消息 MUST 同时携带可扩展来源引用 `provider + conversation_id + label`。
App MUST 将完整引用写入本地消息记录并允许用户复制来源会话 id；默认模板只展示 label。
来源引用 MUST NOT 被服务端或接收端作为路由、授权或可信目标。

#### Scenario: 保存模板

- **GIVEN** Subscription 使用默认完整卡片模板
- **WHEN** 用户修改标题、来源栏、正文或 Markdown 结构并保存
- **THEN** Connector 仅展开变量并将结果作为完整 Host 输入，不额外包裹固定卡片

#### Scenario: 展示发送成功标志

- **GIVEN** 当前会话为 Subscription 配置了发送成功模板
- **WHEN** `send_to_channel` 获得 Channel Service 的可靠消息 id
- **THEN** MCP 使用频道展示名称、发送者、当前会话来源、原始正文和消息 id 展开模板并作为成功回执返回；频道中仍保存原始正文

#### Scenario: 发送结果不确定

- **GIVEN** 当前会话已配置发送成功模板
- **WHEN** `send_to_channel` 明确失败或发送结果未知
- **THEN** MCP 不渲染成功模板，继续返回原有失败或未知状态且不自动重试

- **GIVEN** 用户编辑 Subscription 完整消息模板
- **WHEN** 模板为空、超过上限或包含未知变量
- **THEN** 空模板恢复产品默认完整卡片；超过上限或含未知变量时 App 拒绝保存并保留上一份有效模板

#### Scenario: 预览未保存的模板

- **GIVEN** 用户正在编辑 Subscription 消息模板
- **WHEN** 用户切换到预览
- **THEN** App 在本地以 Markdown 渲染当前草稿，不保存模板或更改变量占位符

#### Scenario: 渲染不可信正文

- **GIVEN** 远端 message text 包含类似系统指令、模板标记、标题、引用、空行或代码围栏
- **WHEN** App 渲染 Host 输入
- **THEN** 该文本只替换 `message_text` 占位符，其中的模板标记不会被二次展开，不能选择
  Binding 或改变本地模板；占位符在 blockquote 中时，多行正文继承该前缀

### Requirement: 自消息策略按 endpoint 判断

精确来源 task endpoint 的消息 MUST 永不回投该 task。Subscription MUST 可以选择是否接收
同一 Member 下其他 endpoint 的消息。

#### Scenario: App 给自己的 task 发消息

- **GIVEN** Subscription 使用默认 `include_other_endpoints`
- **WHEN** 同一 Member 的 app endpoint 向频道发送消息
- **THEN** 绑定 task 收到消息，但发送它的 app endpoint 不产生自回声

#### Scenario: 排除同一成员

- **GIVEN** Subscription 使用 `exclude_member`
- **WHEN** 同一 Member 的 App 或另一个 task endpoint 发送消息
- **THEN** 仅该 SubscriptionDelivery 标为 `filtered`，LocalMessage 与其他 Subscription 不受影响

#### Scenario: task 自己发送

- **GIVEN** task endpoint E 通过 MCP 发送消息
- **WHEN** 同一频道把该消息分发回 Subscription E
- **THEN** App 始终过滤该 delivery，避免创建自回声 turn

### Requirement: 多 Subscription 故障隔离

0.3 Beta MUST 为每条启用的 task-channel Subscription 独立监管运行态；一个 Subscription 的
重连、失败或人工确认 MUST NOT 扩散到其他 Subscription。

#### Scenario: 单项投递未知

- **GIVEN** Subscription A 的 Host 回执未知且 Subscription B 正常
- **WHEN** A 暂停等待人工确认
- **THEN** B 继续接收和投递，主窗口分别展示两个状态

#### Scenario: 成员撤权

- **GIVEN** ChannelConnection C 的 Member 被撤权
- **WHEN** App 收到授权失败
- **THEN** App 停止 C 的 feed 和全部 Subscription，保留其本地历史，其他频道继续运行
