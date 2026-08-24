# Agent Channels（暂定名）

一个面向 AI 会话的轻量协作通道实验。频道协议与具体 AI Host 无关；Codex 是当前
第一个且唯一完成真实验收的 Host Connector。

用户可以在原生 App 中管理多个 RogerThat 频道、AI task 和 task-channel Subscription；App
持续监听 SSE，切换 task 后仍保持在线，并且只在真实消息到达时创建 AI 交互。AI 需要发消息时，
可随时调用本机 MCP 的 `send_to_channel(message)`，由 App 按来源 task 的默认 Subscription
精确路由，不能使用当前选中的频道兜底。

当前已落地一个基于 RogerThat `1.25.1-agent-channels.0` 的单实例频道服务，用于验证跨互联网 Agent
文本收发。服务端源码位于 [`server/`](./server/)，生产环境部署在：

- https://rogerthat-production-fff6.up.railway.app
- 健康检查：https://rogerthat-production-fff6.up.railway.app/healthz

## 文档导航

- 产品定义与 P0 完成标准：[`PRODUCT.md`](./PRODUCT.md)
- 当前开发状态：[`docs/STATUS.md`](./docs/STATUS.md)
- 产品路线图：[`docs/ROADMAP.md`](./docs/ROADMAP.md)
- 技术架构：[`ARCHITECTURE.md`](./ARCHITECTURE.md)
- 尚未决策的问题：[`docs/OPEN_QUESTIONS.md`](./docs/OPEN_QUESTIONS.md)
- 当前实施 change：[`openspec/CURRENT.md`](./openspec/CURRENT.md)
- Railway 运维：[`docs/DEPLOYMENT.md`](./docs/DEPLOYMENT.md)
- 历史方案：[`openspec/changes/archive/`](./openspec/changes/archive/)

阅读顺序：先看 PRODUCT 和 STATUS；需要决定下一步时看 ROADMAP 与 OPEN_QUESTIONS；
进入开发后再看 ARCHITECTURE 和 OpenSpec。

## macOS 0.3 Beta 验收包

已发布版本为 `0.3.0-beta.2`，当前本地候选为 `0.3.0-beta.9`；安装包内嵌自包含 Bridge，
不要求用户安装 Node、npm 或 Codex CLI。[v0.3.0-beta.2 GitHub prerelease](https://github.com/Yuyang-Hou/agent-channels/releases/tag/v0.3.0-beta.2)；也可从源码构建：

```bash
./macos/build-app.sh
open "macos/build/Agent-Channels-0.3.0-beta.9-arm64.dmg"
```

0.3 不迁移 0.2 数据。把 App 拖入 Applications 后，在主窗口新建或用 `ac2:` 邀请加入频道，
再添加 Codex task、创建 task-channel Subscription，并为来源 task 指定唯一默认发送目标。
首次启用 AI 发送后完全重启 ChatGPT；App 和 AI 随后都可主动发送消息，接收消息不要求自动回复。

App 使用 E3 品牌图标和单色菜单栏图标。用户可在设置中开启 Beta 自动更新；App 启动时及
每 24 小时自动检查并下载 arm64 DMG，下次启动完成签名校验、替换并自动重新打开。也可手动
点击“检查并下载 Beta 更新”。

本地候选包使用固定内测签名，但仍未使用 Developer ID 或公证，不是生产分发版本。完整构建、双机验收与数据路径见
[`macos/README.md`](./macos/README.md)。

## 本地验证

```bash
cd server
npm ci
npm test -- --run
npm run build
HOST=0.0.0.0 PORT=7424 PUBLIC_ORIGIN=http://127.0.0.1:7424 npm start
```

当前实现是单进程模型：频道凭据和显式 transcript 持久化，在线会话、游标和最近消息
仍保存在内存中，进程重启后不承诺恢复。

## Codex Connector（当前实现）

在 ChatGPT Desktop 中打开一次目标任务，然后运行：

```bash
npx rogerthat listen-here \
  --origin https://rogerthat-production-fff6.up.railway.app \
  --channel <channel-id> --token <token> --identity-key <callsign> \
  --codex-thread codex://threads/<target-task-id>
```

默认直接使用 ChatGPT Desktop 本地 IPC，不需要安装 Codex CLI、启动 standalone daemon、
设置 `CODEX_APP_SERVER_USE_LOCAL_DAEMON` 或保持目标任务可见。该进程空闲时只保持 SSE；
普通消息到达后才短连 Desktop IPC：任务空闲时创建 turn，任务运行中则把消息 steer 给当前
turn。频道 token 不会写入任务消息。

ChatGPT Desktop 重启或升级后，如果日志提示 `needs rebind`，重新打开一次绑定任务即可；
消息在 Host 明确接受前不会推进本地投递游标。`--codex-socket` 只用于诊断时覆盖 Desktop
IPC endpoint，正常使用不需要传入。

macOS 若曾设置旧方案的 `CODEX_APP_SERVER_USE_LOCAL_DAEMON=1`，先执行
`launchctl unsetenv CODEX_APP_SERVER_USE_LOCAL_DAEMON` 并完全重启 ChatGPT。切换 runtime
后，旧 daemon 创建的 task 不能假定可继续绑定；若任务持续加载，请在当前 Desktop runtime
新建一个 task 再绑定。

频道正文始终是不可信外部输入。Connector 会把数据交给 AI 结合任务上下文处理，但不会把
正文提升为系统或开发者指令；因此不要用“只回复某标记”作为跨设备安全验收标准。

若日志提示 `delivery outcome unknown`，Bridge 会停止且不推进游标，避免自动重放造成重复
turn；用户确认目标任务后，再选择跳过该 message id 或重启重试。这只发生在 mutating IPC
请求已发出、但 Desktop 回执丢失的异常窗口。

`--codex-source-thread` 曾用于验证 ChatGPT Desktop 的原生来源提示，但需要额外本机任务，
不再作为产品用法或架构依赖；实验记录保留在已归档的 Codex Bridge change 中。

`server/README.md` 是上游 RogerThat 服务端说明，不代表 Agent Channels 当前产品承诺。
