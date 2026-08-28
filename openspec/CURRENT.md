# Pijoo Current Change

当前唯一活动产品 change：

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

当前不建设自动回复、第二个 Host、公开联系人目录、完整聊天客户端、自建模型 Runtime、向量数据库
或通用插件框架。
