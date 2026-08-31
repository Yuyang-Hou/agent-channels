# Proposal: Add Member Channel AI

## Why

Channel 已允许多人加入，但当前只有 owner 能运行 AI，且所有 AI 消息都显示为“AI”。多人频道无法让各成员
带入自己的 AI，也无法辨认回复归属；AI 页签内容还会因默认居中布局出现大块顶部空白。

## What Changes

- active Membership 均可建立经过认证的 `channel_ai` endpoint；
- 创建者继续自动连接 AI，其他成员可在 App 中主动连接自己的隔离 AI；
- App/Web 显示“成员名的 AI”，macOS 按 member + endpoint 分组；
- 只有当前保持接收流的成员 AI 才作为 `@成员名的 AI` 目标；无人连接 AI 时不展示 AI 目标；
- 每个 Channel AI 可选择回复所有 human 消息，或仅回复 @所有人 / @自己的 AI；
- AI 页签内容固定从顶部开始布局。

## Non-goals

- 不新增 AI、联系人或 Membership 类型；
- 不允许公开 band 声明 `channel_ai`；
- 不允许选择已有 Codex task 作为运行 task；
- 不让 AI 消息回流并触发其他 AI；
- 不把离线、本机配置但未连接的 AI 当成在线可 @ 目标。
