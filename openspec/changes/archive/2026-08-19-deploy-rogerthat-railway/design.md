# Design

## 运行形态

Railway 运行一个 Node 进程，通过 `HOST=0.0.0.0` 和平台注入的 `PORT` 提供
REST、SSE 与 MCP Streamable HTTP。`/healthz` 作为部署健康检查。

## 数据与恢复

- Channel/session/message/cursor 运行态保存在单进程内存中。
- `channels.json`、`stats.json` 与显式 transcript 写入 `/app/data` Volume。
- 部署或崩溃会中断在线连接并丢失内存消息；客户端按原协议重新加入。
- 单实例是当前边界；扩容前必须把运行态迁移到共享存储。

## 安全边界

- 新建频道生成不可猜测 bearer token，只存 SHA-256 哈希。
- token 使用安全前缀，避免以 `-` 开头时被 CLI 解析为选项。
- 默认不持久化消息正文；公开部署前升级存在安全公告的 HTTP 依赖。
- Admin 仅在设置独立强 token 时启用。
