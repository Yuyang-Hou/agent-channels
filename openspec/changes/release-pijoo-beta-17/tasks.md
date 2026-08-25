# Tasks

## 1. Release Readiness

- [ ] 为 Developer ID 构建启用 hardened runtime 与安全时间戳
- [ ] 严格校验 OpenSpec、测试与类型检查
- [ ] 将发布代码快进合并到 `main`

## 2. Distribution

- [ ] 从 `main` 构建 Developer ID 签名的 Beta DMG
- [ ] Apple notarization Accepted 并 staple
- [ ] 通过签名、DMG、staple 与 Gatekeeper 验证

## 3. Publication

- [ ] push `main` 并创建 GitHub prerelease
- [ ] 上传 DMG，记录校验和、提交、公证 ID 与发布地址
