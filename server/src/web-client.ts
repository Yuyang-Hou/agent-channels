export function webAppHtml(accountEnabled: boolean): string {
  return `<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
  <meta name="theme-color" content="#f4f1ea">
  <title>Pijoo · 频道</title>
  <style>
    :root {
      color-scheme: light;
      --ink: #1c2523;
      --muted: #69726f;
      --paper: #f4f1ea;
      --panel: #fffdf8;
      --line: #ddd9cf;
      --accent: #24725d;
      --accent-strong: #155543;
      --accent-soft: #deeee8;
      --danger: #b34435;
      --shadow: 0 20px 60px rgba(44, 54, 50, .12);
    }
    * { box-sizing: border-box; }
    html, body { height: 100%; }
    body {
      margin: 0;
      background:
        radial-gradient(circle at 8% 8%, rgba(67, 143, 118, .13), transparent 28rem),
        var(--paper);
      color: var(--ink);
      font: 15px/1.5 -apple-system, BlinkMacSystemFont, "SF Pro Text", "PingFang SC", "Helvetica Neue", sans-serif;
    }
    button, textarea, input { font: inherit; }
    button, a { -webkit-tap-highlight-color: transparent; }
    button { cursor: pointer; }
    .shell {
      min-height: 100%;
      display: grid;
      grid-template-columns: 284px minmax(0, 1fr);
      padding: 18px;
      gap: 14px;
    }
    .sidebar, .conversation {
      background: color-mix(in srgb, var(--panel) 94%, transparent);
      border: 1px solid rgba(183, 180, 170, .72);
      box-shadow: var(--shadow);
      overflow: hidden;
    }
    .sidebar { border-radius: 26px; display: flex; flex-direction: column; min-height: calc(100vh - 36px); }
    .conversation { border-radius: 30px; min-height: calc(100vh - 36px); display: flex; flex-direction: column; }
    .brand {
      display: flex;
      align-items: center;
      gap: 11px;
      padding: 22px 20px 18px;
    }
    .brand img { width: 36px; height: 36px; border-radius: 12px; }
    .brand strong { display: block; font-size: 18px; letter-spacing: -.02em; }
    .brand span { display: block; color: var(--muted); font-size: 12px; }
    .sidebar-label {
      padding: 4px 20px 10px;
      color: var(--muted);
      font-size: 11px;
      font-weight: 700;
      letter-spacing: .12em;
      text-transform: uppercase;
    }
    .channels { list-style: none; margin: 0; padding: 0 10px; overflow: auto; flex: 1; }
    .channel-button {
      width: 100%;
      display: grid;
      grid-template-columns: 40px minmax(0, 1fr);
      gap: 11px;
      align-items: center;
      border: 0;
      border-radius: 17px;
      background: transparent;
      padding: 10px;
      text-align: left;
      color: var(--ink);
    }
    .channel-button:hover { background: #f0eee8; }
    .channel-button[aria-current="true"] { background: var(--accent-soft); }
    .avatar {
      width: 40px;
      height: 40px;
      border-radius: 14px;
      display: grid;
      place-items: center;
      background: #e9e5db;
      color: var(--accent-strong);
      font-weight: 750;
    }
    .channel-button[aria-current="true"] .avatar { background: var(--accent); color: white; }
    .channel-name { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; font-weight: 650; }
    .channel-meta { color: var(--muted); font-size: 12px; }
    .account {
      margin: 12px;
      padding: 12px;
      border-top: 1px solid var(--line);
      display: flex;
      gap: 9px;
      align-items: center;
    }
    .account-copy { min-width: 0; flex: 1; }
    .account-copy strong, .account-copy span { display: block; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .account-copy span { color: var(--muted); font-size: 12px; }
    .icon-button, .subtle-button {
      border: 1px solid var(--line);
      background: var(--panel);
      color: var(--ink);
      border-radius: 12px;
      padding: 8px 11px;
    }
    .icon-button:hover, .subtle-button:hover { border-color: #aaa69c; }
    .mobile-menu { display: none; }
    .conversation-header {
      min-height: 79px;
      padding: 17px 22px;
      border-bottom: 1px solid var(--line);
      display: flex;
      align-items: center;
      gap: 14px;
    }
    .conversation-header h1 { margin: 0; font-size: 20px; letter-spacing: -.025em; }
    .conversation-header p { margin: 1px 0 0; color: var(--muted); font-size: 12px; }
    .connection-dot {
      width: 8px;
      height: 8px;
      border-radius: 50%;
      background: #aaa;
      box-shadow: 0 0 0 4px rgba(170,170,170,.12);
    }
    .connection-dot.online { background: #2b8e69; box-shadow: 0 0 0 4px rgba(43,142,105,.12); }
    .content { flex: 1; min-height: 0; display: flex; flex-direction: column; }
    .messages {
      flex: 1;
      overflow: auto;
      padding: 24px clamp(18px, 4vw, 56px);
      scroll-behavior: smooth;
    }
    .message-row { display: flex; margin: 0 0 16px; }
    .message-row.mine { justify-content: flex-end; }
    .message {
      max-width: min(680px, 82%);
      border: 1px solid var(--line);
      border-radius: 20px 20px 20px 6px;
      background: white;
      padding: 11px 14px 10px;
      box-shadow: 0 6px 22px rgba(44, 54, 50, .06);
    }
    .mine .message {
      color: white;
      background: var(--accent);
      border-color: var(--accent);
      border-radius: 20px 20px 6px 20px;
    }
    .message-row.ai { justify-content: flex-start; }
    .ai .message { background: var(--accent-soft); border-color: rgba(36,114,93,.22); }
    .ai .message-head { color: var(--accent-strong); }
    .message-head { display: flex; gap: 12px; justify-content: space-between; margin-bottom: 4px; color: var(--muted); font-size: 11px; }
    .mine .message-head { color: rgba(255,255,255,.72); }
    .message-text { white-space: pre-wrap; overflow-wrap: anywhere; }
    .empty-state, .gate {
      margin: auto;
      max-width: 520px;
      padding: 38px;
      text-align: center;
    }
    .empty-mark {
      width: 62px;
      height: 62px;
      margin: 0 auto 18px;
      border-radius: 22px;
      display: grid;
      place-items: center;
      background: var(--accent-soft);
      color: var(--accent);
      font-size: 28px;
    }
    .empty-state h2, .gate h2 { margin: 0 0 8px; font-size: 24px; letter-spacing: -.03em; }
    .empty-state p, .gate p { margin: 0 auto 20px; color: var(--muted); }
    .primary-button {
      display: inline-flex;
      align-items: center;
      justify-content: center;
      min-height: 44px;
      padding: 0 18px;
      border: 0;
      border-radius: 14px;
      background: var(--accent);
      color: white;
      font-weight: 700;
      text-decoration: none;
    }
    .primary-button:hover { background: var(--accent-strong); }
    .primary-button:disabled { opacity: .5; cursor: default; }
    .composer-wrap { padding: 12px 18px 18px; }
    .notice {
      min-height: 22px;
      max-width: 860px;
      margin: 0 auto 6px;
      color: var(--muted);
      font-size: 12px;
    }
    .notice.error { color: var(--danger); }
    .composer {
      max-width: 860px;
      margin: 0 auto;
      display: grid;
      grid-template-columns: minmax(0, 1fr) auto;
      gap: 9px;
      align-items: end;
      padding: 9px;
      background: white;
      border: 1px solid var(--line);
      border-radius: 20px;
      box-shadow: 0 12px 34px rgba(44, 54, 50, .09);
    }
    .composer:focus-within { border-color: var(--accent); box-shadow: 0 0 0 3px rgba(36,114,93,.12); }
    textarea {
      width: 100%;
      min-height: 44px;
      max-height: 160px;
      resize: none;
      border: 0;
      outline: 0;
      padding: 10px 9px;
      color: var(--ink);
      background: transparent;
    }
    .send {
      width: 44px;
      height: 44px;
      border: 0;
      border-radius: 14px;
      color: white;
      background: var(--accent);
      font-size: 19px;
    }
    .send:disabled { opacity: .45; cursor: default; }
    .hidden { display: none !important; }
    @media (max-width: 760px) {
      .shell { display: block; padding: 0; }
      .conversation { min-height: 100vh; border: 0; border-radius: 0; box-shadow: none; }
      .sidebar {
        position: fixed;
        inset: 0 18% 0 0;
        z-index: 10;
        min-height: 100vh;
        border-radius: 0 28px 28px 0;
        transform: translateX(-110%);
        transition: transform .2s ease;
      }
      body.menu-open::after { content: ""; position: fixed; inset: 0; z-index: 9; background: rgba(16,23,21,.4); }
      body.menu-open .sidebar { transform: translateX(0); }
      .mobile-menu { display: inline-grid; place-items: center; width: 40px; height: 40px; padding: 0; }
      .conversation-header { padding: 13px 14px; }
      .messages { padding: 18px 14px; }
      .message { max-width: 88%; }
      .composer-wrap { padding: 8px 10px max(12px, env(safe-area-inset-bottom)); }
      .gate, .empty-state { padding: 26px 22px; }
    }
  </style>
</head>
<body>
  <main class="shell">
    <aside class="sidebar" aria-label="频道列表">
      <div class="brand">
        <img src="/logo.svg" alt="">
        <div><strong>Pijoo</strong><span>频道</span></div>
      </div>
      <div class="sidebar-label">我的频道</div>
      <ul class="channels" id="channels"></ul>
      <div class="account hidden" id="account">
        <div class="avatar" id="accountAvatar">P</div>
        <div class="account-copy"><strong id="accountName"></strong><span>GitHub 账号</span></div>
        <button class="icon-button" id="logout" type="button" aria-label="退出登录">退出</button>
      </div>
    </aside>
    <section class="conversation">
      <header class="conversation-header">
        <button class="icon-button mobile-menu" id="menu" type="button" aria-label="打开频道列表">☰</button>
        <span class="connection-dot" id="connectionDot" aria-hidden="true"></span>
        <div><h1 id="title">Pijoo</h1><p id="subtitle">安全地加入频道</p></div>
      </header>
      <div class="content" id="content">
        <div class="gate hidden" id="gate">
          <div class="empty-mark">↗</div>
          <h2 id="gateTitle">连接你的频道</h2>
          <p id="gateCopy">登录后即可恢复曾经加入的频道，或使用邀请链接加入频道。</p>
          <a class="primary-button" id="login" href="/web/auth/github/start?return_to=/app">使用 GitHub 登录</a>
        </div>
        <div class="messages hidden" id="messages" aria-live="polite"></div>
        <div class="composer-wrap hidden" id="composerWrap">
          <div class="notice" id="notice" role="status"></div>
          <form class="composer" id="composer">
            <textarea id="messageInput" maxlength="8192" rows="1" placeholder="发消息到频道…" aria-label="消息"></textarea>
            <button class="send" id="send" type="submit" aria-label="发送消息">↑</button>
          </form>
        </div>
      </div>
    </section>
  </main>
  <script>
    const ACCOUNT_ENABLED = ${accountEnabled ? "true" : "false"};
    const el = (id) => document.getElementById(id);
    const ui = {
      channels: el("channels"), account: el("account"), accountName: el("accountName"),
      accountAvatar: el("accountAvatar"), logout: el("logout"), menu: el("menu"),
      title: el("title"), subtitle: el("subtitle"), dot: el("connectionDot"),
      gate: el("gate"), gateTitle: el("gateTitle"), gateCopy: el("gateCopy"), login: el("login"),
      messages: el("messages"), composerWrap: el("composerWrap"), composer: el("composer"),
      input: el("messageInput"), send: el("send"), notice: el("notice")
    };
    const state = {
      session: null, channels: [], selected: null, messages: [], connections: new Map(),
      pollController: null, pendingChannel: joinChannelFromPath(), pendingInvite: null
    };

    function joinChannelFromPath() {
      const match = location.pathname.match(/^\\/join\\/([^/]+)$/);
      return match ? decodeURIComponent(match[1]) : null;
    }

    function inviteStorageKey(channel) { return "pijoo:invite:" + channel; }

    function captureInvite() {
      if (!state.pendingChannel) return;
      const fragment = new URLSearchParams(location.hash.slice(1));
      const token = fragment.get("invite");
      if (token) sessionStorage.setItem(inviteStorageKey(state.pendingChannel), token);
      state.pendingInvite = token || sessionStorage.getItem(inviteStorageKey(state.pendingChannel));
      if (location.hash) history.replaceState(null, "", location.pathname + location.search);
    }

    async function request(url, options) {
      const response = await fetch(url, options);
      const body = await response.json().catch(() => ({}));
      if (!response.ok) {
        const error = new Error(body.error || "请求失败");
        error.status = response.status;
        error.code = body.code;
        throw error;
      }
      return body;
    }

    function channelTitle(channel) { return channel.channel_name || "未命名频道"; }

    function setGate(title, copy, action, href) {
      stopPolling();
      state.selected = null;
      ui.login.onclick = null;
      ui.gateTitle.textContent = title;
      ui.gateCopy.textContent = copy;
      ui.login.textContent = action || "使用 GitHub 登录";
      ui.login.href = href || "/web/auth/github/start?return_to=" + encodeURIComponent(location.pathname + location.search);
      ui.login.classList.toggle("hidden", !action && !href && !!state.session);
      ui.gate.classList.remove("hidden");
      ui.messages.classList.add("hidden");
      ui.composerWrap.classList.add("hidden");
      ui.dot.classList.remove("online");
    }

    function renderChannels() {
      ui.channels.replaceChildren();
      for (const channel of state.channels) {
        const item = document.createElement("li");
        const button = document.createElement("button");
        button.type = "button";
        button.className = "channel-button";
        button.setAttribute("aria-current", state.selected && state.selected.channel_id === channel.channel_id ? "true" : "false");
        const avatar = document.createElement("span");
        avatar.className = "avatar";
        avatar.textContent = channelTitle(channel).slice(0, 1).toUpperCase();
        const copy = document.createElement("span");
        const name = document.createElement("span");
        name.className = "channel-name";
        name.textContent = channelTitle(channel);
        const meta = document.createElement("span");
        meta.className = "channel-meta";
        meta.textContent = "频道";
        copy.append(name, meta);
        button.append(avatar, copy);
        button.addEventListener("click", () => openChannel(channel));
        item.append(button);
        ui.channels.append(item);
      }
    }

    function showAccount() {
      ui.account.classList.remove("hidden");
      ui.accountName.textContent = state.session.display_name;
      ui.accountAvatar.textContent = state.session.display_name.slice(0, 1).toUpperCase();
    }

    async function loadChannels() {
      const body = await request("/v1/channels");
      state.channels = body.channels || [];
      renderChannels();
      if (state.pendingChannel) {
        const existing = state.channels.find((channel) => channel.channel_id === state.pendingChannel);
        if (existing) {
          sessionStorage.removeItem(inviteStorageKey(state.pendingChannel));
          state.pendingInvite = null;
          await openChannel(existing);
          return;
        }
        showJoinGate();
        return;
      }
      if (!state.channels.length) {
        setGate("还没有频道", "请使用邀请链接加入频道。");
        return;
      }
      const remembered = localStorage.getItem("pijoo:selected-channel");
      await openChannel(state.channels.find((channel) => channel.channel_id === remembered) || state.channels[0]);
    }

    function showJoinGate() {
      ui.title.textContent = "加入频道";
      ui.subtitle.textContent = "邀请只在首次加入时使用";
      if (!state.pendingInvite) {
        setGate("邀请信息缺失", "请重新打开完整的邀请链接。", "返回我的频道", "/app");
        return;
      }
      setGate("加入频道？", "加入后，该频道会保存在你的账号中，以后登录即可直接回来。", "确认加入", "#");
      ui.login.onclick = async (event) => {
        event.preventDefault();
        ui.login.setAttribute("aria-busy", "true");
        try {
          await request("/api/channels/" + encodeURIComponent(state.pendingChannel) + "/invites/redeem", {
            method: "POST",
            headers: { "content-type": "application/json" },
            body: JSON.stringify({ invite_token: state.pendingInvite, name: state.session.display_name })
          });
          sessionStorage.removeItem(inviteStorageKey(state.pendingChannel));
          state.pendingInvite = null;
          await loadChannels();
        } catch (error) {
          ui.gateCopy.textContent = error.status === 401 ? "邀请已失效或已被使用，请联系分享者获取新链接。" : error.message;
        } finally {
          ui.login.removeAttribute("aria-busy");
        }
      };
    }

    async function openChannel(channel) {
      stopPolling();
      state.selected = channel;
      localStorage.setItem("pijoo:selected-channel", channel.channel_id);
      document.body.classList.remove("menu-open");
      ui.title.textContent = channelTitle(channel);
      ui.subtitle.textContent = "频道 · 最近消息";
      ui.gate.classList.add("hidden");
      ui.messages.classList.remove("hidden");
      ui.composerWrap.classList.remove("hidden");
      ui.notice.textContent = "正在连接…";
      ui.notice.classList.remove("error");
      renderChannels();
      try {
        const callsign = "web_" + state.session.device_id.replace(/[^a-z0-9]/gi, "").slice(0, 12).toLowerCase();
        const joined = await request("/api/channels/" + encodeURIComponent(channel.channel_id) + "/join", {
          method: "POST",
          headers: { "content-type": "application/json" },
          body: JSON.stringify({ callsign: callsign, name: state.session.display_name })
        });
        const connection = {
          sessionId: joined.session_id,
          lastId: Math.max(0, ...(joined.history || []).map((message) => Number(message.id) || 0))
        };
        state.connections.set(channel.channel_id, connection);
        state.messages = joined.history || [];
        renderMessages();
        ui.dot.classList.add("online");
        ui.notice.textContent = "";
        poll(channel, connection);
      } catch (error) {
        ui.notice.textContent = error.status === 401 ? "你已无法访问此频道。" : error.message;
        ui.notice.classList.add("error");
        if (error.status === 401) await refreshAfterRevocation(channel.channel_id);
      }
    }

    function renderMessages() {
      ui.messages.replaceChildren();
      if (!state.messages.length) {
        const empty = document.createElement("div");
        empty.className = "empty-state";
        const title = document.createElement("h2");
        title.textContent = "开始这段对话";
        const copy = document.createElement("p");
        copy.textContent = "你的消息会发送到这个共享频道。";
        empty.append(title, copy);
        ui.messages.append(empty);
        return;
      }
      const seen = new Set();
      state.messages = state.messages.filter((message) => {
        const id = String(message.id);
        if (seen.has(id)) return false;
        seen.add(id);
        return message.kind !== "status";
      }).sort((a, b) => Number(a.id) - Number(b.id));
      for (const message of state.messages) {
        const row = document.createElement("div");
        const isAI = message.author_kind === "channel_ai";
        row.className = "message-row" + (isAI ? " ai" : message.sender_member_id === state.selected.membership_id ? " mine" : "");
        const bubble = document.createElement("article");
        bubble.className = "message";
        const head = document.createElement("div");
        head.className = "message-head";
        const sender = document.createElement("span");
        sender.textContent = isAI ? "AI" : message.sender_name || message.from || "频道成员";
        const time = document.createElement("time");
        time.textContent = new Date(message.at).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });
        const text = document.createElement("div");
        text.className = "message-text";
        text.textContent = message.text || "";
        head.append(sender, time);
        bubble.append(head, text);
        row.append(bubble);
        ui.messages.append(row);
      }
      ui.messages.scrollTop = ui.messages.scrollHeight;
    }

    async function poll(channel, connection) {
      const controller = new AbortController();
      state.pollController = controller;
      while (!controller.signal.aborted && state.selected && state.selected.channel_id === channel.channel_id) {
        try {
          const body = await request(
            "/api/channels/" + encodeURIComponent(channel.channel_id) + "/listen?timeout=25&since=" + connection.lastId,
            { headers: { "x-session-id": connection.sessionId }, signal: controller.signal }
          );
          for (const message of body.messages || []) {
            connection.lastId = Math.max(connection.lastId, Number(message.id) || 0);
            state.messages.push(message);
          }
          if ((body.messages || []).length) renderMessages();
          ui.dot.classList.add("online");
        } catch (error) {
          if (controller.signal.aborted || error.name === "AbortError") return;
          ui.dot.classList.remove("online");
          if (error.status === 410) {
            await openChannel(channel);
            return;
          }
          if (error.status === 401) {
            ui.notice.textContent = "频道访问已失效。";
            ui.notice.classList.add("error");
            await refreshAfterRevocation(channel.channel_id);
            return;
          }
          await new Promise((resolve) => setTimeout(resolve, 1500));
        }
      }
    }

    function stopPolling() {
      if (state.pollController) state.pollController.abort();
      state.pollController = null;
    }

    async function refreshAfterRevocation(channelId) {
      stopPolling();
      state.connections.delete(channelId);
      const body = await request("/v1/channels").catch(() => ({ channels: [] }));
      state.channels = body.channels || [];
      renderChannels();
      const fallback = state.channels[0];
      if (fallback) await openChannel(fallback);
      else setGate("频道访问已结束", "分享者可能已经移除成员；需要新的邀请才能重新加入。");
    }

    ui.composer.addEventListener("submit", async (event) => {
      event.preventDefault();
      const text = ui.input.value.trim();
      const channel = state.selected;
      const connection = channel && state.connections.get(channel.channel_id);
      if (!text || !channel || !connection || ui.send.disabled) return;
      ui.send.disabled = true;
      ui.notice.textContent = "发送中…";
      ui.notice.classList.remove("error");
      try {
        const sent = await request("/api/channels/" + encodeURIComponent(channel.channel_id) + "/send", {
          method: "POST",
          headers: { "content-type": "application/json", "x-session-id": connection.sessionId },
          body: JSON.stringify({ to: "all", message: text, source: { provider: "pijoo-web", label: "网页版" } })
        });
        state.messages.push({
          id: sent.id, at: sent.at, from: sent.from, sender_name: sent.sender_name,
          sender_member_id: channel.membership_id, sender_endpoint_id: sent.sender_endpoint_id,
          author_kind: sent.author_kind || "human", to: sent.to, text: text, source: sent.source
        });
        connection.lastId = Math.max(connection.lastId, Number(sent.id) || 0);
        ui.input.value = "";
        ui.input.style.height = "";
        ui.notice.textContent = "";
        renderMessages();
      } catch (error) {
        ui.notice.textContent = error.status ? error.message : "发送结果未知，请勿立即重复发送。";
        ui.notice.classList.add("error");
      } finally {
        ui.send.disabled = false;
        ui.input.focus();
      }
    });

    ui.input.addEventListener("input", () => {
      ui.input.style.height = "auto";
      ui.input.style.height = Math.min(ui.input.scrollHeight, 160) + "px";
    });
    ui.input.addEventListener("keydown", (event) => {
      if (event.key === "Enter" && !event.shiftKey && !event.isComposing) {
        event.preventDefault();
        ui.composer.requestSubmit();
      }
    });
    ui.logout.addEventListener("click", async () => {
      await fetch("/v1/session/logout", { method: "POST" });
      location.assign("/app");
    });
    ui.menu.addEventListener("click", () => document.body.classList.toggle("menu-open"));
    document.addEventListener("click", (event) => {
      if (document.body.classList.contains("menu-open") && !event.target.closest(".sidebar") && !event.target.closest("#menu")) {
        document.body.classList.remove("menu-open");
      }
    });

    async function boot() {
      captureInvite();
      if (!ACCOUNT_ENABLED) {
        setGate("账号服务尚未启用", "请在启用 GitHub 登录的 Pijoo 服务上使用网页版。");
        ui.login.classList.add("hidden");
        return;
      }
      try {
        state.session = await request("/v1/session");
        showAccount();
        await loadChannels();
      } catch (error) {
        if (new URLSearchParams(location.search).get("login") === "cancelled") {
          ui.gateCopy.textContent = "登录已取消，你可以稍后重试。";
        }
        setGate("连接你的频道", ui.gateCopy.textContent || "登录后即可恢复曾经加入的频道，或使用邀请链接加入频道。", "使用 GitHub 登录",
          "/web/auth/github/start?return_to=" + encodeURIComponent(location.pathname + location.search));
      }
    }
    boot();
  </script>
</body>
</html>`;
}
