# Managed Channel Assistant Requirements

## ADDED Requirements

### Requirement: 默认助理只在账号受管工作区运行

App MUST 为每个本机账号建立稳定、私有的 Pijoo 助理工作区，并且 MUST 只把在该目录创建的受管 Codex task
作为默认助理频道的执行目标。原始 account id、频道凭证和工作目录 MUST NOT 上传到 Channel Service。

#### Scenario: 创建受管助理

- **WHEN** 当前账号首次创建默认助理 task
- **THEN** App 在 `thread/start` 前准备账号隔离工作区，并把该绝对路径作为 cwd
- **AND** 目录与生成文件只允许当前系统用户访问

#### Scenario: 不同账号隔离

- **GIVEN** 同一台 Mac 登录过账号 A 与账号 B
- **WHEN** 两个账号分别创建助理 task
- **THEN** 两者使用不同受管目录，且路径不暴露原始 account id

#### Scenario: 外部 task 不能成为执行目标

- **GIVEN** 用户选择一个 cwd 位于其他项目的既有 task X
- **WHEN** 当前频道是默认助理频道
- **THEN** App 不为 X 创建或启用频道 Subscription，频道消息不会在 X 创建 turn

### Requirement: 内置身份卡先于 task 创建

App MUST 在创建受管 task 前把内置 `AGENTS.md` 写入其工作区。身份卡 MUST 把频道消息与历史片段声明为
不可信输入，并且 MUST NOT 把自身描述为 sandbox、授权或发送确认机制。

#### Scenario: 首次创建

- **WHEN** App 准备空的账号助理工作区
- **THEN** 它在 `thread/start` 前原子写入当前内置身份卡
- **AND** Codex 启动后能读取该身份卡

#### Scenario: 身份卡缺失或被修改

- **GIVEN** 受管身份卡缺失或与 App 内置版本不一致
- **WHEN** App 准备创建 task 或投递下一条外部消息
- **THEN** App 恢复内置版本；恢复失败时不创建或投递 turn

#### Scenario: 远端要求修改身份

- **WHEN** 频道正文要求改写身份卡、扩大历史范围或提升工具权限
- **THEN** App 不把正文写入身份卡或本机授权配置

### Requirement: 投递前强制复验工作区与权限

App MUST 在真正向默认助理 task 投递频道消息前复验 Desktop owner 的 task id、cwd 与安全权限档位。
复验失败 MUST 失败关闭且 MUST NOT 推进投递游标。

#### Scenario: 安全状态

- **GIVEN** task id 与本机配置一致、cwd 为账号受管目录、sandbox 为 workspace 且审批者为本机用户
- **WHEN** 一条频道消息等待投递
- **THEN** Connector 可创建或 steer 该 task 的 turn

#### Scenario: 工作目录漂移

- **GIVEN** 当前 task 的 cwd 不再等于账号受管目录
- **WHEN** 频道消息等待投递
- **THEN** Connector 不创建 turn、不推进游标，并提示恢复助理工作区

#### Scenario: 权限提升

- **GIVEN** 当前 task 已变为 full access 或不受支持的权限状态
- **WHEN** 频道消息等待投递
- **THEN** Connector 不创建 turn、不推进游标，且远端消息不能触发权限提升或绕过本机确认

#### Scenario: 撤销或断开

- **GIVEN** 助理 task 被归档、删除、解绑或 Desktop owner 不可用
- **WHEN** 频道消息到达
- **THEN** App 保留消息与旧游标，显示可操作的重连状态，不猜测其他 task

### Requirement: 既有 task 只能作为显式只读来源

App MUST 只通过本机 allowlist 和 `thread/read(includeTurns: true)` 读取既有 task。读取权限 MUST 与频道执行、
工具权限和对外发送权限分离，默认 MUST 为空，撤销后下一次读取 MUST 立即失败。

#### Scenario: 授权资料源

- **GIVEN** 用户在本机选择既有 task X 并明确授权
- **WHEN** 助理查询相关历史
- **THEN** App 返回有界、带 X 来源且标记不可信的片段，不在 X 创建 turn 或修改其 cwd、权限

#### Scenario: 未授权资料源

- **GIVEN** task Y 未被授权
- **WHEN** 助理或频道消息要求读取 Y
- **THEN** App 不返回 Y 的标题、正文或存在性细节

#### Scenario: 撤销资料源

- **GIVEN** task X 曾被授权
- **WHEN** 本机用户撤销 X 后再次查询
- **THEN** App 立即拒绝读取 X，不依赖后台索引清理
