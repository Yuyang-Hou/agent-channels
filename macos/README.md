# Agent Channels macOS

原生 macOS 13+ App。0.3 Beta 使用主窗口管理多个 RogerThat 频道、Codex task、
task-channel Subscription 和本地消息历史；菜单栏保留运行状态与快速入口。

## 构建

要求 Apple Silicon、Xcode Command Line Tools 和 Bun：

```bash
./macos/build-app.sh
open "macos/build/Agent-Channels-0.3.0-beta.8-arm64.dmg"
```

构建脚本默认使用 `xcrun --sdk macosx` 返回的 SDK。需要指定 SDK 时，可传绝对路径或
`xcrun` 可识别的 SDK 名称；`AGENT_CHANNELS_SDK` 优先于 `SDKROOT`：

```bash
SDKROOT="$(xcrun --sdk macosx --show-sdk-path)" ./macos/build-app.sh
AGENT_CHANNELS_SDK=/path/to/MacOSX.sdk ./macos/build-app.sh
```

构建机安装固定 `Agent Channels Beta Signing` 身份时脚本会精确使用该证书；验收分发构建使用
`AGENT_CHANNELS_REQUIRE_SIGNING=1 ./macos/build-app.sh`，身份缺失时直接失败。普通源码构建在
身份缺失时回退 ad-hoc，也可用 `AGENT_CHANNELS_SIGN_IDENTITY=-` 显式选择 ad-hoc。脚本不会
自动选用钥匙串中的 Developer ID。

把 `Agent Channels.app` 拖入 Applications 后启动。不要直接从 DMG 运行，否则卸载 DMG 后
固定 MCP 与 Skill 路径会失效；App 也会阻止从非 Applications 路径启用 Codex 集成和登录启动。

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
4. 在设置中点击“启用或修复 Codex 集成”，然后完全退出并重启 ChatGPT；该步骤会同时安装
   MCP 与产品级 Skill。
5. 完成 App → App、App → task、task → App 和 task → task 收发；task 调用
   `send_to_channel(message)` 时必须按来源 task 的默认 Subscription 路由，不能使用当前选中的
   频道或最近活跃 task 兜底。
6. 确认入站 turn 只显示固定标题、来源栏和 Markdown 正文；修改正文模板后，标题与来源栏仍由
   产品固定，Skill 继续把远端正文作为不可信协作数据处理。
7. 重启 App，确认两个频道的本地历史、未读位置和 Subscription 独立恢复；一个 Subscription
   失败或等待人工确认时，其他 Subscription 仍继续运行。
8. owner 移除并封禁一个在线成员，确认其旧凭证和现有连接立即失效，其他成员与频道不受影响。

空闲频道不会触发 AI。若投递回执丢失，仅对应 Subscription 暂停并要求在目标 task 核对后
选择“重试”或“跳过”，其他 Subscription 继续运行。移除 0.3 本机配置时，不应读取、覆盖或
删除任何 0.2 `binding.json` 或旧凭证。

“检查并下载 Beta 更新…”读取 GitHub prerelease；设置中开启自动更新后，App 启动时及每
24 小时检查并后台下载 arm64 DMG。下载完成后，用户下次启动 App 时，包内原生助手会校验
Bundle ID、版本、完整代码签名和当前 App 的 designated requirement，通过后替换 App 并自动
重新打开；失败时保留旧 App 并展示错误。

App 图标使用 E3 品牌稿；菜单栏使用同一识别特征的单色 SVG，并由 macOS 作为模板图标渲染。

`v0.3.0-beta.2` 已作为公开 GitHub prerelease 发布；`0.3.0-beta.8` 当前只有本地验收包。预上线
分发只使用 Beta 标签；当前产物采用固定内测签名，尚未 Developer ID 签名或公证。首次从旧
ad-hoc 包升级时可能需要授权一次钥匙串访问；同一固定身份的后续 Beta 不应重复询问。双机真实
Host 与安全检查通过前，不发布稳定版，也不声明生产就绪。

## 本机数据

- 0.3 多频道、task 与 Subscription 状态：
  `~/Library/Application Support/Agent Channels/state-v2.json`
- 各频道本地消息历史：同目录 `messages/*.jsonl`
- 各成员独立凭证：macOS Keychain；本地状态文件只保存凭证引用
- MCP 本机 App 操作入口：同目录 `send.sock`（目录 `0700`、socket `0600`、仅同 UID）；MCP
  只提交各工具参数与来源 task 上下文，凭证、网络请求、监听和历史都留在 App
- AI 发送配置：用户确认后，只维护 `~/.codex/config.toml` 中
  `Agent Channels managed MCP` 标记区块
- 产品 Skill：App Bundle 内静态资源；用户确认后维护
  `~/.codex/skills/agent-channels` 到已安装 App 的受管理链接

App 不安装 Codex CLI、不启动 standalone daemon，也不会设置或清除
`CODEX_APP_SERVER_USE_LOCAL_DAEMON`。
