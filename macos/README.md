# Agent Channels macOS

原生 macOS 13+ App。0.3 Beta 使用主窗口管理多个 RogerThat 频道、Codex task、
task-channel Subscription 和本地消息历史；菜单栏保留运行状态与快速入口。

## 构建

要求 Apple Silicon、Xcode Command Line Tools 和 Bun：

```bash
./macos/build-app.sh
open "macos/build/Agent-Channels-0.3.0-beta.2-arm64.dmg"
```

构建脚本默认使用 `xcrun --sdk macosx` 返回的 SDK。需要指定 SDK 时，可传绝对路径或
`xcrun` 可识别的 SDK 名称；`AGENT_CHANNELS_SDK` 优先于 `SDKROOT`：

```bash
SDKROOT="$(xcrun --sdk macosx --show-sdk-path)" ./macos/build-app.sh
AGENT_CHANNELS_SDK=/path/to/MacOSX.sdk ./macos/build-app.sh
```

把 `Agent Channels.app` 拖入 Applications 后启动。不要直接从 DMG 运行，否则卸载 DMG 后
固定 MCP 路径会失效；App 也会阻止从非 Applications 路径启用 AI 发送和登录启动。

当前包未公证。传到另一台 Mac 后若 Gatekeeper 拦截，请先核对交付方提供的 SHA-256，
再由用户本人在 Finder 中右键 App 选择“打开”并确认；不要关闭 Gatekeeper 或执行全局绕过命令。

## 0.3 双机验收

0.3 使用全新的本地数据模型，不导入 0.2 的 `binding.json` 或共享频道凭证。验收时请在两台
Mac 上新建频道、成员和 task 绑定，不复用 0.2 配置。

1. A 在主窗口创建两个频道并分别复制 `ac2:` 邀请；B 用自己的 Agent 名称接受邀请，频道名
   由邀请自动配置。
2. 两端各添加至少两个已在 ChatGPT Desktop 打开过的 `codex://threads/...` task，并创建
   task-channel Subscription；至少覆盖“一个 task 订阅两个频道”和“一个频道订阅两个 task”。
3. 为每条 Subscription 设置模板、自消息策略和是否作为该 task 的默认发送目标，然后启用监听。
4. 首次启用 AI 发送后完全退出并重启 ChatGPT；该步骤只需首次执行。
5. 完成 App → App、App → task、task → App 和 task → task 收发；task 调用
   `send_to_channel(message)` 时必须按来源 task 的默认 Subscription 路由，不能使用当前选中的
   频道或最近活跃 task 兜底。
6. 重启 App，确认两个频道的本地历史、未读位置和 Subscription 独立恢复；一个 Subscription
   失败或等待人工确认时，其他 Subscription 仍继续运行。
7. owner 移除并封禁一个在线成员，确认其旧凭证和现有连接立即失效，其他成员与频道不受影响。

空闲频道不会触发 AI。若投递回执丢失，仅对应 Subscription 暂停并要求在目标 task 核对后
选择“重试”或“跳过”，其他 Subscription 继续运行。移除 0.3 本机配置时，不应读取、覆盖或
删除任何 0.2 `binding.json` 或旧凭证。

“检查正式版更新…”和“检查 Beta 更新…”分别读取 GitHub Release。检查只在用户点击时发生；App
只提示并打开对应 DMG 或 Release 页面，不静默下载或自我替换。

App 图标使用 E3 品牌稿；菜单栏使用同一识别特征的单色 SVG，并由 macOS 作为模板图标渲染。

本地构建产物采用 ad-hoc 签名，尚未 Developer ID 签名或公证。只有自动化、双机真实 Host
与安全检查全部通过后，才发布 `v0.3.0-beta.2` GitHub prerelease。

## 本机数据

- 0.3 多频道、task 与 Subscription 状态：
  `~/Library/Application Support/Agent Channels/state-v2.json`
- 各频道本地消息历史：同目录 `messages/*.jsonl`
- 各成员独立凭证：macOS Keychain；本地状态文件只保存凭证引用
- MCP 本机发送入口：同目录 `send.sock`（目录 `0700`、socket `0600`、仅同 UID）；MCP
  只提交消息与来源 task 上下文，由 App 选择已配置的默认 Subscription、读取 Keychain 并访问频道服务
- AI 发送配置：用户确认后，只维护 `~/.codex/config.toml` 中
  `Agent Channels managed MCP` 标记区块

App 不安装 Codex CLI、不启动 standalone daemon，也不会设置或清除
`CODEX_APP_SERVER_USE_LOCAL_DAEMON`。
