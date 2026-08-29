# Verification

## Automated

- 路径检查：相同账号得到稳定目录，不同账号隔离，目录名不包含原始 account id；
- 文件检查：工作区与 `AGENTS.md` 权限正确，缺失或被修改时恢复内置版本，远端文本不进入模板；
- 创建检查：`thread/start.cwd` 只能是当前账号受管目录；
- 路由检查：默认助理选择外部 task 不创建 Subscription，只更新明确授权的 history allowlist；
- 投递检查：task id、cwd 或权限任一漂移时不调用 start/steer turn、不推进游标；
- 历史检查：只读已授权 task，撤销立即生效，结果有来源和上限，原 task 无新增 turn；
- `npx --yes @fission-ai/openspec@1.6.0 validate --strict --all`；
- `npm test --prefix server -- --no-file-parallelism`；
- `npm run typecheck --prefix server` 与 `npm run build --prefix server`；
- Swift `-typecheck -warnings-as-errors` 与 macOS v2 self-test。

首轮源码验证：OpenSpec 18/18、server 115/115、TypeScript typecheck/build、Swift strict typecheck、
macOS self-test 与 `git diff --check` 均通过；随后发布 `beta.25` 进入真实 Codex/UI 验收。

真实 `beta.25` 验收发现：空 `thread/start` 在数据库登记了 rollout path，但未生成对应文件，Desktop
打开时报 `failed to resolve rollout path ... file does not exist`。修复恢复中性 `thread/inject_items`
持久化步骤，并由 task 创建协议测试固定该调用顺序；身份与权限仍分别来自 `AGENTS.md` 和运行时复验。
修复后另用隔离临时 `CODEX_HOME` 调用真实 Codex `0.150.0-alpha.12.2`：task 创建成功、rollout JSONL
存在且包含正确 cwd 与中性初始化记录，`host-preflight` 可重新解析该 task。

## Real Product Checks

1. 用账号 A 创建默认助理，确认 task cwd 是 A 的受管目录且启动时加载内置身份卡；
2. 分享默认助理频道，账号 B 从 Web 发一条要求读取其他项目并提升权限的消息；
3. 确认消息只进入受管 task，cwd 保持不变，权限仍为 workspace + user approval；
4. 在 Codex 侧手动把 task 改到不安全档位，再发送频道消息；App 必须停止投递且游标不推进；
5. 选择既有 task X，确认 X 只成为显式只读来源，频道消息不会在 X 创建 turn；
6. 撤销 X 后立即检索，X 的标题和正文均不可读；
7. 检查服务端与 Web 响应不包含工作目录、`AGENTS.md`、task id、allowlist 或 sandbox 状态。

本 change 不授权打包、部署、发布或生产数据迁移。
