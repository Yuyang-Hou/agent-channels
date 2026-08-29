# Pijoo

## 产品定义

Pijoo 只有一种产品对象：`Channel`。用户主动创建 Channel、邀请成员，并在同一消息流中与真人和
Channel AI 交流。人数、邀请状态和成员关系不会产生“助理频道”“好友频道”“群聊”或“联系人”等
额外类型。

每个由本机所有者创建的 Channel 都有独立的 AI 运行空间。底层 Codex task 只是 App 管理的运行句柄，
不是用户需要选择、绑定或理解的产品对象；其他 Codex task 只能按 Channel 授权为只读历史来源。

## 首版体验

```text
登录 -> 主动创建 Channel -> App 建立该 Channel 的隔离 AI 运行空间
  -> 在 App/Web 发送 human 消息 -> 同一条链路进入 Channel AI
  -> Channel AI 回复 -> App/Web 以独立 AI 身份展示，不再次进入模型
  -> 邀请成员加入当前 Channel -> 所有 human 消息继续走相同处理链路
  -> 所有者可编辑 Channel 指令和记忆，并授权只读 Codex 历史
```

## P0 范围

- Channel、Membership、Invite 和消息是唯一协作模型；
- 用户主动创建 Channel，不自动创建默认频道；
- 每个所有者 Channel 自动建立且只使用一个隔离 Codex task；加入者不会再建立第二个 task；
- 所有 human 消息按同一架构送入模型，包括所有者从 App/Web 发出的消息；
- Channel AI 消息可靠写回 Channel，但不会再次喂给模型；
- App/Web 始终分开显示 human 与 Channel AI，相邻消息不共用头像或分组；
- 指令、`MEMORY.md`、工作区、只读历史 allowlist 都按 Channel ID 隔离；
- 邀请只向当前 Channel 添加成员，不创建新 Channel；
- Web 支持登录、邀请加入、频道恢复/切换、最近消息与纯文本收发；
- 复用现有账号、SSE、游标、本地账本、回执和 Host Connector。

## P0 不包含

- 联系人关系、成员身份、备注、AI 印象或按人数派生的界面；
- 用户选择执行 task，或把既有 Codex task 绑定为 Channel AI；
- 文件目录、域名、脚本和联网能力的细粒度授权。Codex 未提供稳定可验证的强制接口前不伪造权限 UI；
- 自动读取全部历史、修改被授权 task，或上传完整 task/工作目录；
- 永久云端聊天历史、文件上传、第二个 Host、公开目录或独立 Web 服务；
- 宣称端到端加密。当前服务端可见消息明文。

## 安全原则

1. **Channel 隔离**：AI task、cwd、指令、记忆和历史 allowlist 都以 Channel ID 为边界。
2. **默认无历史权**：只读历史逐项授权并可撤销，不启动、恢复或修改来源 task。
3. **作者可信**：服务端从认证 endpoint 写入 `human|channel_ai`，客户端不能伪造消息作者。
4. **不回流**：`channel_ai` 消息进入时间线但不再次投递给模型。
5. **能力分离**：普通文字处理不等于文件、Shell、浏览器、网络或部署权限。
6. **可靠回执**：结果未知时不自动重试，也不声称已经发送。

## P0 完成标准

1. 新账号没有默认 Channel；用户创建后可直接在 App 中与 Channel AI 双向交流；
2. 所有者与其他成员的 human 消息以相同格式进入同一个 Channel AI；
3. AI 回复只显示一次，且 App/Web 与 human 消息有明确独立身份；
4. 邀请成员不会创建额外 Channel 或 AI task；
5. 每个 Channel 的指令、记忆、工作区和历史授权不串线；
6. 未授权历史不可读，撤销后立即不可读；
7. App 重启和短暂断线不静默丢消息、不重复发送未知结果；
8. Web 可完成登录、加入、切换和双向收发；退出或移除后必须重新获邀；
9. 自动化通过后，完成真实账号、真实 Codex 和真实邀请的端到端验收。
