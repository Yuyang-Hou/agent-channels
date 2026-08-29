# Design

## One Product Object

```text
Channel
  Membership[]
  Message[]
  local instructions + memory
  local read-only history grants
  one owner-managed Codex task
```

成员人数不产生新的类型。频道名称始终使用 `channel_name`。邀请只把成员加入当前频道。

## Local Runtime

owner 创建频道后，macOS App 在 `~/Pijoo/accounts/<account>/channels/<channel>/` 写入固定安全规则、
用户可编辑频道指令和 `MEMORY.md`，并自动创建一个 Codex task。task id、工作目录与安全权限只保存在
本机 Channel 配置中。加入他人频道不会在本机再创建第二个运行 task。

已有 Codex task 只能加入当前频道的只读历史 allowlist。历史查询从发起查询的受管 task 反查 Channel，
不得读取其他 Channel 的 allowlist。

## Authenticated Message Author

消息服务在 endpoint join 时确定 `author_kind`：

- 普通 App、Web 和成员 endpoint 为 `human`；
- 只有频道 owner 的受管 endpoint 可声明 `channel_ai`；
- Message 从认证 endpoint 继承来源，发送正文不能覆盖它。

监听器先记录所有内容消息，再过滤 `channel_ai`，因此 AI 回复会进入 App/Web 历史，但不会重新生成
Codex turn。所有 `human` 消息（包括 owner 从另一 App/Web endpoint 发送）都按相同路径进入模型。

## Presentation

App/Web 始终显示服务器频道名。消息分组键包含 `author_kind`；AI 使用独立图标和“AI”标签，不作为
Membership，也不计入成员数。相邻的人类消息和 AI 消息永不合并。

## Failure Boundary

Channel 创建成功但 task 暂时不可用时保留 Channel，显示 AI 未连接并允许重试恢复；不回退为绑定用户
已有 task。消息投递和发送结果未知仍沿用现有账本规则，不自动重试。
