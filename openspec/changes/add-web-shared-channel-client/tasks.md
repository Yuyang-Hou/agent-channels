# Tasks

## 1. Contract

- [x] 更新 Product、Architecture、Roadmap、Status 与当前 OpenSpec
- [x] 明确 Web 只复用现有服务、账号、Membership、邀请与 Channel

## 2. Browser Account

- [x] 增加 Web GitHub 登录和 HttpOnly Account Session Cookie
- [x] 保持桌面 PKCE/Bearer 登录兼容

## 3. Shared Channel Client

- [x] 增加同源 `/app` 与 `/join/<channel>` 页面
- [x] 支持 active Membership 恢复、频道切换、最近消息和纯文本收发
- [x] 已加入时跳过邀请兑换；未加入时只确认一次
- [x] 收到撤权后移除频道，未知发送结果不自动重试

## 4. Invitation Handoff

- [x] macOS 默认复制 Web 邀请链接
- [x] macOS 继续解析旧 `ac2:` 口令和新链接

## 5. Verification

- [x] Web 登录 Cookie、幂等邀请和不重复消耗自动化
- [x] 已登录刷新期间不短暂展示登录提示
- [x] 全量服务端测试、typecheck、build、Swift 自测与 OpenSpec strict
- [x] 本地页面预览
- [ ] 真实部署环境 OAuth/邀请验收
