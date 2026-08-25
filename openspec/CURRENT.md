# Pijoo Current Change

当前活动 changes：

1. [`changes/define-host-connector-boundary`](./changes/define-host-connector-boundary/)：保留已经完成的
   Host-neutral 与 Codex Connector 边界，剩余双用户出站闭环由本地产品包完成；
2. [`changes/package-macos-menu-bar-app`](./changes/package-macos-menu-bar-app/)：把已验证链路包装为
   首个 Apple Silicon 菜单栏验收包；
3. [`changes/build-multi-channel-beta`](./changes/build-multi-channel-beta/)：以全新 0.3 Beta 数据
   模型建设主窗口、多频道、独立成员凭证、本地消息和 task-channel Subscription，并交付
   产品级 Pijoo Skill 与固定 Markdown 外部消息卡片；
4. [`changes/rename-product-pijoo`](./changes/rename-product-pijoo/)：把工作名称全局统一为
   `Pijoo`，并采用 `pijoo.dev` 对应的 `dev.pijoo` 技术命名空间。

已完成设计、尚未进入实现的 change：

- [`changes/add-github-account-system`](./changes/add-github-account-system/)：以 GitHub OAuth + PKCE
  建立稳定 Human、设备 Session 和账号级 Membership；当前不改代码、不部署，也不阻塞 0.3 Beta
  双用户真实 Host 验收。

该 change 把已验证的 Codex 投递链路定义为第一个 Host Connector，确保频道服务、
订阅恢复与消息语义不依赖 Codex。方案、运行时代码边界和无需 daemon/env 的 Desktop
IPC Connector 已完成。0.2 的发送凭证与断线状态修复继续作为基线；当前新增的产品 change
是 clean-slate 0.3 Beta，不迁移 0.2 单 Binding 数据，也不增加其他 Host 实现。

产品权威按以下顺序读取：

1. [`../PRODUCT.md`](../PRODUCT.md)
2. [`../docs/STATUS.md`](../docs/STATUS.md)
3. [`../docs/ROADMAP.md`](../docs/ROADMAP.md)
4. [`../ARCHITECTURE.md`](../ARCHITECTURE.md)
5. [`../docs/OPEN_QUESTIONS.md`](../docs/OPEN_QUESTIONS.md)

当前只执行上述四个活动 change；账号 change 仅作为下一阶段设计。当前不建设通用插件框架、其他 Host Connector、独立模型
Runtime 或完整聊天客户端。已完成的 Codex 验证记录保留在
[`changes/archive/2026-08-19-add-codex-thread-bridge`](./changes/archive/2026-08-19-add-codex-thread-bridge/)。

`package-macos-menu-bar-app` 与 `define-host-connector-boundary` 中“单 Binding、仅发送工具”的描述
记录 0.2 基线；当前 0.3 的多 Subscription、七工具、产品 Skill 和 Markdown 卡片决策以
`build-multi-channel-beta` 为准。
