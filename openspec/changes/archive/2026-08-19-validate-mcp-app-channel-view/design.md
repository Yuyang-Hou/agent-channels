# Design

## MCP Apps 链路

`open_channel_view` 在当前 MCP Session 中完成频道 join，并返回：

- `_meta.ui.resourceUri` 指向 `ui://rogerthat/channel-view-v1.html`；
- `structuredContent` 只包含频道、呼号、非机密 session id 和监听状态；
- Tool Result `_meta.channelView` 携带仅供 View 使用的 token、session id 与服务地址。

View 通过 MCP Apps JSON-RPC bridge 初始化，使用带 Authorization 与
X-Session-Id Header 的 `fetch` 读取现有 SSE。普通消息到达后，View 调用
`ui/message`，把来源、消息 id、正文和不可信边界交给 Host。

## 安全边界

- token 不进入 `content` 或 `structuredContent`，避免成为模型可见输出；
- View 不执行消息中的指令，只把它作为显式标注的不可信输入交给 Host；
- REST CORS 允许无 Cookie 的跨域请求，实际权限仍由 Bearer token 控制；
- CSP `connectDomains` 只允许当前 RogerThat Origin；
- `ui/message` 失败即停止自动推进，并在 View 中展示失败，不伪造成功。

## 恢复语义

View 仅在 `ui/message` 成功后记录最后消息 id。重新建立 SSE 时携带 `since`，
用于补发和去重。该游标属于当前 View 的短期恢复证据，不改变服务端仍为内存
运行态的边界。
