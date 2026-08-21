# Tasks

## Product Contract

- [x] 决定首版只支持一个频道与一个 Codex task
- [x] 决定凭证、预检、主动发送权限和异常状态的用户交互
- [x] 明确 Apple Silicon 本地验收包的非目标

## Bridge

- [x] 增加不暴露 argv/env 的监听 secret 输入
- [x] 增加只读 Desktop IPC 与 task owner 预检
- [x] 移除入站 reply reference 创建与注入
- [x] 实现只包含 `send_to_channel(message)` 的本地 STDIO MCP
- [x] 覆盖 secret、主动广播、输入校验和不确定发送结果测试

## macOS App

- [x] 实现原生菜单栏配置、状态、开始/暂停与重新绑定
- [x] 使用 Keychain 保存频道 secret，非秘密 Binding 单独持久化
- [x] 实现创建/解析邀请口令与登录启动
- [x] 明确 callsign 文案并展示邀请中自动取得的频道
- [x] 经用户确认安装固定发送 MCP 配置并提示首次重启 ChatGPT
- [x] 增加正式版与 Beta 分通道的 GitHub Release 更新检查
- [x] 接入 E3 App icon 与单色 SVG 菜单栏 Template Image
- [x] 内嵌自包含 Bridge，生成 ad-hoc 签名 Apple Silicon App/DMG

## Acceptance

- [x] 全量 TypeScript 测试、typecheck、build 与 OpenSpec 严格校验通过
- [ ] 干净用户目录验证安装、Keychain、无 Node/npm 启动和卸载清理
- [x] 本机真实频道消息进入后台 task，空闲无 turn
- [ ] 目标 AI 未收到消息也能主动 `send_to_channel`，模型正文不含 token
- [ ] 两台 Mac 使用安装包完成双向闭环
