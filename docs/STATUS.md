# Pijoo Development Status

## 当前阶段

当前处于 **Pijoo 0.3 Beta 外部试用**：多频道 App、Host 无关边界和 Codex 公网入站链路已经完成；
`0.3.0-beta.18` 已从 `main` 构建，使用 Developer ID 签名、通过 Apple 公证并作为
[GitHub prerelease](https://github.com/Yuyang-Hou/agent-channels/releases/tag/v0.3.0-beta.18) 发布。

## 已完成

| 能力 | 状态 | 证据边界 |
|---|---|---|
| Railway 单实例 Channel Service | 已完成 | 健康检查、授权、双端收发和 Volume 恢复已验收 |
| 公网频道消息进入 Codex 会话 | 已完成 | 未打开的目标会话产生真实 turn |
| 零空闲 turn | 已完成 | 无消息窗口内目标会话没有新增 turn |
| 凭证隔离 | 已完成 | 频道 token 和 session credential 未进入注入正文 |
| 原生来源提示实验 | 已结束 | 能显示来源，但需要额外代理任务，产品不采用 |
| Host 无关架构设计 | 已完成 | 产品、架构和 OpenSpec 已定义 Connector 边界 |
| Host-neutral 投递边界 | 已完成 | 标准信封、串行投递与 Codex Connector 已实现，94 项测试通过 |
| Host 会话发现 | 本地 Beta 包已完成，待实机 | 输入非空关键词后可按 Codex 标题/id 搜索用户主会话，结果浮层点选或直接输入 id；标题不落盘，绑定仍需 preflight |
| CLI 失败状态 | 已完成 | 未支持 Host 参数、Host 不可用和错误凭证均明确失败 |
| Codex Desktop IPC | 已完成 | 无 daemon/env，空闲 start 与忙时 steer 已实机通过；不确定回执停机有自动化覆盖 |
| 两设备公网双向入站 | 已完成 | A、B 两台 Mac 均完成频道消息 → Desktop IPC → 目标 task 真实 turn；正文按不可信输入处理 |
| Apple Silicon 菜单栏包 | Beta 18 已发布 | Developer ID 签名、公证、staple、DMG 与挂载后 App Gatekeeper 均通过；待测试者实机产品验收 |
| 安全本机配置 | 已完成 | token/owner password 进入 Keychain；监听 secret 走 stdin；MCP 配置需用户确认 |
| 只读 task 预检 | 已完成 | 打包版对当前真实 task owner discovery 通过且不创建 turn |
| Task 频道工具 | 本地代码已完成，待打包实机 | 七个 task-scoped 工具通过 `_meta.threadId` 精确路由；来源查询只读本地最近投递记录，MCP 不持有接收链路 |
| Pijoo Skill | 源码已完成，待新包实机 | 面向完整产品语义、入站信任边界和七项频道动作；仅在用户主动追问时查询来源，不使用每 turn hook |
| Markdown 外部消息卡片 | 本地 Beta 包已完成，待实机 | 默认为当前卡片；标题、来源栏、正文和引用样式均可编辑 |
| Markdown 发送成功卡片 | beta.15 真实会话已验收 | 每 Subscription 可编辑；可靠回执按模板展示，不改写频道正文或制造自回声 turn |
| MCP 更新重启提示 | beta.16 本地包已完成，待实机 | 设置页持续显示已加载版本，MCP 上报当前版本后自动清除；不占用菜单栏健康状态 |
| App 内发送凭证边界 | 本地 Beta 包已完成，待实机 | 发送工具只传正文与来源 task 到同 UID Unix socket；App 独占 Keychain 与频道 REST |
| 断线恢复状态 | 本地 Beta 包已完成，待实机 | SSE 自动重连后清除已恢复的连接错误，不再依赖“发送测试招呼”刷新图标 |
| 终态重放幂等 | 本地 Beta 包已完成，待实机 | 已投递、已过滤或已跳过的消息重放时只推进游标，不再次调用 Host；异常断流保留最新游标 |
| 单窗口交互 | 本地 Beta 包已完成，待实机 | 设置并入主窗口侧栏；菜单栏只保留状态、打开、暂停/恢复与退出；打开会置前聚焦主窗口 |
| 邀请加入 | 已完成 | 邀请口令自带频道，加入者直接粘贴；统一使用设置中的“我的昵称” |
| 品牌资源 | 已完成 | App 使用 E3 图标和单色 SVG 菜单栏图标 |
| 手动更新检查 | 已完成 | 正式版与 Beta 分开检查 GitHub Release，不静默下载或替换 App |

## 正在推进

| 工作 | 完成条件 |
|---|---|
| 0.3 Beta 真实 Host 闭环 | 两台 Mac 安装新包，验证 Skill、Markdown 卡片、七项工具与多 Subscription 不串台 |
| 可追溯消息来源 | 本地账本与 `inspect_message_source` 自动化已通过；默认不改变消息正文，仅在用户主动追问时查询当前 task 最近一条成功投递；待新 App 构建及实机验收 |

## 尚未开始

- 静默自更新和 Intel Mac；
- 正式 Human 账户、跨设备 Membership、邀请和撤权体验；
- 离线未读摘要和恢复选择 UI；
- 跨进程原子 claim 与并发孤儿 sidecar 下的严格 exactly-once；
- Codex 之外的 Host Connector；
- 多副本 Channel Service 和共享运行态存储。

## 当前技术债务

- Codex Desktop IPC 属于私有版本化协议，需要版本探测和升级后的兼容性提示；
- `CODEX_APP_SERVER_USE_LOCAL_DAEMON=1` 会让 Desktop IPC 无 owner，且旧 daemon task
  不能假定可迁移到内嵌 runtime；切换后应明确提示新建或重新绑定 task；
- 回执丢失的极小窗口仍需用户在目标 task 核对后手动选择跳过或重试；
- 从旧 ad-hoc Beta 首次升级到固定签名时仍可能请求一次 Keychain 授权；固定身份不变的后续 Beta 不应重复请求；
- 已被替代的 MCP App View 代码仍保留在服务端，但不属于当前产品路线。

## 完成度口径

- 自动化测试通过只代表代码检查通过；
- Railway 健康只代表服务可访问；
- Host 接受 start-turn 只代表投递成功；
- 只有真实用户、真实设备、真实 Host 的双向主动发送与接收闭环才代表 P0 产品完成。
- `v0.2.0-beta.1` 的 MCP 直接读 Keychain 和重连警告问题已在本地 Beta 分支修复；仍待新包实机验收。
