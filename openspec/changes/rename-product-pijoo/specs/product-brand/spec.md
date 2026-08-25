# Product Brand Requirements

## ADDED Requirements

### Requirement: 产品统一显示 Pijoo

所有当前用户可见的 App、安装包、菜单、提示、MCP 工具和产品文档 MUST 使用 `Pijoo`，不得继续
把旧工作名称作为当前产品名。

#### Scenario: 安装并启动正式 Beta 候选

- **GIVEN** 用户取得新构建的安装包
- **WHEN** 用户挂载 DMG、安装并启动 App
- **THEN** DMG、App bundle、菜单和主窗口都显示 `Pijoo`

### Requirement: 技术命名空间 clean-slate 切换

当前源码、Bundle ID、Keychain service、App Support、MCP、Skill、环境变量和协议标签 MUST 使用
`Pijoo` 对应的新命名，不得为旧工作名称增加兼容读写。

#### Scenario: 新 App 首次启动

- **GIVEN** 本机可能存在旧内测 App 的本机状态
- **WHEN** `Pijoo.app` 首次启动
- **THEN** App 使用 `dev.pijoo` 与 `Pijoo` 路径创建新状态，不读取或覆盖旧状态

### Requirement: 未迁移外部资源保持可用

尚未执行外部重命名的 GitHub 与 Railway 资源 MUST 继续使用其真实定位，当前产品文档 MUST NOT
把不存在的新仓库或服务地址描述为可用。

#### Scenario: 检查 GitHub Release

- **GIVEN** GitHub 仓库尚未重命名
- **WHEN** Pijoo 检查更新
- **THEN** App 仍访问当前真实仓库的 Release API
