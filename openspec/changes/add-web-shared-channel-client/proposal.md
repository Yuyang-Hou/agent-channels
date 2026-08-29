# Proposal: Add Web Shared Channel Client

## Why

被邀请者目前必须安装 Pijoo App 并粘贴 `ac2:` 口令，无法方便地使用他人分享的会话。账号、Membership、
邀请和频道消息已经存在，缺少的只是同源 Web 入口。

## What Changes

- 现有 Hono 服务托管 `/app` 和 `/join/<channel>`；
- Web 复用 GitHub OAuth，在 HttpOnly Cookie 中保存 Account Session；
- 邀请链接把 token 放在 Fragment，登录后先检查现有 Membership，未加入时才兑换；
- 登录用户恢复所有 active 频道，可切换当前频道并收发纯文本；
- macOS 创建邀请时默认复制 Web 链接，并继续接受旧 `ac2:` 口令；
- 默认助理频道允许 Owner 主动创建邀请，但 Codex task、历史授权与工具权限仍留在本机。

## Non-goals

- 独立 Web 服务、WebSocket、永久云端历史、文件上传、通知或 PWA；
- 在网页选择 Codex task、修改 Subscription、读取本机历史或工作目录；
- 自动授予远端消息文件、Shell、浏览器、部署或付款权限；
- 打包、部署或公开发布。

## Impact

Account、Membership、Invite、Channel 与消息协议不新增并行模型。服务端只增加浏览器 Session Cookie
和页面；macOS 只调整邀请链接呈现与兼容解析。
