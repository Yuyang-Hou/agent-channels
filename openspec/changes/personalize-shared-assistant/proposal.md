# Proposal: Personalize Shared Assistant

## Why

当前“分享会话”复用普通频道邀请，多个来访者会进入同一个助理频道；固定草稿策略又让助理收到消息后
不会直接回复。用户需要分享的是同一个助理身份，而不是同一个多人聊天上下文。

## What Changes

- 默认助理频道只保留当前账号，不再直接邀请来访者加入；
- 每次分享为一名来访者创建独立双人 Channel、独立受管 Codex task 和独立联系人工作区；
- 用户可以编辑助理身份、语气与介绍，安全边界仍由 App 固定生成；
- 普通文本回复默认自动发送，文件、网络、历史读取和其他高风险动作仍受独立授权约束；
- Host 输入携带经过频道鉴权的稳定 Member id，昵称只用于展示；
- 每个联系人拥有本机资料与 AI 印象，用户可以查看、纠正和删除，印象不得成为权限依据。

## Non-goals

- 不新增平行私信协议，仍复用 Channel、Membership、Invite、TaskBinding 和 Subscription；
- 不同步身份卡、联系人资料、AI 印象、task id 或工作目录到服务端；
- 不允许来访者消息修改身份卡、历史 allowlist、sandbox 或联系人信任级别；
- 不兼容或迁移旧助理频道、旧身份卡和旧联系人资料；当前暂无用户。

## Impact

服务端消息和 Membership 模型保持不变。macOS App 在分享时先创建一个单用途双人频道入口，再为其
创建受管 task；Codex Connector 增加认证 Member id，内置 Skill 与身份卡允许受管助理自动发送普通文本。
