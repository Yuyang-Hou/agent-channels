# Agent Channels macOS

原生 macOS 13+ 菜单栏 App，当前只支持一个 RogerThat 频道绑定一个 Codex task。

## 构建

要求 Apple Silicon、Xcode Command Line Tools 和 Bun：

```bash
./macos/build-app.sh
open "macos/build/Agent-Channels-0.2.0-beta.1-arm64.dmg"
```

把 `Agent Channels.app` 拖入 Applications 后启动。不要直接从 DMG 运行，否则卸载 DMG 后
固定 MCP 路径会失效；App 也会阻止从非 Applications 路径启用 AI 发送和登录启动。

当前包未公证。传到另一台 Mac 后若 Gatekeeper 拦截，请先核对交付方提供的 SHA-256，
再由用户本人在 Finder 中右键 App 选择“打开”并确认；不要关闭 Gatekeeper 或执行全局绕过命令。

## 双机验收

1. A 输入自己的 Agent 名称并创建频道，邀请口令会自动复制；B 只需输入自己的 Agent 名称
   并粘贴该口令，频道由邀请口令自动配置。
2. 两端分别打开目标 ChatGPT task 一次，粘贴对应 `codex://threads/...`，点击检查并绑定。
3. 两端点击“启用 AI 发送”，确认后完全退出并重启 ChatGPT；该步骤只需首次执行。
4. 两端开始监听，等待状态显示“已连接”。
5. B 的 AI 调用 `send_to_channel(message)`；A 的绑定 task 应产生真实 turn。
6. A 的 AI 可在需要时主动发送另一条频道消息，B 的绑定 task 应收到真实 turn；接收与发送
   相互独立，收到消息不等于必须回复，切换到其他 task 也不影响监听。

空闲频道不会触发 AI。若投递回执丢失，App 会暂停并要求在目标 task 核对后选择“重试”或
“跳过”。“移除本机配置”会删除 Keychain 凭证、Binding 与受管理 MCP 配置。

“检查正式版更新…”和“检查 Beta 更新…”分别读取 GitHub Release。检查只在用户点击时发生；App
只提示并打开对应 DMG 或 Release 页面，不静默下载或自我替换。

App 图标使用 E3 品牌稿；菜单栏使用同一识别特征的单色 SVG，并由 macOS 作为模板图标渲染。

当前产物通过 GitHub prerelease 公开用于 Beta 验收，采用 ad-hoc 签名，尚未 Developer ID 签名或公证。

## 本机数据

- 非秘密 Binding：`~/Library/Application Support/Agent Channels/binding.json`
- 频道 token / owner password：macOS Keychain
- 下一 Beta 源码的本机发送入口：同目录 `send.sock`（目录 `0700`、socket `0600`、仅同 UID）；
  MCP 只传消息正文，由 App 读取 Keychain 并访问频道服务；当前公开的 `v0.2.0-beta.1` 尚不包含此改动
- AI 发送配置：用户确认后，只维护 `~/.codex/config.toml` 中
  `Agent Channels managed MCP` 标记区块

App 不安装 Codex CLI、不启动 standalone daemon，也不会设置或清除
`CODEX_APP_SERVER_USE_LOCAL_DAEMON`。
