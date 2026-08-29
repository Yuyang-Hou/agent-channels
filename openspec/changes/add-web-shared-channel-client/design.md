# Design

## Minimal Shape

```text
Pijoo Web -> existing Hono origin -> Account/Membership/Channel APIs
                                     -> macOS Subscription -> Codex task
```

## Authentication

Web 登录复用现有 LoginAttempt。服务端生成浏览器 PKCE verifier 并暂存在十分钟 HttpOnly Cookie；GitHub
回跳后在服务端完成 exchange，签发与 macOS 相同的 Account Session，并写入 90 天 HttpOnly、Secure、
SameSite=Lax Cookie。Bearer 登录保持兼容。

## Invitation State Machine

链接格式为 `/join/<channel>#invite=<token>`。JS 只把 token 暂存在当前标签页 Session Storage，并立即
清除 Fragment。登录完成后先读取账号 active Membership：已加入则直接打开且不调用 redeem；未加入才
显示一次确认。服务端现有 redeem 仍保持幂等，作为并发与旧客户端兜底。

## Channel Runtime

浏览器按 device id 生成稳定 callsign，每个频道独立 `/join`。只对当前频道运行 `/listen?since=` 长轮询；
切换频道立即取消旧请求。发送必须取得服务端 message id 才进入已发送状态，网络错误记为未知且不重试。

## Trust Boundary

Web Session credential 不进入 JS，邀请 token 不持久化。Web 无法读取 task id、历史 allowlist、本机账本或
工作目录。远端正文仍是不可信输入；加入频道不授予工具执行权限。当前传输不是 E2EE。
