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
   `Pijoo`，并采用 `pijoo.dev` 对应的 `dev.pijoo` 技术命名空间；
5. [`changes/release-pijoo-beta-17`](./changes/release-pijoo-beta-17/)：从 `main` 构建、
   Developer ID 签名、公证并发布 `0.3.0-beta.17` Apple Silicon 正式 Beta；
6. [`changes/release-pijoo-beta-18`](./changes/release-pijoo-beta-18/)：从当前 `main` 的确定提交构建、
   Developer ID 签名、公证并发布 `0.3.0-beta.18` Apple Silicon 正式 Beta。
7. [`changes/add-channel-mentions`](./changes/add-channel-mentions/)：为 App 与 AI 发送增加不@、
   @所有人和@多名成员，并让每条“转发到会话”Subscription 可选择仅接收提及自己的消息。
8. [`changes/release-pijoo-beta-19`](./changes/release-pijoo-beta-19/)：从合并全部本地功能后的
   `main` 确定提交构建、公证并发布 `0.3.0-beta.19` Apple Silicon GitHub prerelease。
9. [`changes/release-pijoo-beta-20`](./changes/release-pijoo-beta-20/)：从当前 `main` 的确定提交构建、
   公证并发布包含冷会话绑定与会话权限管理的 `0.3.0-beta.20` Apple Silicon GitHub prerelease。
10. [`changes/add-project-license`](./changes/add-project-license/)：以 MIT License 明确 Pijoo 的开源授权，
    并保留 `server/` 中 RogerThat 上游代码的原版权声明。
11. [`changes/rename-github-repository-pijoo`](./changes/rename-github-repository-pijoo/)：将公开 GitHub
    仓库统一为 `Yuyang-Hou/pijoo`，并同步 App 自动更新地址、文档链接与本地 remote。
12. [`changes/improve-product-readme`](./changes/improve-product-readme/)：将仓库首页改为以产品价值、
    下载、使用流程和信任边界为主的 Pijoo 产品入口，把开发细节收敛到文档导航。
13. [`changes/automate-beta-release`](./changes/automate-beta-release/)：为 PR/main 增加统一 CI，
    在合并后保存下一 Beta 候选包，并通过人工触发的受保护流水线完成签名、公证和 GitHub prerelease。
14. [`changes/add-github-account-system`](./changes/add-github-account-system/)：以 GitHub OAuth + PKCE
    建立稳定 Human、设备 Session 与 PostgreSQL Membership；账号版已 clean-slate 切换频道授权，
    登录后恢复频道卡片，不同步本机消息、TaskBinding 或 Host 数据。

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

当前只执行上述十四个活动 change。当前不建设通用插件框架、其他 Host Connector、独立模型
Runtime 或完整聊天客户端。已完成的 Codex 验证记录保留在
[`changes/archive/2026-08-19-add-codex-thread-bridge`](./changes/archive/2026-08-19-add-codex-thread-bridge/)。

`package-macos-menu-bar-app` 与 `define-host-connector-boundary` 中“单 Binding、仅发送工具”的描述
记录 0.2 基线；当前 0.3 的多 Subscription、七工具、产品 Skill 和 Markdown 卡片决策以
`build-multi-channel-beta` 为准。
