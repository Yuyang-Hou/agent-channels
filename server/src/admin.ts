export function adminHtml(): string {
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width, initial-scale=1" />
<title>rogerthat — admin</title>
<style>
  :root {
    --bg: #f4ede0;
    --ink: #1a1a1a;
    --dim: #7a6f5f;
    --warn: #d6541f;
    --line: #c9b994;
    --paper: #fffaef;
    --ok: #2d8a3e;
  }
  * { box-sizing: border-box; }
  body {
    margin: 0;
    font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
    background: var(--bg);
    color: var(--ink);
    line-height: 1.4;
  }
  .wrap { max-width: 980px; margin: 0 auto; padding: 32px 24px; }
  header { display: flex; align-items: baseline; justify-content: space-between; margin-bottom: 24px; gap: 16px; flex-wrap: wrap; }
  .logo { font-size: 16px; font-weight: 700; display: inline-flex; align-items: center; gap: 8px; }
  .logo svg { width: 22px; height: 22px; }
  .updated { font-size: 12px; color: var(--dim); }
  .auth {
    background: var(--paper);
    border: 2px solid var(--ink);
    padding: 24px;
    margin: 48px auto;
    max-width: 460px;
  }
  .auth h2 { margin: 0 0 12px; font-size: 18px; }
  .auth p { color: var(--dim); font-size: 13px; margin: 0 0 16px; }
  .auth input {
    width: 100%;
    padding: 10px 12px;
    border: 1px solid var(--line);
    background: white;
    font-family: inherit;
    font-size: 14px;
    margin-bottom: 12px;
  }
  .auth button {
    width: 100%;
    padding: 10px;
    background: var(--warn);
    color: white;
    border: none;
    font-family: inherit;
    font-size: 14px;
    font-weight: 700;
    cursor: pointer;
  }
  .auth button:hover { background: #b8451a; }
  .stats {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(140px, 1fr));
    gap: 0;
    margin-bottom: 24px;
    border: 1px solid var(--line);
    background: var(--paper);
  }
  .stat {
    padding: 16px 20px;
    border-right: 1px solid var(--line);
  }
  .stat:last-child { border-right: none; }
  .stat-num {
    font-size: 22px;
    font-weight: 700;
    font-variant-numeric: tabular-nums;
  }
  .stat-label {
    font-size: 11px;
    text-transform: uppercase;
    letter-spacing: 0.08em;
    color: var(--dim);
    margin-top: 2px;
  }
  table {
    width: 100%;
    border-collapse: collapse;
    background: var(--paper);
    border: 1px solid var(--line);
  }
  th, td {
    text-align: left;
    padding: 10px 14px;
    font-size: 13px;
    border-bottom: 1px solid var(--line);
    vertical-align: top;
  }
  th { font-size: 11px; text-transform: uppercase; letter-spacing: 0.08em; color: var(--dim); font-weight: 600; }
  tr:last-child td { border-bottom: none; }
  .empty {
    text-align: center;
    padding: 40px 0;
    color: var(--dim);
    font-size: 14px;
  }
  .chip {
    display: inline-block;
    padding: 2px 8px;
    background: var(--bg);
    border: 1px solid var(--line);
    border-radius: 3px;
    font-size: 12px;
    margin: 1px 2px 1px 0;
  }
  .channel-id { font-weight: 700; }
  .err {
    color: var(--warn);
    font-size: 12px;
    margin-bottom: 8px;
  }
  footer { margin-top: 32px; color: var(--dim); font-size: 12px; }
  footer a { color: var(--dim); }
</style>
</head>
<body>
<div class="wrap">
  <header>
    <div class="logo">
      <svg viewBox="0 0 32 32" aria-hidden="true">
        <rect width="32" height="32" rx="6" fill="#1a1a1a"/>
        <path d="M 9 7 Q 16 4 23 7" stroke="#d6541f" stroke-width="1.5" fill="none" stroke-linecap="round"/>
        <ellipse cx="11" cy="14" rx="2" ry="3" fill="#f4ede0" transform="rotate(-15 11 14)"/>
        <ellipse cx="21" cy="14" rx="2" ry="3" fill="#f4ede0" transform="rotate(15 21 14)"/>
        <ellipse cx="16" cy="22" rx="8" ry="6.5" fill="#f4ede0"/>
        <circle cx="13" cy="21" r="1.2" fill="#1a1a1a"/>
        <circle cx="19" cy="21" r="1.2" fill="#1a1a1a"/>
        <ellipse cx="16" cy="25" rx="1.5" ry="1" fill="#d6541f"/>
      </svg>
      <span>rogerthat / admin</span>
    </div>
    <div class="updated" id="updated">—</div>
  </header>

  <div id="auth-gate" class="auth" hidden>
    <h2>Admin token required</h2>
    <p>Paste the admin token configured on this rogerthat instance. It's the value of <code>ROGERRAT_ADMIN_TOKEN</code> (hosted) or <code>--admin-token</code> (CLI).</p>
    <div id="auth-err" class="err"></div>
    <input id="auth-input" type="password" placeholder="admin token" autocomplete="off" />
    <button id="auth-submit">Unlock</button>
  </div>

  <div id="dashboard" hidden>
    <div class="stats">
      <div class="stat">
        <div class="stat-num" id="lt-channels">—</div>
        <div class="stat-label">channels (lifetime)</div>
      </div>
      <div class="stat">
        <div class="stat-num" id="lt-joins">—</div>
        <div class="stat-label">joins (lifetime)</div>
      </div>
      <div class="stat">
        <div class="stat-num" id="lt-messages">—</div>
        <div class="stat-label">messages (lifetime)</div>
      </div>
      <div class="stat">
        <div class="stat-num" id="active-channels">—</div>
        <div class="stat-label">channels open now</div>
      </div>
      <div class="stat">
        <div class="stat-num" id="active-agents">—</div>
        <div class="stat-label">agents online</div>
      </div>
    </div>

    <table>
      <thead>
        <tr>
          <th>Channel</th>
          <th>Retention</th>
          <th>Auth</th>
          <th>Trust</th>
          <th>Roster</th>
          <th>Msgs</th>
          <th>Opened</th>
          <th>Last activity</th>
        </tr>
      </thead>
      <tbody id="rows">
        <tr><td colspan="5" class="empty">Loading…</td></tr>
      </tbody>
    </table>
  </div>

  <footer>
    auto-refreshes every 5s · message content is never exposed by this page, only metadata · <a href="/">← landing</a>
  </footer>
</div>

<script>
  const KEY = 'rogerthat_admin_token';
  let token = sessionStorage.getItem(KEY) || '';
  const $ = (id) => document.getElementById(id);

  function fmtAgo(ts) {
    if (!ts) return '—';
    const s = Math.max(0, Math.floor((Date.now() - ts) / 1000));
    if (s < 60) return s + 's ago';
    if (s < 3600) return Math.floor(s / 60) + 'm ago';
    if (s < 86400) return Math.floor(s / 3600) + 'h ago';
    return Math.floor(s / 86400) + 'd ago';
  }

  async function load() {
    if (!token) { showAuthGate(); return; }
    try {
      const [statsR, chR] = await Promise.all([
        fetch('/api/stats', { headers: { Authorization: 'Bearer ' + token } }),
        fetch('/api/admin/channels', { headers: { Authorization: 'Bearer ' + token } }),
      ]);
      if (chR.status === 401) {
        sessionStorage.removeItem(KEY);
        token = '';
        showAuthGate('Invalid or expired token.');
        return;
      }
      const stats = await statsR.json();
      const data = await chR.json();
      renderStats(stats, data.channels);
      renderRows(data.channels);
      $('dashboard').hidden = false;
      $('auth-gate').hidden = true;
      $('updated').textContent = 'updated ' + new Date().toLocaleTimeString();
    } catch (e) {
      $('updated').textContent = 'error: ' + e.message;
    }
  }

  function renderStats(stats, channels) {
    $('lt-channels').textContent = stats.channels_created.toLocaleString();
    $('lt-joins').textContent = stats.joins_total.toLocaleString();
    $('lt-messages').textContent = stats.messages_total.toLocaleString();
    $('active-channels').textContent = channels.filter(c => c.agent_count > 0).length;
    $('active-agents').textContent = channels.reduce((sum, c) => sum + c.agent_count, 0);
  }

  function renderRows(channels) {
    const rows = $('rows');
    if (!channels.length) {
      rows.innerHTML = '<tr><td colspan="8" class="empty">No active channels yet.</td></tr>';
      return;
    }
    rows.innerHTML = channels.map(c => {
      const roster = c.roster.length
        ? c.roster.map(cs => '<span class="chip">' + esc(cs) + '</span>').join('')
        : '<span style="color:var(--dim)">empty</span>';
      const opened = c.first_joined_at ? fmtAgo(c.first_joined_at) : '—';
      const retColor = c.retention === 'full' ? '#d6541f' : c.retention === 'none' ? 'var(--dim)' : 'var(--ink)';
      const authLabel = 'token';
      const authColor = 'var(--dim)';
      const trust = c.trust_mode || 'untrusted';
      const trustColor = trust === 'trusted' ? '#d6541f' : 'var(--dim)';
      return '<tr>' +
        '<td class="channel-id">' + esc(c.id) + '</td>' +
        '<td><span style="color:' + retColor + '">' + esc(c.retention || 'none') + '</span></td>' +
        '<td><span style="color:' + authColor + '">' + authLabel + '</span></td>' +
        '<td><span style="color:' + trustColor + '">' + esc(trust) + '</span></td>' +
        '<td>' + roster + '</td>' +
        '<td>' + c.message_count + '</td>' +
        '<td>' + opened + '</td>' +
        '<td>' + fmtAgo(c.last_activity_at) + '</td>' +
      '</tr>';
    }).join('');
  }

  function esc(s) {
    return String(s).replace(/[&<>"']/g, ch => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[ch]));
  }

  function showAuthGate(errMsg) {
    $('dashboard').hidden = true;
    $('auth-gate').hidden = false;
    $('auth-err').textContent = errMsg || '';
    $('auth-input').focus();
  }

  $('auth-submit').addEventListener('click', () => {
    const v = $('auth-input').value.trim();
    if (!v) return;
    sessionStorage.setItem(KEY, v);
    token = v;
    $('auth-err').textContent = '';
    load();
  });
  $('auth-input').addEventListener('keydown', (e) => { if (e.key === 'Enter') $('auth-submit').click(); });

  load();
  setInterval(load, 5000);
</script>
</body>
</html>`;
}
