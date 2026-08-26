# Tasks

## 方案设计

- [x] 定义 Subscription Runtime 与 Host Connector 的职责边界
- [x] 定义本地 Host Binding、标准入站信封和接受回执
- [x] 明确能力分级、投递语义、恢复与信任边界
- [x] 将 Codex 定位为首个实现而非产品协议
- [x] 将 App 与 Runtime Binding 入口改为 `provider + conversation_id`

## 实施与验收

- [x] 在不改变 CLI 行为的前提下隔离 `listen-here` 的通用投递边界
- [x] 让现有 Codex 路径通过该边界投递并保持协议测试通过
- [x] 增加 Host 不支持、Host 不可用和串行投递的最小测试
- [x] 将 Codex 默认投递替换为 Desktop IPC owner discovery + targeted start-turn
- [x] 移除默认 daemon 与 `CODEX_APP_SERVER_USE_LOCAL_DAEMON` 依赖
- [x] 覆盖 IPC 拆帧、client discovery 拒绝、busy steer、接受回执与不确定结果停机测试
- [x] 在真实 ChatGPT Desktop 上验证切换 task 后仍可投递且空闲零 turn
- [x] 完成两台独立设备的公网双向 Host 入站验收
- [x] 增加 Codex 本机会话标题/id 搜索，标题不落盘，并在点选绑定时复验本机身份
- [x] 将冷会话绑定改为本机索引复验，owner 只用于监听/投递，并展示上次目录
- [x] 冷会话权限显示未知；已加载会话读取当前目录/权限，并允许本机用户显式切换三档权限
- [ ] 完成两个独立用户且双方 AI 通过 `send_to_channel(message)` 主动发信的双向闭环

只有决定实现第二个 Host 时，才评估动态 Connector registry 或 SDK。
