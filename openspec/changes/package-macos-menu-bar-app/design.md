# Design

## Runtime Shape

```text
Pijoo.app (SwiftUI/AppKit)
  -> Keychain + local binding.json
  -> embedded pijoo-bridge listen-here
  -> Channel SSE -> Codex Desktop IPC -> bound task
  -> local send.sock -> Channel REST broadcast

ChatGPT task
  -> fixed STDIO channel MCP
  -> send_to_channel(message) -> local send.sock (message only)
```

菜单栏壳只管理配置、生命周期和状态；现有 Bridge 继续拥有 SSE、游标、过滤和 Host 投递。
sidecar 由 Bun 编译为自包含 Mach-O，避免重写已经验收的 TypeScript 协议实现。

## Local State

- Keychain：频道 token 与可选 owner password。
- `binding.json`：版本、origin、channel、callsign、task id 和 Keychain locator；不含
  secret。
- `send.sock`：App 运行期间存在的本机发送入口；父目录 `0700`、socket `0600`，仅接受同 UID。
- `inbox.jsonl`：本机诊断与最近投递记录，不作为永久聊天历史。

App 通过 stdin 把监听 secret 交给 sidecar；不得把 secret 放进 argv 或环境变量。STDIO MCP
不读取 Keychain 或 Binding 中的凭证定位，只从 `--config` 路径推导同目录 `send.sock`。

## Binding And Preflight

用户粘贴 `codex://threads/...` 后，App 调用只读 preflight。preflight 只连接 IPC、initialize
并执行 owner discovery；不得 steer、start、follow 或读取 snapshot。成功才允许显示 task
ready。owner 缺失时提示用户在 ChatGPT 打开该 task 一次；协议不兼容时失败关闭。

## Outbound Tool

接收与发送是两条独立链路。App 订阅频道并把普通消息投递给绑定 task；入站正文继续标记为
不可信外部输入，但不再创建 `reply_ref`，也不要求 AI 回复。

固定 STDIO MCP 只暴露 `send_to_channel(message)`。MCP 把版本号与正文交给本机 App；App 从
当前 Binding 和 Keychain 取得频道、callsign 与凭证，幂等加入后向 `all` 广播。模型和 MCP
正文都不包含 origin、token、owner password 或 session。明确失败可以重新发送；请求交给 App
后若回执不确定则返回明确的“不确定”结果，并阻止自动重试。该工具无需 App 开启 SSE 监听，
也不依赖之前收到过消息，但菜单栏 App 必须运行。

## MCP Installation

App 只管理带 marker 的 `[mcp_servers.pijoo]` 配置块，并在写入前展示确认；遇到用户
已有同名且非本 App 管理的配置时拒绝覆盖。配置只包含 App 内嵌 sidecar 路径和非秘密
Binding 路径。首次保存后提示重启 ChatGPT，后续频道切换不改该配置。旧 `reply-mcp` 启动参数
仅作为已安装版本的兼容别名保留；无论使用哪个入口，`tools/list` 都只返回
`send_to_channel`。

## Invitation Join

`ac1:` 邀请口令包含 origin、channel、token 和可选 owner password。加入者不填写或修改
channel；UI 单独要求填写的是本机 Agent 名称（服务端 callsign），并在加入后展示实际频道，
避免把 Agent 名称误解成频道名。

## Release Check

App 使用 GitHub Release 公共 API 手动检查更新，不引入 updater 依赖：

- “检查正式版”只使用 latest stable release，忽略 draft 与 prerelease；
- “检查 Beta”单独读取 prerelease 列表，只选择 Beta 标签；
- 使用 Bundle 版本与 Release tag 做 SemVer 比较，等于或低于当前版本时不提示下载；
- 发现更新后由用户选择打开 DMG asset；缺少 DMG 时打开 Release 页面；App 不静默下载、替换
  或重启自身。

## State And Recovery

- 绿色：SSE、Desktop IPC owner 与 Binding 均可用。
- 黄色：连接中、ChatGPT 未运行或需要重新打开 task。
- 红色：凭证失效、协议不兼容或投递结果不确定。
- 暂停关闭 SSE 但保留 Binding、Keychain 与游标。
- mutating IPC 回执不确定时停止自动重放，并让用户选择跳过或重试。
- SSE 临时断开时显示重连状态；重新连接成功必须清除该连接错误，不能保留过期警告。

## 视觉方向：圆身传信鸽

App icon 源图：[`pijoo-app-icon.png`](../../../macos/branding/pijoo-app-icon.png)；README 透明品牌图：[`pijoo-logo.png`](../../../macos/branding/pijoo-logo.png)

- **传信鸽**：用最直接的“可靠传递消息”意象表达 Pijoo 连接不同 AI 会话的核心价值。
- **圆身、小头与短圆喙**：用接近皮球的圆身体承载亲和力；菜单栏只保留外轮廓和单点眼睛，在 `18 × 18` 下仍能辨认。
- **冷灰、钢蓝、暖白**：冷灰主体保持克制，钢蓝承担识别与可信感，暖白背景降低工具软件的距离感。
- **彩色与单色分工**：App icon 保留柔和色彩与轻微层次；菜单栏使用同轮廓的单色 Template Image，由 macOS 自动适配明暗状态。

不透明背景图作为当前 App icon 来源；菜单栏使用从同一轮廓派生的 18×18 单色 SVG Template Image，
保持透明背景并由 macOS 自动适配明暗菜单栏。异常状态仍使用系统警告图标。
