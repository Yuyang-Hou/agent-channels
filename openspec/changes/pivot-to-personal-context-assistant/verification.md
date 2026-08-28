# Verification

## Automated

- `npx --yes @fission-ai/openspec@1.6.0 validate --strict --all`
- `npm test --prefix server`
- `npm run typecheck --prefix server`
- Swift `-typecheck -warnings-as-errors`（不创建 App 或 DMG）

## Real Product Checks

1. 登录后确认 App 自动建立昵称命名的默认助理频道，连接一个助理 task，并准备两个普通 Codex task；
2. 默认检索两个普通 task 均被拒绝；
3. 只授权 task A 后，A 的匹配片段带来源返回，task B 的标题和正文均不泄露；
4. 撤销 A 后立即再次检索，A 不可读；
5. 默认助理频道在 App 与绑定 task 间双向收发；双人频道显示“好友”和对方昵称；
6. 助理生成草稿但不发送；用户明确确认后只有一条消息进入联系人端；
7. 记录 App Server 版本不兼容、断线与 unknown 回执的可操作状态。

本 change 不授权打包、部署、发布或生产数据迁移。
