# Proposal: Unify Channel Product Model

## Why

“默认助理、好友助理、好友频道、联系人记忆和助理会话”把同一个 Channel 拆成了多套产品概念。
同一账号的人类消息和频道 AI 回复又共享 Member 身份，导致模型路由与 App/Web 展示无法可靠区分。

## What Changes

- 产品只保留 Channel，不根据成员人数改变频道类型、标题或界面；
- 用户主动创建 Channel，App 不再自动创建默认助理频道；
- owner 创建 Channel 时自动建立一对一的隔离 Codex task，task 只作为内部运行载体；
- 频道指令、记忆和只读历史授权按 Channel 隔离；
- 删除联系人关系、备注、AI 印象及“分享助理”流程，邀请只表示向当前 Channel 添加成员；
- 服务端为消息写入可信的 `human` 或 `channel_ai` 来源；所有人类消息进入模型，频道 AI 消息只进入频道历史和客户端；
- App/Web 使用消息来源区分人类和 AI，不把相邻消息合并到同一头像或气泡组。

## Non-goals

- 不新增私信、好友或群聊数据模型；
- 不允许用户选择已有 Codex task 作为频道执行 task；已有 task 只可作为只读上下文；
- 本 change 不实现尚未有稳定 Codex 强制接口的目录、域名或脚本权限规则；这些授权不得用提示词伪装；
- 不迁移旧 AssistantConfig、联系人资料或旧消息；当前暂无用户。

## Impact

服务端 Channel、Membership、Invite 和消息中继继续复用。macOS 删除助理/联系人分支并改为按
Channel 保存本地配置；Web 与 macOS 共同消费消息 `author_kind`。
