# Open Questions

这里只保留尚未形成产品决策的问题。已决策内容以 `PRODUCT.md` 和
`ARCHITECTURE.md` 为准；早期问题全集已归档到
[`archive/OPEN_QUESTIONS-2026-08-18.md`](./archive/OPEN_QUESTIONS-2026-08-18.md)。

## 1. 本地 Runtime 生命周期

0.3 已决定 App 管理多个 TaskBinding 与 task-channel Subscription、可选登录启动，且只有真实
消息才触发 Host。崩溃后的孤儿 sidecar 清理、异常自动拉起和公证后的升级安装仍未决定。正式版
与 Beta 已支持分别手动检查 GitHub Release，但不会静默下载或自我替换。

## 2. 账号实现与数据切换时机

Human 账号方向已收敛为 GitHub OAuth + PKCE、Pijoo 自有 Session、设备身份和账号级
Membership，详见 [`add-github-account-system`](../openspec/changes/add-github-account-system/)。实施前仍需
核对生产环境是否只有测试频道：若已有真实用户，必须暂停 clean-slate 切换并单独设计一次性认领。
若未来改走 Mac App Store，还需在提交前补充符合审核要求的等价隐私登录选项。

## 3. 离线恢复体验

已决定频道持久、会话临时，不把全部历史自动灌入模型。仍需决定恢复时展示未读数量、
摘要、提及还是逐条选择，以及相应的短期保留期限。

## 4. 重复投递

显式失败继续自动重试；已完成终态的历史消息重放只推进游标，不再次调用 Host；SSE 异常断流
使用本连接最新游标重连。mutating 请求发出后若回执丢失，0.3 会持久化 `unknown`、停止对应
Subscription 并保留游标。若要让并发孤儿 sidecar 或该未知窗口也完全自动恢复，仍需要原子 claim
或 Host 幂等键；待真实故障验收后决定。

## 5. Host 兼容性

Codex Connector 当前使用 ChatGPT Desktop 私有 IPC。需要确定版本探测、升级后的兼容性
失败提示和公开支持边界；其他 Host 只在真实需求出现后实现对应 Connector。

## 6. 双用户验收

仍需在两个用户、两台设备、两个独立 AI 会话上完成双向主动发送与接收闭环，并验证撤权、
短暂断线和消息突发时的串行投递。接收与发送独立，不把收到消息作为必须回复的前提。

## 7. 长期产品形态

需求协作频道与兴趣频道是否属于同一产品，以及 Human 与 AI 是否共享同一成员模型，
暂不影响 P0，但在建设账户和目录前必须决定。
