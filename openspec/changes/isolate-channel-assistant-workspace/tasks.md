# Tasks

## 1. Freeze The Contract

- [x] 更新 PRODUCT、Architecture、Roadmap、Status：默认助理只在 Pijoo 受管 task 执行，其他 task 只读
- [x] 明确 `AGENTS.md` 是身份上下文，不是权限边界；共享邀请不继承本机工具权限

## 2. Managed Workspace

- [x] 将静态 `AppPaths.defaultWorkspace` 收敛为按账号摘要生成的助理工作区
- [x] 以 0700 目录、原子写入和内置版本准备 `AGENTS.md`
- [x] 在 `thread/start` 前完成工作区准备，并删除重复的 `thread/inject_items` 身份提示

## 3. Single Execution Target

- [x] 默认助理频道只允许 App 创建的受管 task 成为唯一启用 Subscription
- [x] 在 Subscription 启动、App 唤醒和每次频道投递前复验 task id、cwd 与安全权限档位
- [x] 状态不一致时停止投递且不推进游标；只允许本机 UI 恢复，不允许频道消息提升权限

## 4. Read-only Sources

- [x] 默认助理频道选择既有 task 时不再调用 `subscribe`，只更新历史 allowlist
- [x] 保留当前搜索与 ID 解析 UI，补充授权、撤销和来源说明，不新建第二套会话选择器
- [x] 确认读取只使用 `thread/read`，不在原 task 创建 turn、修改 cwd 或修改权限

## 5. Acceptance

- [x] 最小自动化覆盖路径隔离、身份卡契约、外部 task 拒绑、权限漂移和游标不推进
- [x] 严格 OpenSpec、server tests、typecheck、Swift strict typecheck 与 macOS self-test 通过
- [ ] 真实 Web 加入者验证：远端提示不能访问用户项目、不能提升权限、不能让消息进入原 task
