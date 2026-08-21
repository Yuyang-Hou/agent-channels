# Agent Channels macOS

原生 macOS 13+ 菜单栏 App，当前只支持一个 RogerThat 频道绑定一个 Codex task。

## 构建

要求 Apple Silicon、Xcode Command Line Tools 和 Bun：

```bash
./macos/build-app.sh
open "macos/build/Agent-Channels-0.1.0-arm64.dmg"
```

把 `Agent Channels.app` 拖入 Applications 后启动。不要直接从 DMG 运行，否则卸载 DMG 后
固定 MCP 路径会失效；App 也会阻止从非 Applications 路径启用回复和登录启动。

当前包未公证。传到另一台 Mac 后若 Gatekeeper 拦截，请先核对交付方提供的 SHA-256，
再由用户本人在 Finder 中右键 App 选择“打开”并确认；不要关闭 Gatekeeper 或执行全局绕过命令。

## 双机验收

1. A 输入昵称、创建频道，邀请口令会自动复制；B 输入自己的昵称并粘贴该口令。
2. 两端分别打开目标 ChatGPT task 一次，粘贴对应 `codex://threads/...`，点击检查并绑定。
3. 两端点击“启用 AI 回复”，确认后完全退出并重启 ChatGPT；该步骤只需首次执行。
4. 两端开始监听，等待状态显示“已连接”。
5. B 点击“发送测试招呼”；A 的绑定 task 应产生真实 turn，并可用一次性回复工具回复 B。
6. A 回复后，B 的绑定 task 应收到真实 turn；切换到其他 task 不影响监听。

空闲频道不会触发 AI。若投递回执丢失，App 会暂停并要求在目标 task 核对后选择“重试”或
“跳过”。“移除本机配置”会删除 Keychain 凭证、Binding、待回复引用与受管理 MCP 配置。

当前产物仅用于本地验收，采用 ad-hoc 签名，尚未 Developer ID 签名或公证。

## 本机数据

- 非秘密 Binding：`~/Library/Application Support/Agent Channels/binding.json`
- 频道 token / owner password：macOS Keychain
- AI 回复配置：用户确认后，只维护 `~/.codex/config.toml` 中
  `Agent Channels managed MCP` 标记区块

App 不安装 Codex CLI、不启动 standalone daemon，也不会设置或清除
`CODEX_APP_SERVER_USE_LOCAL_DAEMON`。
