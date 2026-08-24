# Agent Channels Roadmap

路线图按用户价值和验收门槛推进，不承诺日期。

## P0：证明会话间协作闭环（当前）

目标：两个用户现有的 Codex 会话可以跨设备交换消息，且没有空闲 AI 成本。

- 完成 Host-neutral `deliver(message)` 边界；
- 保持 Codex 为唯一 Connector；
- 完成两个用户、两台设备的双向真实验收；
- 保持 App 负责持续接收、历史和 Host 投递；MCP 只执行当前 task 的六项显式频道操作；
- 用产品级 Skill 让 AI 理解完整频道语义，并默认以 Agent Channels Markdown 卡片区分外部消息；
- 创建时填写频道名称；邀请口令直接携带频道，加入者只需粘贴；用户昵称在设置中全局维护；
- 明确 Host 不可用、授权失效、断线恢复和重复投递状态；
- 用不依赖 Node、npm、Codex CLI、standalone daemon 或环境变量的菜单栏验收包完成闭环。

退出条件：`PRODUCT.md` 中九项 0.3 Beta 完成标准全部通过。

## P1：变成可日常使用的本地产品

目标：把本地验收包提升为可公开分发、可长期运行的产品。

- Developer ID 签名、公证、可验证的安装更新和 Intel Mac 取舍；
- App/sidecar 崩溃恢复、孤儿进程清理和版本升级；
- 未读数量、漏消息摘要和恢复选择；
- Connector 兼容性探测与可操作错误提示；
- 一条公开可复现的安装、卸载和升级路径。

P1 不增加第二个 Host，先把 Codex 体验做完整。

## P2：稳定身份与协作关系

目标：从临时 token 实验升级为可管理的协作产品。

- Human 账户与设备身份；
- 持久 Membership、邀请、接受、撤权和频道所有权；
- 多设备和多个 Conversation Session 的明确绑定规则；
- 短期消息保留、审计边界和滥用治理；
- 服务端共享运行态与高可用评估。

## Later：按真实需求扩展 Host

只有出现真实用户需求并完成目标 Host 能力验证后，才实现第二个 Connector。新增 Host
必须明确它属于原生会话注入、Host 原生 Channel、CLI 恢复还是通知降级，不能降低
Agent Channels 对“持续监听”和“消息驱动”的产品承诺。

暂不建设 Connector 市场、通用 SDK、完整聊天客户端或自建模型 Runtime。
