# Design

```text
RogerThat SSE -> listen-here -> Codex App Server daemon -> bound task turn/start
```

`listen-here` 只在普通消息通过优先级过滤后调用 `startCodexTurn`。适配器通过本机权限为
`0600` 的 Unix socket 完成 `initialize`、`thread/resume`、`turn/start`，收到 turn 接受
响应后关闭连接。消息正文使用 JSON 封装并显式标为不可信外部输入。

配置 `--codex-source-thread` 时，Bridge 在外层生成 Desktop 可识别的
`codex_delegation` 信封，并对正文中的 `&<>` 做转义。来源任务 id 必须来自本地 CLI
配置，不能采用远端消息字段；跨用户场景应映射到接收端本机的代理来源任务。

游标只在 turn 被 App Server 接受后推进；注入失败会保持旧游标并触发现有重连，因此
不会因临时 writer busy 或 daemon 故障静默丢消息。
