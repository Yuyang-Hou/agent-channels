# Agent Channels Current Change

当前活动 changes：

1. [`changes/define-host-connector-boundary`](./changes/define-host-connector-boundary/)：保留已经完成的
   Host-neutral 与 Codex Connector 边界，剩余双用户出站闭环由本地产品包完成；
2. [`changes/package-macos-menu-bar-app`](./changes/package-macos-menu-bar-app/)：把已验证链路包装为
   首个 Apple Silicon 菜单栏验收包。

该 change 把已验证的 Codex 投递链路定义为第一个 Host Connector，确保频道服务、
订阅恢复与消息语义不依赖 Codex。方案、运行时代码边界和无需 daemon/env 的 Desktop
IPC Connector 已完成，下一步只做公网回归及双用户、双设备验收；不增加其他 Host 实现。

产品权威按以下顺序读取：

1. [`../PRODUCT.md`](../PRODUCT.md)
2. [`../docs/STATUS.md`](../docs/STATUS.md)
3. [`../docs/ROADMAP.md`](../docs/ROADMAP.md)
4. [`../ARCHITECTURE.md`](../ARCHITECTURE.md)
5. [`../docs/OPEN_QUESTIONS.md`](../docs/OPEN_QUESTIONS.md)

当前只执行上述两个相关 change；不建设通用插件框架、其他 Host Connector、独立模型
Runtime 或完整聊天客户端。已完成的 Codex 验证记录保留在
[`changes/archive/2026-08-19-add-codex-thread-bridge`](./changes/archive/2026-08-19-add-codex-thread-bridge/)。
