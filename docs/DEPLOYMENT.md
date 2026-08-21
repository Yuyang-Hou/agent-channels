# RogerThat Railway Deployment

## Production

- URL: https://rogerthat-production-fff6.up.railway.app
- Railway project: `agent-fabric-channels`
- Railway service: `rogerthat`
- Project ID: `7daad361-67e7-4b84-b26f-cecdd3856193`
- Service ID: `2eb7d73f-4e1e-49dc-baa2-ed9ce1e42ba9`
- Deployment config: [`../server/railway.json`](../server/railway.json)
- Replica: 1
- Volume: `/app/data`

## Runtime variables

```text
HOST=0.0.0.0
PORT=7424
PUBLIC_ORIGIN=https://rogerthat-production-fff6.up.railway.app
```

`ROGERRAT_ADMIN_TOKEN` 未设置，因此公网不启用管理页。

## Redeploy

```bash
cd server
railway up --service rogerthat
```

## Verified

- `/healthz` 返回 `ok`。
- 公网 create → 两端 join → send → listen 成功。
- 错误 bearer token 返回 401。
- Railway 重启后，重启前创建的频道仍可用原 token 加入。
- 当前默认 Desktop IPC 已在两台独立 Mac 上完成公网双向入站：频道 SSE → 后台目标 task
  → 真实 turn。该结果证明 Connector 两端可投递，不等于目标 AI 已拥有频道出站权限。
- 空闲监听不会创建 turn，频道凭证不会进入模型正文。
- 频道正文按不可信外部输入进入 task；验收不得通过正文命令 AI 返回固定标记，应分别核对
  Host 接受回执、真实 turn 和 AI 的安全处理结果。

历史版本曾公开 `open_channel_view` 与 `ui://rogerthat/channel-view-v1.html`，但 MCP App
View 路线已被本地 Subscription Runtime + Host Connector 取代，不再作为当前接收方案。
部署和 Host 验收证据保存在 `openspec/changes/archive/`。

## Known boundary

Volume 只保存频道凭据、统计和显式 transcript。在线 session、消费 cursor 和最近 100 条
消息属于单进程内存状态；不要配置多副本，升级为高可用前需迁移到共享数据库。

ChatGPT Desktop 必须正常启动且目标 task 属于当前内嵌 runtime。若曾设置
`CODEX_APP_SERVER_USE_LOCAL_DAEMON=1`，先 `launchctl unsetenv` 并完全重启 ChatGPT；
旧 daemon 创建的 task 不能假定能被当前 Desktop runtime 继续认领。

以上是已验收基线，不代表当前线上 revision 永久不变；发布后仍需重新检查 health、
授权、持久化恢复和真实 Host 链路。
