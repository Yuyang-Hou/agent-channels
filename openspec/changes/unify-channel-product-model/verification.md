# Verification

## Automated

- `npm run typecheck --prefix server`
- `npm test --prefix server`（116 tests passed）
- `npm run build --prefix server`
- `openspec validate --strict --all`（20 items passed）
- `./macos/build/pijoo-self-test`（`macos v2 self-test ok`）
- `PIJOO_APP_ONLY=1 PIJOO_SKIP_SELF_TESTS=1 PIJOO_SIGN_IDENTITY=- ./macos/build-app.sh`
- `git diff --check`

## Product checks

- 新账号没有自动频道；创建 Channel 后自动出现唯一受管 Codex task。
- App/Web 不再显示助理、好友或群聊类型，也不使用对方昵称替换频道名。
- owner 从 App/Web 发送的 human 消息进入 Codex；AI 回复显示在频道但不回流 Codex。
- 人类和 AI 连续发言时使用不同头像/标签，永不合并。
- 加入他人 Channel 不在加入者本机创建第二个 Codex task。
