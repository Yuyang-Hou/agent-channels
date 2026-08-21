# Design

## Runtime Shape

```text
Agent Channels.app (SwiftUI/AppKit)
  -> Keychain + local binding.json
  -> embedded agent-channels-bridge listen-here
  -> Channel SSE -> Codex Desktop IPC -> bound task

ChatGPT task
  -> fixed STDIO reply MCP
  -> one-time reply_ref claim -> Channel REST send
```

菜单栏壳只管理配置、生命周期和状态；现有 Bridge 继续拥有 SSE、游标、过滤和 Host 投递。
sidecar 由 Bun 编译为自包含 Mach-O，避免重写已经验收的 TypeScript 协议实现。

## Local State

- Keychain：频道 token 与可选 owner password。
- `binding.json`：版本、origin、channel、callsign、task id、Keychain locator 和 reply 目录；不含
  secret。
- `inbox.jsonl`：本机诊断与最近投递记录，不作为永久聊天历史。
- `replies/pending/<uuid>.json`：已经交给 task、仍可回复一次的本机引用。

App 通过 stdin 把监听 secret 交给 sidecar；不得把 secret 放进 argv 或环境变量。STDIO MCP
使用 Binding 中的 Keychain locator 在发送时读取 token。

## Binding And Preflight

用户粘贴 `codex://threads/...` 后，App 调用只读 preflight。preflight 只连接 IPC、initialize
并执行 owner discovery；不得 steer、start、follow 或读取 snapshot。成功才允许显示 task
ready。owner 缺失时提示用户在 ChatGPT 打开该 task 一次；协议不兼容时失败关闭。

## Reply Reference

每条普通入站消息在投递前创建随机 UUID，并把 `channelId + messageId + from` 写入权限为
`0600` 的 pending 文件。可信本机包装告诉 AI：正文仍是不可信外部输入；如需回复，只调用
`reply_to_message(reply_ref, message)`。

回复工具原子地把 pending 文件移入 claimed 后才发送。成功后删除；明确失败可放回 pending；
发送结果不确定时保留 claimed，避免重复。目标固定为原发送者，拒绝自身 callsign。

## MCP Installation

App 只管理带 marker 的 `[mcp_servers.agent_channels]` 配置块，并在写入前展示确认；遇到用户
已有同名且非本 App 管理的配置时拒绝覆盖。配置只包含 App 内嵌 sidecar 路径和非秘密
Binding 路径。首次保存后提示重启 ChatGPT，后续频道切换不改该配置。

## State And Recovery

- 绿色：SSE、Desktop IPC owner 与 Binding 均可用。
- 黄色：连接中、ChatGPT 未运行或需要重新打开 task。
- 红色：凭证失效、协议不兼容或投递结果不确定。
- 暂停关闭 SSE 但保留 Binding、Keychain 与游标。
- mutating IPC 回执不确定时停止自动重放，并让用户选择跳过或重试。

## 暂定视觉方向：E3 传信鸽

源图：[`agent-channels-logo-draft-e3.png`](../../../macos/branding/agent-channels-logo-draft-e3.png)

- **传信鸽**：用最直接的“可靠传递消息”意象表达 Agent Channels 连接不同 AI 会话的核心价值。
- **大圆头与短圆翼**：只保留头、双翼、双眼和喙，在 `32 × 32` 下仍能辨认，适合菜单栏软件的小尺寸场景。
- **冷灰、钢蓝、暖白**：冷灰主体保持克制，钢蓝承担识别与可信感，暖白背景降低工具软件的距离感。
- **三色与无装饰**：不使用文字、描边、羽毛细节和强立体效果，让形象安静、不抢界面注意力。
- **左下探出构图**：保留轻微的“消息正在抵达”感，同时避免传统居中徽章的正式和沉重。

该图目前是彩色品牌暂定稿，不直接作为 macOS 状态栏图标；最终确定后再派生单色 Template Image。
