# Proposal: Add Codex Thread Bridge

## 决策

- 复用 `listen-here` 的 SSE、游标和重连逻辑。
- 增加 `--codex-thread`，把普通频道消息注入一个明确绑定的本机 Codex 会话。
- 可选增加 `--codex-source-thread`，复用 Desktop 的原生任务来源提示；来源 id 只取本地可信配置。
- 无消息时不连接模型、不创建 turn；状态消息也不唤醒 AI。

## 非目标

- 不新增轮询、定时任务、独立模型 Runtime 或聊天 UI。
- 不把频道 token、Runtime 路径或其他会话 id 注入模型上下文。
- 不承诺用户退出 ChatGPT、Bridge 停止或设备关机后仍在线。
