# Tasks

## 1. Product Contract

- [x] 将 PRODUCT、Architecture、Roadmap、Status 和 OpenSpec 统一为个人上下文助理
- [x] 明确所有对话复用 Channel、历史默认无权、外发默认草稿

## 2. First Runnable Slice

- [x] 增加独立本机 `AssistantConfig`，不迁移 `AppStateV2`
- [x] 增加 Codex App Server 只读历史命令，只允许读取配置 allowlist
- [x] 覆盖允许、拒绝、撤销和有界输出的最小自动化检查

## 3. Owner Experience

- [x] 登录后自动创建昵称命名的默认助理频道，并在连接会话时只保留一个 Subscription
- [x] 自动创建 `~/Pijoo`，作为新建专属会话的默认工作目录
- [x] 双人频道显示为“好友”和对方昵称
- [ ] 在 UI 中授权、查看来源和撤销历史 task
- [ ] 生成、纠正和删除带来源的画像草稿

## 4. Friend Conversation

- [x] 复用现有 Channel；默认助理显示用户昵称，双人频道显示为“好友”
- [x] 复用现有一次性邀请连接一个联系人
- [ ] 外部消息进入助理 task，回复只生成草稿，明确确认后发送

## 5. Acceptance

- [x] 严格 OpenSpec、单元测试和 typecheck 通过
- [ ] 真实 Codex task 验证未授权不可读、授权可读、撤销立即生效
- [ ] 真实联系人验证不串 task、未经确认不发送、未知回执不重试
