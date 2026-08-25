# Design

## Runtime Shape

```text
Channel Service
  -> Channel / Invite / Member / Endpoint / Message / Session
  -> member-scoped credentials and revocation

Pijoo.app
  -> main window + local history + Keychain
  -> ChannelConnection[]
  -> TaskBinding[] x Subscription[]
  -> one supervised listen-here sidecar per enabled task-channel Subscription
  -> one user-only app.sock for MCP and supervised sidecar -> App requests

Codex task
  <-> Pijoo Skill -> product semantics + trust + reply policy
  -> send_to_channel / list_channels
  -> subscribe_to_channel / unsubscribe_from_channel
  -> get_channel_settings / update_channel_settings
  -> tools/call params._meta.threadId
  -> local socket v2 -> exact TaskBinding -> App-owned operation
```

App 是本机配置、凭证、消息状态、频道监听、Host 投递和 sidecar 生命周期的唯一 owner。
Channel Service 不理解 TaskBinding；MCP 不读取 Keychain、不直接请求服务端，也不接收频道
消息；Skill 不持有动态状态；sidecar 不决定 UI 中的频道选择。

## Service Data Model

```text
Channel
  id, name, owner_member_id, created_at

Invite
  id, channel_id, token_hash, label, max_uses, use_count, created_at, expires_at, revoked_at

Member
  id, channel_id, display_name, role(owner|member), status(active|removed|banned),
  credential_hash, invite_id, created_at, revoked_at

Endpoint
  id, member_id, kind(app|task), label, status

Message
  id, channel_id, sender_member_id, sender_endpoint_id, sender_name,
  source(provider, conversation_id, label), text, created_at

OnlineSession
  id, member_id, endpoint_id, cursor, expires_at
```

邀请 token 是短期加入能力。加入成功后，服务端创建 Member，并只返回该 Member 自己的长期
凭证；owner 和每个加入者使用不同凭证。任何频道 API 都从 member credential 解析
`channel_id + member_id`，不得再接受共享频道 token 代表所有成员。

邀请在创建时设置备注、1–100 次使用上限和最长 30 天有效期，创建后不可修改；需要改变配置时
撤销旧邀请并新建。服务端仅保存 token hash，列表不返回明文。邀请状态由 `revoked_at`、
`expires_at` 和 `use_count / max_uses` 推导为 active、revoked、expired 或 exhausted。撤销邀请
只阻止后续兑换，不撤销已经创建的 Member；成员撤权继续使用成员管理。兑换检查、次数增加和
Member 创建必须作为一次持久化提交，单实例内并发请求不得超过 `max_uses`。

`removed` 与 `banned` 都撤销当前凭证、终止在线 session 并关闭现有 stream。`removed` 的成员
可以由 owner 通过新邀请重新加入；`banned` 的同一 Member 不能恢复或重新激活。0.3 Beta 没有
账户或设备证明，因此不能承诺阻止同一个自然人在拿到另一份新邀请后创建全新 Member；UI 和
文档必须明确这个边界。

Endpoint 只用于来源和自消息判断。task Endpoint 的 id 是不透明随机值；服务端不得保存目标
TaskBinding、工作目录或本机路径。发送端可为单条 Message 提供
`source(provider, conversation_id, label)` 供接收端追溯；它是不可信审计元数据，不参与路由、授权
或自消息判断。

`sender_name` 由服务端根据凭证对应的 Member 生成，UI 与 Host 卡片使用它展示；`from` callsign
继续承担端点路由兼容职责，不作为用户昵称。ChannelConnection 的 `display_name` 是本机频道昵称，
`channel_id` 是不可变原始名称和唯一网络路由键。

## Local Data Model

0.3 使用全新的版本化本地 store；不读取或改写 0.2 `binding.json`。

```text
ChannelConnection
  id, channel_id, member_id, display_name, credential_ref, app_endpoint_id,
  last_read_message_id, connection_state

TaskBinding
  id, provider, conversation_id, label, compatibility_state

Subscription
  id, channel_connection_id, task_binding_id, task_endpoint_id,
  enabled, is_default_outbound, template_id, same_member_policy,
  last_received_message_id, last_delivered_message_id, runtime_state

DeliveryTemplate
  id, name, body

LocalMessage
  channel_id, message_id, sender_member_id, sender_endpoint_id, sender_label,
  source(provider, conversation_id, label), direction, text, server_created_at, local_received_at, outbound_state

SubscriptionDelivery
  subscription_id, channel_id, message_id,
  state(received|filtered|delivered|failed|unknown), detail, updated_at

AppIdentity
  nickname
```

本地 secret 只存 Keychain；store 只保留 Keychain locator。`TaskBinding.conversation_id` 只在本机
使用。`LocalMessage` 以 `channel_id + message_id` 去重；同一服务端消息可以拥有多条不同的
SubscriptionDelivery。

0.3 不迁移旧数据：clean install 创建新 store。若检测到 0.2 数据，App 不导入、不覆盖、不
删除，只提示该 Beta 需要全新配置。

## Main Window

主窗口采用三块最小布局：频道侧栏、当前频道时间线与发送框、成员和会话转发详情；App 设置
作为同一侧栏的固定底部目的地呈现，与可增长的频道列表分隔，不创建独立 Settings Scene。
菜单栏继续展示总体状态并快速打开主窗口，但不再承担完整配置流程。快速打开必须先请求单实例
窗口，再于下一主循环激活、反最小化并置前，避免 `LSUIElement` 只把菜单浮窗变成 key window。

首次使用直接复用主窗口设置内容，只展示“身份”和“AI 集成”。全局昵称非空且 Codex MCP 与 Skill
均已配置后，App 自动进入频道主界面；任一条件未满足时不展示频道工作区。是否需要重启 ChatGPT
继续作为集成状态提示，不阻止已完成配置的用户进入主界面。

本地开发使用独立的 App-only 构建入口，跳过 DMG 和重复 self-test，完成后直接启动固定路径下的
`macos/build/Pijoo.app`。开发标记只放入该 App 的 Info.plist，使用户主动启用集成时可引用固定的
本地 bundle 路径；正式构建不包含该标记，继续要求位于 Applications。开发 App 修复 Skill 时，
只允许把 bundle id 同为 `dev.pijoo.menubar` 的旧 Pijoo bundle 内 Skill 链接切到当前开发 bundle；
普通目录、外来链接和其他 bundle 仍拒绝，后续 Codex 配置写入失败时恢复旧链接。

### 频道工作区交互方案

添加频道入口固定在侧栏“频道”标题旁，不进入会因可用宽度变化而折叠的窗口工具栏。频道详情收敛为三层：
窗口工具栏承载频道身份和当前频道动作；正文顶部使用轻量下划线导航在“消息 / 成员 /
转发到会话”间切换，不使用带内容边框的默认 Tab View；当前 Tab 只展示自身内容和操作。消息页取消额外
卡片容器与重复标题，时间线占满剩余空间，发送框固定在底部。消息按发送者与相邻时间聚合，正文优先，时间和投递状态降为次要信息；仅
`failed`、`unknown` 等需要处理的状态使用强调色，普通 `received` 不逐条显示英文状态。

侧栏添加频道使用带辅助功能标签和悬停说明的原生 `+` 图标，不重复展示文字按钮。成员页不常驻展示
邀请、移除和封禁的长篇说明：撤销与移除后果继续在对应确认框明确展示，封禁确认额外说明同一自然人
仍可持新邀请创建新 Member。转发页输入框已表达搜索与 ID 绑定能力，只保留低层级的 Host 支持范围。

添加频道弹窗先让用户在“创建频道 / 加入频道”之间二选一：创建路径只填写服务端频道名称，加入路径
只填写邀请口令。用户昵称在设置中全局维护，并同步为每个 ChannelConnection 对应 Member 的
`display_name`；endpoint callsign 只作为隐藏技术标识。唯一主按钮放在底部并随路径切换。

owner 从频道工具栏创建邀请，在原生成员页查看邀请状态、备注、已用次数和过期时间并撤销活跃
邀请。创建时只配置备注、有效小时数和可加入人数；成功后立即复制 `ac2:` 口令。App 不持久化邀请
明文，服务端也不能再次展示；需要重新分享时创建新邀请。撤销确认必须明确不影响已加入成员。

成员页和转发到会话页复用一致的“说明 + 列表 + 就地操作”节奏；用户界面使用“会话”和消息转发方向
表达结果，不暴露 `TaskBinding`、`Subscription` 等内部模型名。危险操作进入行尾菜单或确认流程，
不与高频主操作并排。第一阶段只调整信息层级、间距和本地化，不增加搜索、筛选、表情、附件或消息
线程；出现真实规模问题后再补相应能力。

App 为每个已加入频道维护消息 feed。普通消息到达时，必须先 upsert `LocalMessage` 为
`received`，随后才允许 Host delivery。这样即使 task 不可用、模板过滤或投递结果未知，用户
仍能在主窗口看到消息及其真实状态。

该顺序不能依赖异步 stderr 状态。0.3 的单一本机 App IPC 除 MCP 发送外，还提供 sidecar 使用的
`record_received` 与 `record_outcome` 请求：Subscription sidecar 在调用 Connector 前提交标准
消息信封，App 先持久化 LocalMessage 和 `received` SubscriptionDelivery，全部成功后才返回 ack；
任一步失败都不允许调用 Host。JSONL 允许失败重试产生重复物理记录，读取时必须按唯一键合并。

`record_received` 还必须按 `subscription_id + channel_id + message_id` 检查最新投递状态：已有
`delivered|filtered|skipped` 时返回 `already_processed`，sidecar 不调用 Host并只推进游标；已有
`attempting|unknown` 时返回 `unresolved` 并停止该 Subscription；`received|failed` 可以安全重试。
投递结束后 sidecar 再记录 filtered、delivered、failed 或 unknown。所有终态游标只能单调前进。

SSE 正常结束或异常断开都必须把本连接内最后一个成功处理的 message id 带回重连循环；不能因
body stream 异常退回连接开始前的游标。频道 feed 与多个 Subscription 重复看到同一消息时仍由
本地唯一键合并。

App 手工发送使用当前选中的 ChannelConnection 和 app endpoint。发送状态区分
`pending`、`accepted`、`failed` 与 `unknown`；只有可靠服务端回执才能标记 `accepted`。本地
历史在重启后保留并可由用户清空，但不宣称跨设备同步或永久保存。

## TaskBinding And Subscription

TaskBinding 只描述一个本机 Host 会话；Subscription 才表达“这个 task 接收这个频道”。删除
TaskBinding 必须先停掉相关 Subscription，删除 ChannelConnection 也必须停止其全部运行态。
TaskBinding 只持久化 `provider + conversation_id`，绑定后的稳定展示使用 Host 名称与缩短 id。
标题仅在会话搜索结果中通过对应 Host Connector 的只读发现能力即时获取，不写入 Binding。Codex 首个实现只从本机
`state_5.sqlite` 读取用户主会话的 `id/name/title/updated_at` 索引，排除 subagent/reviewer，且不读取
正文或 snapshot；用户可按标题或 id 搜索点选，也可直接输入 id/链接。创建 Subscription 前仍执行
Host preflight。

“转发到会话”只展示已安装且具备完整投递 Connector 的 AI App。只有一个可用 Host 时直接展示其操作，
不增加无意义的选择器；存在多个可用 Host 时才先选择 AI App。尚未闭环的 Claude 不展示。

“转发到会话”的主路径允许用户用原生目录选择器为当前频道新建专属 Codex 会话。App 通过内嵌
sidecar 调用已安装 ChatGPT Codex 自带的 `app-server thread/start`，显式创建持久 user task，
并以“Pijoo · 频道名”调用 `thread/name/set` 持久化空白 task；取得 conversation id 后立即打开
`codex://threads/<id>`。Desktop owner preflight 成功后才复用
既有 `TaskBinding + Subscription` 流程。创建本身不发送输入或创建 turn。创建后若 Desktop 暂未
就绪，App 必须显示可恢复的 conversation id；搜索、id/链接连接已有会话继续作为回退。

P0 每条启用的 Subscription 监管一个现有 `listen-here` sidecar，保持独立 session、游标、
错误和不确定投递状态。一个 Subscription 失败不得暂停其他 Subscription。App 可以为频道
时间线维护独立 feed；重复抵达由本地消息唯一键去重。本轮不把这些进程合并为 daemon。

每个 TaskBinding 最多有一条 `is_default_outbound=true` 的启用 Subscription。AI 主动发送时，
若指定频道，App 只允许使用当前 task 已启用的对应 Subscription；若省略频道，App 只使用唯一
默认项。没有默认项或存在多个默认项都必须失败关闭并提示用户在主窗口修复。Subscription 的
`enabled` 只控制接收监听；暂停接收不得阻止 task 通过该 Subscription 主动发送。

## Codex Source Routing

0.3 MCP 工具表固定暴露七项：

- `send_to_channel`：当前 task 随时主动发送，可使用显式已订阅频道或唯一默认出站频道；
- `list_channels`：列出 App 中当前 task 可见的频道及订阅状态；
- `subscribe_to_channel` / `unsubscribe_from_channel`：请求 App 创建或移除当前 task 的订阅；
- `get_channel_settings` / `update_channel_settings`：读取或修改当前 task 某条订阅的模板、
  自消息策略和默认发送设置。
- `inspect_message_source`：仅在用户主动追问时，读取当前 task 最近一条成功投递的本地消息来源；
  不读取 Host 历史，未命中也不推断为用户手动输入。

频道 SSE、消息接收、本地历史、sidecar 与 Host Connector 全部由 App 持有。MCP 只把当前工具的
已校验参数和 source context 交给 App；它不会因为消息到达而自动运行，也不把“收到消息”解释
为“必须回复”。普通 Codex MCP 调用当前可在 `tools/call params._meta.threadId` 提供来源 task
id，但它属于 Host 能力而非 Pijoo 稳定协议，因此必须做能力探测和实机验收。

例如发送工具在校验 `_meta.threadId` 后，通过 App IPC v2 提交：

```json
{
  "version": 2,
  "operation": "send",
  "message": "...",
  "channel": "optional-channel-id",
  "source": { "provider": "codex", "conversationId": "..." }
}
```

其余六项使用相同 source context，只附带各自需要的 `channel` 或 `settings`；所有频道凭证、网络
请求和接收状态都留在 App 内。

MCP 启动时通过同一本机 socket best-effort 上报内嵌版本 `mcp_ready`。该生命周期消息不带 source、
不创建 Host turn，也不接触频道数据；App 只持久化最近加载版本，并在设置页与当前 App 版本比较。
版本不一致时持续提示完全重启 ChatGPT，收到当前版本后自动清除，不占用菜单栏健康状态。

App 用 `provider + conversationId` 精确匹配 TaskBinding，再解析唯一默认出站 Subscription。
缺少 `_meta.threadId`、类型错误、未绑定、无默认 Subscription 或歧义时，不请求 Channel
Service，不回退到最近活跃 task、当前 UI 频道或全局 active channel。thread id 不进入工具正文、
服务端请求或频道消息。

能力探测必须覆盖两个同时打开的真实 Codex task，并记录 A/B `tools/call` 的 `_meta.threadId`
是否分别等于各自 UUID。源码观察只算设计依据，不能代替该实机门槛。

## Product Skill

Pijoo Skill 面向整个产品，而不是包装某一个 MCP 工具。它定义产品模型、App/MCP/Skill
边界、入站卡片识别、外部输入信任、是否回复、可靠发送回执和最小上下文披露规则；七项工具仍
只执行当前 task 的显式动作。

Skill 是 App Bundle 中不含 secret 或动态频道数据的静态资源。设置页的“启用或修复 Codex 集成”
在用户明确操作后同时写入受管理 MCP block，并在 `~/.codex/skills/pijoo` 创建指向 Bundle
资源的受管理链接。更新 App 即更新 Skill；同名普通目录或指向其他内容的链接必须失败关闭，移除
集成也只能删除本 App 的链接。启用和移除必须先读取并校验完整 Codex 配置与 Skill 归属；读取
失败不得当作空配置，组合操作中途失败必须回滚本次受管变更，并保留用户已有配置 symlink。
默认卡片保留 Pijoo 标题以触发 Skill；自定义标题包含“频道消息”或“Pijoo”
任一项同样触发，不增加每 turn hook。整段可见 Markdown 均属于本地
用户模板；外部内容的信任边界与是否回复由 Skill 统一解释，不在每条消息中重复展示说明文案。

## Templates And Self-Message Policy

每条 Subscription 选择本地接收模板和发送成功模板。两者只支持以下变量：

- `{channel_name}`
- `{sender_name}`
- `{message_source}`
- `{message_text}`
- `{message_id}`

保存时拒绝未知变量和超过本地上限的结果，空值恢复默认。模板控制完整 Markdown Host 输入；
默认值包含 Pijoo 标题、频道、发送者、消息 id、正文和 blockquote 样式。Connector 只展开
变量，并让多行 `{message_text}` 继承该占位符所在的 blockquote 前缀，不在模板外增加可见外壳。
远端正文只作为 `{message_text}` 数据插入，不能成为模板指令或选择目标 Binding。
`{message_source}` 对 task 消息使用 Host 名称与缩短的会话 id，对 App 消息使用
`Pijoo App`；旧客户端未提供来源时回退为发送者昵称。完整来源引用随消息写入本地记录，
其中 provider 与 conversation_id 用于追溯但不进入默认模板。

接收模板在消息进入 Host 时展开；发送成功模板只在 Channel Service 返回可靠消息 id 后展开为
`send_to_channel` 的工具回执，让当前会话可见哪些正文已经进入频道。它不改写频道 payload、
不制造自回声 turn，失败或 unknown 仍沿用可靠发送状态机。

精确 `sender_endpoint_id == subscription.task_endpoint_id` 的消息永远过滤，避免 task 自回声循环。
每条 Subscription 另有 `same_member_policy`：

- `include_other_endpoints`（默认）：接收同一 Member 下 App 或其他 task endpoint 的消息；
- `exclude_member`：过滤同一 Member 的所有消息。

过滤只把对应 SubscriptionDelivery 标为 `filtered`，不删除 LocalMessage，也不影响其他
Subscription。0.3 不提供“回投精确来源 endpoint”、脚本规则或自动回复。

## Recovery And State

- Channel feed、Subscription sidecar、TaskBinding 兼容性和每条 delivery 分别展示状态。
- 每条 Subscription 只有 Host 明确接受后才推进 `last_delivered_message_id`。
- `failed` 可按原语义重试；`unknown` 必须停住该 Subscription 并等待人工选择，不能拖停其他项。
- App 重启后恢复所有 enabled Subscription；空闲频道不创建 Codex turn。
- 成员撤权后清除对应 Keychain credential、停止该 ChannelConnection 的 feeds 和所有
  Subscription，但保留本地历史供用户查看或清空。

## Beta Boundary

0.3 验收只针对干净安装、新建频道和 Apple Silicon。旧 0.2 数据继续留在原位置但不参与运行。
预上线构建和公开分发只使用 Beta prerelease，允许用它完成跨设备验收；只有完成两台设备、
两个频道、两个真实 Codex task 的路由与撤权验收后，才允许发布稳定版或声明生产就绪。源码、
API 200 或单机 UI 演示都不算完成验收。

## In-App Beta Update

- 自动检查默认关闭；用户开启后在启动时及每 24 小时查询 GitHub prerelease。
- 发现更高 Beta 后把 arm64 DMG 下载到权限受限的 Application Support 更新目录，不自动退出。
- 下次启动由包内原生更新助手等待旧进程退出，挂载 DMG，并校验 Bundle ID、Release 版本、
  完整代码签名和当前 App designated requirement；全部通过后才原子替换 Applications 中的 App。
- 成功或失败都会重新打开 App；失败时删除待安装标记、保留旧 App 并展示错误，避免重启循环。
