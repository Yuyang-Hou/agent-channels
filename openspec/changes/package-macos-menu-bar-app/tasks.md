# Tasks

## Product Contract

- [x] 决定首版只支持一个频道与一个 Codex task
- [x] 决定凭证、预检、回复权限和异常状态的用户交互
- [x] 明确 Apple Silicon 本地验收包的非目标

## Bridge

- [x] 增加不暴露 argv/env 的监听 secret 输入
- [x] 增加只读 Desktop IPC 与 task owner 预检
- [x] 为入站消息创建一次性 reply reference
- [x] 实现只包含 `reply_to_message` 的本地 STDIO MCP
- [x] 覆盖 secret、重复回复、错误目标和不确定发送结果测试

## macOS App

- [x] 实现原生菜单栏配置、状态、开始/暂停与重新绑定
- [x] 使用 Keychain 保存频道 secret，非秘密 Binding 单独持久化
- [x] 实现创建/解析邀请口令与登录启动
- [x] 经用户确认安装固定 MCP 配置并提示首次重启 ChatGPT
- [x] 内嵌自包含 Bridge，生成 ad-hoc 签名 Apple Silicon App/DMG

## Acceptance

- [x] 全量 TypeScript 测试、typecheck、build 与 OpenSpec 严格校验通过
- [ ] 干净用户目录验证安装、Keychain、无 Node/npm 启动和卸载清理
- [x] 本机真实频道消息进入后台 task，空闲无 turn
- [ ] 目标 AI 使用 reply reference 回复原发送者，模型正文不含 token
- [ ] 两台 Mac 使用安装包完成双向闭环
