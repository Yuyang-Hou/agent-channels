# Archive Note

状态：核心目标完成。公网 SSE 已向未打开的 Codex 会话创建真实 turn，且空闲时没有
额外 turn。原生来源提示实验也已人工看到，但其 `--codex-source-thread` 需要额外本机
任务，产品决定不再依赖。两用户、两设备验收迁移到当前
`define-host-connector-boundary` change。
