# Verification

Status: GitHub repository renamed and implementation verified for push.

- 公开仓库现为 `https://github.com/Yuyang-Hou/pijoo`，本地 `origin` 已同步。
- 旧网页地址与旧 Release API 均返回 `301`，已发布 App 的更新检查保持可用。
- 新 Release API 可读取 `v0.3.0-beta.20` prerelease。
- `macos/PijooApp.swift` 的 `SELF_TEST` 编译通过；沙箱外运行返回 `macos v2 self-test ok`。
- `openspec validate --strict --all`：13 passed，0 failed。
- `git diff --check`：passed。
