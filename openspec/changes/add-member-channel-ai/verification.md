# Verification

## Automated

- server：117 tests passed；typecheck 与 build passed。
- Swift：macOS v2 self-test passed；主程序与 sidecar 源码编译 passed。
- OpenSpec strict all（22/22）与 `git diff --check` passed。

Swift 自测在沙箱内因 Unix socket 返回 `Operation not permitted`；同一编译产物在允许 IPC 的环境重跑通过。

## Product checks

- 待真实验收：两名成员分别连接自己的 AI，发送一条 human 消息后两端均收到且可独立回复。
- 待真实验收：App/Web 分别显示“成员名的 AI”，不同 AI 连续回复不合并。
- 待真实验收：AI 页签连接状态紧邻页签栏，不再出现顶部大空白。
- 待真实验收：无人连接 AI 时 @ 菜单没有 AI；连接/断开后目标出现/消失。
- 待真实验收：回复所有消息与仅回复 @我的 AI 两种范围分别命中预期 Host turn。
