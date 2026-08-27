# Tasks

## 1. Version and package checks

- [x] 从当前 marketing version 与最新 Beta tag 计算下一版本，并提供自测
- [x] 构建时让 Beta 序号同步成为 `CFBundleVersion`
- [x] 增加 DMG、App、MCP 版本与内嵌 Skill 的统一校验脚本

## 2. Continuous integration

- [x] PR 与 `main` push 执行 server、OpenSpec、Swift 和 arm64 package 检查
- [x] 仅为 `main` push 上传短期候选 DMG，不使用发布凭据

## 3. Protected release

- [x] 人工触发后锁定 `origin/main`、重新执行检查并导入临时签名凭据
- [x] 签名、公证、staple、Gatekeeper 校验后创建 draft prerelease
- [x] 校验 draft 资产，公开后再次下载并复核最终 SHA-256 和包内容
- [x] 自动生成合并 PR 更新列表并附加构建、公证溯源信息
- [x] 在 GitHub 创建 `release` Environment、配置审批规则和五项 secrets
- [x] 推送后观察 PR/main CI 与一次真实 workflow run
