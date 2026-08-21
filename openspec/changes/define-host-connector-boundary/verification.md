# Verification

## Implemented

- `host-connector.ts` 定义标准入站信封、投递回执和单 Binding 串行器。
- `listen-here` 只负责过滤、信封构造和调用 `HostDelivery`。
- `codex-turn.ts` 当前负责 Codex 目标校验、消息格式与 App Server 协议；本 change 将其默认
  transport 替换为 Desktop IPC，同时保持 HostDelivery 契约不变。
- 菜单栏 App 与 Subscription Runtime 负责持续接收；本机 MCP 只暴露
  `send_to_channel(message)`，主动广播与入站消息相互独立。
- 现有 `--codex-thread`、`--codex-source-thread` 和 `--codex-socket` CLI 行为保留。
- 不声称已经支持非 Codex Host。

## Automated — 2026-08-21

- `npm test`: 10 files, 72 tests passed。
- `npm run typecheck`: passed。
- `npm run build`: passed。
- 新 Desktop IPC 测试覆盖拆帧/粘帧、client discovery 拒绝、owner discovery、定向
  start-turn、busy steer、嵌套接受回执，以及回执不确定时停止自动重放。
- `listen-here --identity-key` 真实集成测试覆盖自动 join 使用服务端 `callsign` 字段。

## Desktop IPC Feasibility — 2026-08-21

- 未设置 `CODEX_APP_SERVER_USE_LOCAL_DAEMON`，ChatGPT 使用内嵌 stdio App Server。
- 真实 Desktop IPC owner discovery 在用户切换离开绑定 task 后仍找到同一 owner。
- 一次 `thread-follower-start-turn` v2 在 4.4 秒内完成并返回真实 turn id。
- 空闲观察未创建额外 turn，也未出现 `active writer` 冲突。
- start-turn 不依赖 `following`；正式 Connector 不启用 following，避免接收 task snapshot。
- 正式 Connector 直接投递返回 turn `01a0230a-62ee-74d1-b134-1fb0214d0665`，目标任务在
  7.2 秒内精确输出 `DESKTOP_IPC_CONNECTOR_OK`。
- 本地真实 Channel Service → SSE `listen-here` → Desktop IPC 返回 turn
  `01a0230b-cb71-7923-a889-943370eecdb1`，目标任务在 2.8 秒内精确输出
  `LISTEN_HERE_DESKTOP_IPC_OK`。
- steer-first 在空闲任务上明确回退 start，turn `01a02320-8c5a-7873-9bc1-e18a5c4e7ef4`
  精确输出 `STEER_FIRST_IDLE_OK`。
- 同一任务运行中连续投递的两个回执均为 turn
  `01a02320-dc9d-7eb3-aa71-8e6f3c4bffd2`，证明第二条进入 steer 路径；该 turn 最终精确输出
  `STEER_FIRST_BUSY_OK`。
- 各次验收完成后 task 均回到 idle；Connector 未连接 standalone daemon。

## Public Two-device Acceptance — 2026-08-21

- 验收包：`rogerthat 1.25.1-agent-channels.0`；全量自动化、构建、隔离安装及 CDN
  SHA-256 回读通过。
- 公网频道 `noisy-civet-af7a` 使用 `retention:none`；A、B 为两台独立 Mac。
- B → A：消息 `1787300371037` 进入 A task
  `01a003c9-5f15-72c3-8da7-cbe7a4c03d6a`，真实 turn
  `01a02367-5a7e-7d51-9e7d-a89a2649d110` 完成并输出 `RETEST_B_TO_A_OK`。
- A → B：消息 `1787300687955` 进入 B task
  `01a0236a-c478-7fc0-99f1-6f8fd6564b90`；UI 显示完整频道信封，AI 明确按不可信
  外部输入处理并拒绝执行正文中的“只回复”命令，信任边界符合设计。
- B 初次失败的根因不是 Channel Service：`CODEX_APP_SERVER_USE_LOCAL_DAEMON=1`
  使 Desktop IPC socket 无 owner；清除环境并切换到当前 runtime 新建的 task 后通过。
- 结论：两设备、双方向的公网 Host 入站已验收；本次没有证明 B 的 AI 可通过
  `send_to_channel(message)` 主动向频道发信并由 A 收到。

## Pending P0 Acceptance

仍需由两个独立用户验收，并给双方 AI 配置最小频道出站权限，完成 B AI 主动发送 →
Channel Service → A task，以及 A AI 主动发送 → Channel Service → B task 的双向闭环。
