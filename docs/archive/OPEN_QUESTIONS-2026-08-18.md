# Open Questions Snapshot — 2026-08-18

该文件是早期产品探索快照，已被 `PRODUCT.md`、`ARCHITECTURE.md` 与当前
`docs/OPEN_QUESTIONS.md` 取代，不作为当前决策入口。

## 1. 连接生命周期

如何定义短暂断线、View 被销毁、Host 退出和设备关机？同一会话重连时如何使用 lease 与 cursor 恢复？

## 2. 是否必须登录

是否允许类似对讲机的邀请码临时加入？如果不登录，如何承担跨设备恢复、频道管理、撤权和滥用治理？

## 3. 用户与会话身份

同一用户能否让多个会话加入同一频道？稳定 `uid`、频道 Membership 和临时 `session_id` 如何分层？

## 4. 服务端职责

频道归属、成员管理、消息排序、分发、短期存储、游标、Presence、撤权和审计的最小边界是什么？

## 5. 未来形态

需求协作频道和兴趣频道是否属于同一产品？Human 与 AI 是否应该使用相同成员模型？

## 6. 历史消息

正文保留多久、保留多少条？是否只做短期恢复而不做永久聊天历史？

## 7. MCP 能力

最小工具集合是否为：列频道、开始监听、停止监听、发送消息、读取未读？`@` 如何映射到 Human、Agent 和具体会话？

## 8. 离线、已读与交付保证

需要区分服务端已接收、会话已投递、用户已看到、AI 已处理和回复已发送。首期要承诺 at-least-once 还是更弱的 best-effort？

## 9. 关闭后的感知与恢复

当时推荐方向：频道持久、会话临时。关闭期间服务端短期保留消息；用户再次启动本地 Bridge 时按游标恢复。

没有独立 App、Runtime 或 Host 官方后台 hook 时，系统无法在 GPT 已关闭或用户关机后即时唤醒用户或 AI。站外邮件、Web Push 和永久在线 Agent 都属于后续独立能力。

## 10. MCP App UI 与身份验证

UI 资源如何加载个性化数据？认证状态、频道权限和 UI iframe 的网络访问边界是什么？目标 Host 对 MCP Apps、`ui/message` 和 Picture-in-Picture 的实际支持范围是什么？

## 当时已通过的 P0 实验

1. ChatGPT Desktop 连接共享本地 App Server daemon；
2. Bridge 连接 RogerThat SSE；
3. 另一频道成员发送真实消息；
4. Bridge 对未打开的绑定会话调用 `thread/resume` + `turn/start`；
5. 目标 AI 收到并回复，turn 在桌面历史中持久化；
6. 无消息时 Bridge 不创建 turn。
