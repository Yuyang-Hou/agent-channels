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

#### Scenario: AI 主动发送

- **GIVEN** 目标 AI 获得频道发送工具
- **WHEN** AI 调用 `send_to_channel`
- **THEN** 模型与 MCP 只把文本交给本机 App，由 App 从 Binding 与 Keychain 取得频道和凭证

#### Scenario: 本机发送隔离

- **GIVEN** 菜单栏 App 正在运行
- **WHEN** MCP 连接本机发送入口
- **THEN** 入口位于权限为 `0700` 的用户目录、socket 权限为 `0600`，且 App 只接受同 UID

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

### Requirement: 最小发送授权

App MUST 只在用户显式确认后安装固定 STDIO MCP，并且 MCP MUST 只暴露
`send_to_channel(message)`。发送 MUST 使用当前本机 Binding 向当前频道广播，不依赖入站消息。

#### Scenario: 首次启用发送

- **GIVEN** 用户尚未启用 Agent Channels 发送工具
- **WHEN** 用户确认配置变更
- **THEN** App 写入受 marker 管理的 MCP 配置并提示重启 ChatGPT

#### Scenario: 主动发送

- **GIVEN** AI 尚未从频道收到任何消息
- **WHEN** AI 调用 `send_to_channel` 并提供非空文本
- **THEN** 工具以当前 callsign 向当前频道广播且不暴露本机凭证

#### Scenario: App 未运行

- **GIVEN** 菜单栏 App 未运行或本机发送 socket 不安全
- **WHEN** AI 调用 `send_to_channel`
- **THEN** MCP 在向频道发出请求前明确失败并提示打开 App，允许用户安全重试

#### Scenario: 发送回执不确定

- **GIVEN** 频道发送请求已发出但未取得可靠回执
- **WHEN** MCP 返回工具结果
- **THEN** 结果明确标记发送结果不确定并要求 AI 不自动重试

### Requirement: 邀请直接确定频道

加入者 MUST 从 `ac1:` 邀请口令取得频道，App MUST NOT 再要求加入者填写频道名；服务端要求
的 callsign MUST 在 UI 中明确标为加入者自己的 Agent 名称。

#### Scenario: 使用邀请

- **GIVEN** 用户填写自己的 Agent 名称并粘贴有效邀请口令
- **WHEN** 用户点击使用邀请
- **THEN** App 保存邀请中的频道并展示已加入的频道

#### Scenario: 邀请频道不可修改

- **GIVEN** 邀请口令已经包含频道
- **WHEN** 用户进入加入流程
- **THEN** UI 不显示独立频道名输入框

### Requirement: 分通道检查 GitHub 更新

App MUST 提供正式版和 Beta 两个独立的手动检查入口，并且 MUST 只在远端版本高于当前版本时
提供下载动作。

#### Scenario: 检查正式版

- **GIVEN** GitHub 同时存在正式版与 prerelease
- **WHEN** 用户检查正式版
- **THEN** App 只比较最新非 prerelease Release

#### Scenario: 检查 Beta

- **GIVEN** GitHub 存在带 Beta 标签的 prerelease
- **WHEN** 用户检查 Beta
- **THEN** App 只比较 Beta prerelease，不把它提示给正式版检查

#### Scenario: 无需重复下载

- **GIVEN** 当前版本等于或高于所选通道的最新版本
- **WHEN** 检查完成
- **THEN** App 告知已是最新版本且不打开下载链接

### Requirement: 品牌图标

App MUST 使用仓库现有 E3 传信鸽图作为 App icon，并使用同轮廓的单色 SVG Template Image
作为菜单栏常态图标。

#### Scenario: 明暗菜单栏

- **GIVEN** 用户切换 macOS 明暗外观
- **WHEN** 菜单栏显示 Agent Channels
- **THEN** Template Image 由系统着色并保持可辨认

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

#### Scenario: 临时频道断线后恢复

- **GIVEN** SSE 连接临时关闭并产生连接错误
- **WHEN** Bridge 自动重连并再次报告 `connected`
- **THEN** App 恢复绿色连接状态并清除已经恢复的连接错误，不要求用户发送测试消息
