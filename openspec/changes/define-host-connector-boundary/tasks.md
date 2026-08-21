# Tasks

## 方案设计

- [x] 定义 Subscription Runtime 与 Host Connector 的职责边界
- [x] 定义本地 Host Binding、标准入站信封和接受回执
- [x] 明确能力分级、投递语义、恢复与信任边界
- [x] 将 Codex 定位为首个实现而非产品协议

## 实施与验收

- [x] 在不改变 CLI 行为的前提下隔离 `listen-here` 的通用投递边界
- [x] 让现有 Codex 路径通过该边界投递并保持协议测试通过
- [x] 增加 Host 不支持、Host 不可用和串行投递的最小测试
- [x] 将 Codex 默认投递替换为 Desktop IPC owner discovery + targeted start-turn
- [x] 移除默认 daemon 与 `CODEX_APP_SERVER_USE_LOCAL_DAEMON` 依赖
- [x] 覆盖 IPC 拆帧、client discovery 拒绝、busy steer、接受回执与不确定结果停机测试
- [x] 在真实 ChatGPT Desktop 上验证切换 task 后仍可投递且空闲零 turn
- [x] 完成两台独立设备的公网双向 Host 入站验收
- [ ] 完成两个独立用户且目标 AI 通过 MCP/REST 回复频道的完整闭环

只有决定实现第二个 Host 时，才评估通用配置格式或 Connector registry。
