# Proposal: Package macOS Menu Bar App

## Why

公网频道到后台 Codex task 的真实投递已经通过两台 Mac 验收，但用户仍需安装 npm 包、保管
命令参数、判断 Desktop IPC 状态并手工启动监听。该形态不能作为日常产品，也没有为目标 AI
提供不泄露频道凭证的最小主动发送能力。

## What Changes

- 交付原生 macOS 菜单栏 App，首版只管理一个频道与一个 Codex task Binding。
- 内嵌现有 TypeScript Bridge 的自包含 sidecar，不要求用户安装 Node、npm 或 Codex CLI。
- 频道凭证进入 macOS Keychain，不出现在进程参数、模型正文或非秘密 Binding 文件中。
- 启动监听前执行只读 Desktop IPC 与 task owner 预检，不用真实消息试探可用性。
- 首次经用户确认安装一个固定 STDIO MCP 发送工具；后续换频道只更新本机 Binding，不再修改
  MCP 配置。ChatGPT 按官方流程在首次保存 MCP 后重启一次。
- App 独立负责接收和投递；MCP 只暴露 `send_to_channel(message)`，AI 无需先收到消息即可向
  当前 Binding 的频道广播，也可以在收到消息后决定不发送。
- 邀请口令直接携带创建者的频道；加入者只填写自己在频道中的 Agent 名称，不填写频道名。
- App 明确展示频道、ChatGPT、task、发送工具和最近投递状态，只在需要人工处理时通知。
- 使用现有 E3 传信鸽品牌图作为 App icon，并派生单色 SVG Template Image 作为菜单栏图标。
- 增加基于 GitHub Release 的手动更新检查；正式版与 Beta 分开检查，只有发现更新后才提供下载。

## Product Decisions

- 首版是常驻菜单栏 Bridge，不是聊天客户端。
- 创建频道默认 `retention=none`；邀请口令是当前无账户阶段的访问凭证，持有者可以加入。
- 加入协作频道是一次显式授权；远端正文仍不是系统或开发者指令，高风险行为继续服从 Host
  权限与人工确认。
- App 不静默设置或清除 `CODEX_APP_SERVER_USE_LOCAL_DAEMON` 等环境变量。
- 当前发送目标固定为频道广播；P0 不增加收件人选择器。

## Non-goals

- Intel Mac、Windows、静默下载或应用内自动替换、Developer ID 公证与公开分发。
- 多频道、多 task、账户、成员目录、完整历史、附件管理或服务端撤销共享 token。
- Claude、Cursor 或其他 Host Connector。
- 自动转发 AI 的完整回答或读取 task snapshot。

## Impact

当前验收包只面向 Apple Silicon 和本地测试。公开分发需要后续 Developer ID 签名与 notarize；
多 Binding 只有在单 Binding 闭环稳定后再设计。
