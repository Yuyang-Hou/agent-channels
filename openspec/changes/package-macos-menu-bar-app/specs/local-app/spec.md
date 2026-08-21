# Local App Requirements

## ADDED Requirements

### Requirement: 单 Binding 菜单栏生命周期

首版 App MUST 在一个本机进程中管理一个频道与一个 Codex task Binding，并在用户切换
ChatGPT task 或其他 App 后继续监听。

#### Scenario: 后台监听

- **GIVEN** 用户完成频道与 task Binding 并开始监听
- **WHEN** 用户切换到另一个 ChatGPT task
- **THEN** 菜单栏 App 继续保持 SSE，真实消息仍进入原绑定 task

#### Scenario: 空闲频道

- **GIVEN** App 正在监听且频道没有普通消息
- **WHEN** 时间经过
- **THEN** App 不请求 Host 创建 turn

### Requirement: 本机 secret 隔离

频道 token 与 owner password MUST 存入 Keychain，MUST NOT 出现在进程参数、环境变量、
Binding 文件或模型正文中。

#### Scenario: 启动监听

- **GIVEN** Keychain 已保存频道 secret
- **WHEN** App 启动内嵌 Bridge
- **THEN** secret 只经子进程 stdin 传入且 argv 与 Binding 文件不含 secret

#### Scenario: AI 回复

- **GIVEN** 目标 AI 获得回复工具
- **WHEN** AI 调用回复
- **THEN** 模型只提供 reply reference 与文本，工具自行从 Keychain 取得频道 token

### Requirement: 无副作用预检

App MUST 在监听前验证 Desktop IPC 与目标 task owner，且预检 MUST NOT 创建或修改 AI turn。

#### Scenario: 可用 task

- **GIVEN** 用户在本次 Desktop 生命周期打开过绑定 task
- **WHEN** App 执行预检
- **THEN** initialize 与 owner discovery 成功且没有 steer、start 或 follow 请求

#### Scenario: 需要重新绑定

- **GIVEN** Desktop IPC 可连接但找不到 task owner
- **WHEN** App 执行预检
- **THEN** App 显示打开该 task 一次的操作提示且不开始消费频道消息

### Requirement: 最小回复授权

App MUST 只在用户显式确认后安装固定 STDIO MCP，并且回复工具 MUST 只能使用一次性引用向
原发送者发送文本。

#### Scenario: 首次启用回复

- **GIVEN** 用户尚未启用 Agent Channels 回复工具
- **WHEN** 用户确认配置变更
- **THEN** App 写入受 marker 管理的 MCP 配置并提示重启 ChatGPT

#### Scenario: 重复或伪造引用

- **GIVEN** reply reference 已使用、未知或不属于当前频道
- **WHEN** AI 调用回复工具
- **THEN** 工具拒绝发送且不暴露本机凭证

### Requirement: 可操作错误状态

App MUST 区分连接中、可用、需要重新绑定、授权失败和投递结果不确定。

#### Scenario: 不确定投递

- **GIVEN** mutating Desktop IPC 请求已发送但无法确认回执
- **WHEN** Bridge 停止自动重放
- **THEN** App 显示人工核对后的跳过或重试动作

#### Scenario: 旧 daemon 环境

- **GIVEN** 本机存在可能冲突的旧 daemon 环境设置
- **WHEN** App 诊断连接失败
- **THEN** App 解释并提供显式修复步骤，不静默修改环境变量
