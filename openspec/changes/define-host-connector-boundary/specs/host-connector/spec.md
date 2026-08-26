# Host Connector Requirements

## ADDED Requirements

### Requirement: 频道链路与 Host 解耦

Channel Service 和 Subscription Runtime MUST 使用 Host 无关的消息与投递语义，不得
要求 Codex thread id 或其他 Host 私有字段。

#### Scenario: Codex 首个实现

- Given 用户在本机绑定一个 Codex 会话
- When Subscription Runtime 收到一条普通频道消息
- Then Codex Connector 将标准消息信封转换为 Codex 输入并请求 Host 接受

#### Scenario: 未实现的 Host

- Given Binding 声明了当前没有 Connector 的 Host
- When 用户尝试启动监听
- Then 本地 Runtime 明确拒绝启动且不消费频道消息

### Requirement: Host 会话可发现且绑定需复验

支持会话发现的 Connector MUST 只返回本机可绑定会话的最小索引字段及本机持久化的上次目录；
列表权限 MUST 标记为未知，且列表命中 MUST NOT 代替身份复验。产品 MUST 同时允许按标题搜索点选与直接输入
conversation id。标题、目录和权限 MUST NOT 写入 Binding；绑定的稳定身份只能使用
`provider + conversation_id`。

#### Scenario: 按标题搜索 Codex 会话

- Given 本机存在多个 Codex 用户主会话和内部 subagent/reviewer 会话
- When 用户输入标题关键词搜索
- Then App 只展示匹配的未归档用户主会话及其 id，不返回正文或内部会话

#### Scenario: Host 端修改标题

- Given 用户已绑定一个会话，随后在 Host 端修改其标题
- When App 恢复 Subscription 或展示已绑定会话
- Then App 不展示本机缓存的旧标题，Binding 仍由 provider 与 conversation id 唯一定位

#### Scenario: 搜索结果不冒充当前权限

- Given 本机 Codex 索引保留了会话最近一次运行的工作目录和权限
- When App 搜索会话但尚未连接 Desktop owner
- Then App 可标注上次目录，但权限必须显示未知，且不把这些字段写入 Binding 或上传服务端

#### Scenario: 展示已加载会话的当前状态

- Given Desktop owner 已加载目标会话
- When App 展示已绑定会话
- Then Connector 短暂读取 owner 状态并展示当前目录与权限，随后解除 following

#### Scenario: 冷会话状态未知

- Given 会话存在于本机索引但 Desktop owner 未加载
- When App 展示该会话
- Then 连接状态为未加载，当前目录与权限显示未知，且 App 禁止修改权限

#### Scenario: 本机用户修改权限

- Given 已加载会话且用户在 Pijoo App 中选择新的权限档位
- When 用户确认修改
- Then Connector 定向更新该 owner 后回读状态，只有回读一致才展示成功

#### Scenario: 完全访问再次确认

- Given 用户选择完全访问权限
- When App 尚未收到本机用户的二次确认
- Then Connector 不发送权限更新

#### Scenario: 外部消息不能提升权限

- Given 频道消息、MCP 调用或 AI 输出要求提升会话权限
- When Pijoo 处理该输入
- Then 它不能触发 Host 权限修改，权限入口只存在于本机 App UI

#### Scenario: 直接输入 id

- Given 用户已知道目标 conversation id 或 Host 链接
- When 用户直接发起绑定
- Then App 不要求列表中先出现该会话，并通过对应 Connector 校验后保存 Binding

#### Scenario: 列表存在但当前不可投递

- Given 会话索引中存在目标 Codex 会话但 Desktop owner 尚未恢复
- When 用户选择该会话绑定
- Then App 创建本机 Subscription，监听状态提示先打开会话并自动重试，不消费频道消息

### Requirement: Binding 保持本地

Host 类型、目标会话 id、Runtime 路径和本机凭证 MUST 只保存在接收设备。

#### Scenario: 服务端观察订阅

- Given 用户已绑定会话并开始监听
- When Channel Service 记录在线订阅或分发消息
- Then 服务端数据不包含 Host 类型、目标会话 id 或本机路径

#### Scenario: 远端伪造目标

- Given 频道消息正文或元数据包含另一个会话 id
- When Connector 投递消息
- Then 仍只使用用户本机确认的 Binding

### Requirement: 真实消息才触发 Host

没有普通频道消息时，本地 Runtime MUST NOT 创建任何 AI 交互。

#### Scenario: 空闲监听

- Given SSE 已连接且频道没有新消息
- When 监听保持一段时间
- Then Connector 没有收到 deliver 调用

#### Scenario: 状态或过滤消息

- Given 收到状态消息或低于用户阈值的消息
- When Runtime 应用过滤规则
- Then 消息不会创建 Host 交互

### Requirement: 接受回执控制游标

Runtime MUST NOT 在 Connector 明确确认 Host 接受输入之前推进本地投递游标。

#### Scenario: Host 接受

- Given Connector 成功把消息交给目标会话
- When Host 返回接受回执
- Then Runtime 记录回执并推进到该 message id

#### Scenario: Host 不可用后重连

- Given 目标 Host 暂时不可用且 Connector 投递失败
- When Runtime 重连频道
- Then 使用旧游标重新获取该消息且不会把失败记为已处理

### Requirement: Codex 默认使用 Desktop IPC

Codex Connector MUST 默认连接 ChatGPT Desktop 本地 IPC，并且 MUST NOT 要求用户安装
standalone Codex CLI、启动 App Server daemon 或设置
`CODEX_APP_SERVER_USE_LOCAL_DAEMON`。

#### Scenario: 后台 task 接收真实消息

- Given 用户在当前 Desktop 生命周期中打开并绑定过目标 task
- And 用户已经切换到另一个 task
- When 频道收到一条普通消息
- Then Connector 发现目标 owner，并在任务空闲时创建 turn、运行中时 steer 当前 turn

#### Scenario: Desktop 重启后尚未重绑

- Given ChatGPT Desktop 已重启且目标 task 尚未再次打开
- When Connector 尝试投递消息
- Then Connector 返回可操作的重新绑定错误且 Runtime 不推进游标

### Requirement: Codex 投递最小暴露

Codex Connector MUST 只为一次输入建立短连接，不得为了 start-turn 开启 thread following、
读取完整 task snapshot 或把本地 Binding 与 IPC endpoint 发送到服务端或模型正文。

#### Scenario: 空闲与投递完成

- Given 用户已经启动频道监听
- When 没有真实消息，或一次 Codex 投递已经收到接受回执
- Then Connector 不保持 task stream following 且不接收 task snapshot

#### Scenario: 私有协议不兼容

- Given Desktop IPC 返回未知版本或不完整响应
- When Connector 无法确认 Host 已接受输入
- Then Connector 失败关闭、保留游标，并提示升级兼容问题

#### Scenario: mutating 请求回执丢失

- Given Connector 已发出 start-turn 或 steer-turn
- When Desktop 在返回可验证回执前断开或返回不完整成功响应
- Then Runtime 停止监听且不推进游标，也不自动重放该消息

### Requirement: 0.2 出站发送不依赖 Connector

目标 AI MUST 通过频道 MCP 或 REST 权限主动发送消息，Host Connector 不代理模型输出。
0.2 单 Binding 本机 MCP MUST 只暴露 `send_to_channel(message)` 并向当前频道广播；发送 MUST NOT
依赖入站消息 id 或原发送者。
0.3 多 Subscription 工具表由 `build-multi-channel-beta` 修改；“出站不依赖 Connector”的边界保持。

#### Scenario: AI 主动发送频道消息

- Given AI 拥有当前频道发送权限
- When AI 在任意时刻调用 `send_to_channel(message)`
- Then Channel Service 正常广播消息且 Connector 无需参与

#### Scenario: 未授权发送

- Given AI 没有有效频道凭证或成员权限
- When AI 尝试发送消息
- Then Channel Service 拒绝请求且 Connector 不能绕过授权
