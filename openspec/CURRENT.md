# Pijoo Current Change

当前优先产品 change：

1. [`changes/unify-channel-product-model`](./changes/unify-channel-product-model/)：
   产品只保留 Channel；用户主动创建频道，owner 频道自动建立隔离的底层 Codex task。消息按可信的
   `human/channel_ai` 来源路由和展示，频道 AI 回复不再回流模型。

已落地主干、等待真实验收的 change：

1. [`changes/add-web-shared-channel-client`](./changes/add-web-shared-channel-client/)：
   由现有 Pijoo 服务托管 Web 共享入口；被邀请者可登录、幂等加入、恢复并切换频道和收发消息。

已落地主干、等待被当前 change 收敛的 change：

1. [`changes/personalize-shared-assistant`](./changes/personalize-shared-assistant/)：
   既有身份卡、好友助理与联系人记忆实现；当前 change 将删除这些平行概念。

已落地主干、继续作为基础的 change：

1. [`changes/pivot-to-personal-context-assistant`](./changes/pivot-to-personal-context-assistant/)：
   将已验证的账号、消息中继和 Codex Connector 收敛为一个固定的个人上下文助理；首版增加本机
   历史 task allowlist 与只读检索；账号自动拥有昵称命名的默认助理频道，双人频道显示为“好友”，回复固定为
   用户确认后的草稿发送。

其他 `changes/` 目录保留为既有实现与发布历史，不再代表当前产品路线，也不在本 change 中删除。

产品权威按以下顺序读取：

1. [`../PRODUCT.md`](../PRODUCT.md)
2. [`../docs/STATUS.md`](../docs/STATUS.md)
3. [`../docs/ROADMAP.md`](../docs/ROADMAP.md)
4. [`../ARCHITECTURE.md`](../ARCHITECTURE.md)
5. [`../docs/OPEN_QUESTIONS.md`](../docs/OPEN_QUESTIONS.md)

当前不建设独立 Web 后端、Web task 管理、永久云端聊天历史、第二个 Host、公开联系人目录、
自建模型 Runtime、向量数据库或通用插件框架。
