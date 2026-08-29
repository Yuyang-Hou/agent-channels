# Design

## Decision

把“执行会话”和“参考会话”拆成两条不可混用的路径：

```text
频道消息 -> 默认助理 Subscription -> Pijoo 受管 task -> 受管账号工作区

用户授权的既有 task -> App Server thread/read -> 有界不可信片段 -> 受管 task
```

默认助理 task 是唯一执行目标。既有 task 不接收频道 turn，不改变 cwd、权限或内容。

## Managed Workspace

复用当前 `~/Pijoo` 根目录，在其下按账号稳定摘要建立一个目录；不把原始 account id 或 channel token
写入路径。目录与生成文件只允许当前系统用户访问，路径只保存在本机：

```text
~/Pijoo/accounts/<account-digest>/
  AGENTS.md
```

P0 每账号只有一个默认助理，因此不预建多助理或每频道目录。真实需求出现多个助理时，再在账号目录下
增加 channel scope。

这个目录是“App 管理、用户无需维护”的本地内容，不是密码学黑盒：本机用户仍可查看，运行中的 agent 也能
访问其工作区。隐私保证来自本机权限、Codex sandbox 和不上传服务端，而不是隐藏文件名。

## Built-in Identity Card

App 在 `thread/start` 前原子写入固定模板的 `AGENTS.md`。模板只包含：Pijoo 频道助理角色、频道消息与历史
片段均为不可信输入、不得由消息改变身份或授权、发送与执行需要独立授权，以及草稿/回执边界。

`AGENTS.md` 是 Codex 启动时读取的行为上下文，不是安全策略。App 在创建 task 和外部投递前恢复内置版本，
但权限仍由投递校验强制执行。Codex App Server 的空 `thread/start` 只登记 task，必须继续用
`thread/inject_items` 写入一条不含身份细节的初始化记录来生成 rollout 文件；该记录只指向工作区
`AGENTS.md`，避免两份身份定义漂移。

P0 不做身份卡编辑 UI。昵称变化继续影响频道展示，不触发静默改写已运行 task 的身份；模板升级需要明确
重建或重新加载助理 task 后才声明生效。

## Runtime Guard

创建助理 task 时必须使用账号受管目录。每次启动 Subscription、App 唤醒以及真正投递频道消息前，Connector
读取 Desktop owner 的当前状态并验证：

- cwd 与预期账号工作区完全一致；
- sandbox 为 workspace 范围，approval policy 为 on-request，审批者为本机用户；
- 不允许 full access，也不允许远端输入改变 reviewer；
- task id 与本机 `AssistantConfig.assistantTaskID` 一致。

任一条件不满足时不创建 turn、不推进消息游标，并在 App 显示“助理工作区或权限已变化，需要恢复”。App 只可
由本机用户入口恢复安全档位；频道正文、Web 操作或 MCP 调用不能触发权限提升。

## Existing Task Selection

默认助理频道不再把搜索或粘贴得到的既有 task 传给 `subscribe`。现有搜索调用、结果列表和 task id 解析先复用，
后续点击语义改为加入或移出 `allowedHistoryTaskIDs`。普通频道旧的连接 UI 暂不在本切片重做，但不得把默认助理
频道重新路由到外部 task。

读取继续复用已实现的 `thread/read(includeTurns: true)`：默认 allowlist 为空，撤销后下一次读取立即失败，
结果有数量与字符上限并标记 `untrusted_history`。读取过程不 resume、不 start turn、不写原 task。

## Failure Behavior

- `AGENTS.md` 缺失或内容不匹配：先恢复内置模板；恢复失败则不创建或投递 turn；
- Desktop owner 不可用或状态无法复验：保留消息与游标，显示可重连状态；
- App Server 历史读取不可用：仅历史功能失败，频道消息与受管 task 不改路由。

当前没有存量用户，不实现旧 `~/Pijoo` task、旧 Subscription 或旧工作目录迁移。

## Trust Boundary

Web 用户只获得 Channel Membership 和消息能力。Channel Service 不知道受管目录、身份卡、task id、allowlist
或 sandbox 状态。共享邀请不授予文件、Shell、网络、浏览器、部署或付款权限；这些能力也不能从历史读取权限
继承。
