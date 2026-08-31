# Pijoo Development Status

## 当前阶段

产品正在收敛为唯一 Channel 模型。本 change 删除默认助理、好友、联系人和可选执行会话，并统一
human/Channel AI 消息作者语义。

## 当前能力

| 能力 | 状态 |
|---|---|
| Account、Membership、Invite | 已复用为唯一成员模型 |
| Channel Service、SSE、短期恢复 | 已实现 |
| `human|channel_ai` 作者绑定 | 源码已实现，待真实验收 |
| 每成员/Channel 独立 Codex task/cwd | 源码已实现，待真实多成员 task 验收 |
| Channel 指令、记忆和历史 allowlist | 源码已实现，待真实撤权验收 |
| App/Web 人与多个成员 AI 独立展示 | 源码已实现，待真实 UI 验收 |
| Web 登录、邀请、恢复和收发 | 已实现，待部署环境真实账号验收 |

## 尚未完成

- 真实账号下创建多个 Channel，验证 task、cwd、记忆和历史不串线；
- 验证两个成员分别连接 AI 后，同一 human 消息进入两端模型，AI 回复都不回流；
- 验证 App/Web 显示“成员名的 AI”，不同 AI 相邻回复不会合并；
- 部署环境 GitHub OAuth、邀请与多频道切换验收；
- E2EE 与细粒度目录/网络/脚本授权。

## 证据口径

自动化、源码检查、部署成功和真实业务验收是不同证据。只有真实设备完成上述链路，才代表产品状态
达成，而不是仅代表 diff 已合入。
