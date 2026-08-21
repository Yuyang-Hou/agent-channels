# Proposal: Deploy RogerThat on Railway

## 决策

- 复用 MIT 许可的 `opcastil11/rogerthat` 服务端，不重写频道协议。
- 首版部署为 Railway 单实例 Node 服务，默认 `retention=none`。
- 使用邀请 token 加入；所有频道消息均视为不可信外部输入。
- Railway Volume 只持久化频道元数据、统计和显式 transcript。

## 目标

- 公网 `/healthz` 返回 200。
- 两个独立会话可创建频道、加入、发送、监听并恢复短暂断线后的缓冲消息。
- 部署配置可从仓库复现。

## 非目标

- 不复刻 Apuchat 的账户、永久身份、DM、视频、远程控制或付费能力。
- 不承诺进程重启后恢复在线会话或内存消息。
- 不实现 MCP App View 自动唤醒、后台 Agent 或多副本高可用。
