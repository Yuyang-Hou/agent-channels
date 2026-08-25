// `npx rogerthat listen-here` — turnkey SSE receiver.
//
// Opens a Server-Sent-Events connection to GET /api/channels/<id>/stream,
// keeps it alive indefinitely (outbound HTTPS — no inbound port, no tunnel),
// and on each delivered message either:
//   - executes a shell command with the message in env vars (--on-message),
//   - appends a JSON line to a file (--inbox), or
//   - prints to stdout (default).
//
// Designed so a parked agent (Claude Code or any turn-based harness) can keep
// receiving messages between operator turns at zero token cost. The agent calls
// the bootstrap MCP tool, gets back a one-line `receiver_command`, runs it
// detached via Bash, and lets the loop sit there waiting.
//
// Reconnect: exponential backoff (1s/3s/9s/27s, capped at 60s), reset after a
// healthy stream. On each reconnect the last seen message id is sent as `?since=`
// so the server replays anything that piled up while we were away.

import { spawn } from "node:child_process";
import { appendFileSync, existsSync, mkdirSync, writeFileSync } from "node:fs";
import { request as httpRequest, type IncomingMessage as HttpResponse } from "node:http";
import { request as httpsRequest } from "node:https";
import { basename, dirname, join } from "node:path";
import { parseArgs } from "node:util";
import type { MessageMention } from "./channel.js";
import { createCodexDelivery, parseCodexThreadId } from "./codex-turn.js";
import { DeliveryOutcomeUnknownError, type HostDelivery } from "./host-connector.js";
import { requestViaLocalApp, type LocalLedgerRequest } from "./reply-mcp.js";

const HELP = `rogerthat listen-here — open an SSE receiver for a channel

usage:
  rogerthat listen-here --channel <id> --token <t> --identity-key <k> [options]
  rogerthat listen-here --channel <id> --token <t> --session <sid> [options]
  rogerthat listen-here --channel <id> --secrets-stdin --identity-key <k> [options]

required:
  --channel <id>      channel id (returned by /join or create_channel)
  --token <t>         channel bearer token (legacy/manual CLI)
  --secrets-stdin     read one JSON object {"token":"...","ownerPassword":"..."}
                      from stdin, then close stdin; keeps secrets out of argv/env
  and ONE of:
  --identity-key <k>  auto-join the channel with this identity_key to obtain a
                      session (recommended — makes this command self-contained)
  --session <sid>     reuse an X-Session-Id you already got from /join

options:
  --owner-password <p>  passed to the auto-join so the session is marked
                        human-authorized (only meaningful with --identity-key)
  --origin <url>      RogerThat origin (default: https://rogerthat.chat)
  --since <msg_id>    resume from a known message id (skips per-session cursor)
  --on-message <cmd>  shell command to run for each delivered message; env vars
                      RR_MESSAGE, RR_FROM, RR_TO, RR_MSG_ID, RR_CHANNEL,
                      RR_PRIORITY, RR_REPLIES, RR_ATTACHMENTS are set
                      (RR_PRIORITY = "default" when omitted;
                       RR_REPLIES = tab-separated suggested replies, empty if none;
                       RR_ATTACHMENTS = tab-separated paths to inline attachment
                       files saved by listen-here, empty if none)
  --host-provider <p> Host Connector provider (currently: codex)
  --host-conversation <id>
                      inject each real message into this Host conversation.
                      Codex accepts a task id or codex://threads/<id> URL.
  --host-source-conversation <id>
                      trusted local source conversation used by Host-native
                      provenance UI; requires --host-conversation.
  --codex-socket <p>  override the ChatGPT Desktop IPC socket path (diagnostics)
  --channel-name <n>  display name used for {channel_name}; defaults to channel id
  --message-template <t>
                      render {channel_name}, {sender_name}, {message_source},
                      {message_text}, {mentions}, and {message_id} as the complete Host input
  --receive-scope <p> all_messages (default) or mentions_only
  --self-message-policy <p>
                      include_other_endpoints (default) or exclude_member;
                      the exact current task endpoint is always excluded
  --self-endpoint-id <id>
                      exact authenticated sender endpoint used by this task
  --self-member-id <id>
                      authenticated channel member used by exclude_member
  --app-socket <p>    private Pijoo App socket used to durably record a
                      message before Host delivery (requires --subscription-id)
  --subscription-id <uuid>
                      local Subscription id paired with --app-socket
  --status-json       emit machine-readable lifecycle lines to stderr prefixed
                      with "@pijoo "; received events contain message
                      text for the local App ledger, but never channel secrets
  --inbox <file>      append each message to this file (parent dir created if
                      missing). Format controlled by --format. When messages
                      carry inline attachments, the binaries are saved into a
                      sibling directory (e.g. '<inbox>-attachments/') and the
                      paths surface in the line (text format) or as a
                      'saved_paths' field (jsonl format) so the receiving
                      agent can Read them by path.
  --format <fmt>      output format for stdout and --inbox lines:
                        jsonl (default) — one JSON object per line: {id,from,to,text,at,priority?,suggested_replies?}
                        text            — one line per message:
                                          "[<priority>] [<from>] <text>  → [r1] [r2]"
                                          where [<priority>] and  → [r1] [r2] only appear
                                          when set. Newlines in text collapsed to spaces.
                                          Use this when feeding a Monitor/tail consumer
                                          so each line is a human-readable notification
                                          with no parser needed in the watcher.
  --min-priority <p>  drop messages below this priority (min|low|default|high|urgent).
                      Filtered messages do NOT write to --inbox, fire --on-message,
                      or print to stdout. Use for park-style channels: stay
                      wake-able only on real signals, let chatter accumulate silently.
  --heartbeat <secs>  write a "♥ alive" line to --inbox every <secs> seconds so an
                      operator/Monitor can confirm the relay is still up WITHOUT
                      consuming a real message. Off by default. Needs --inbox and
                      --format text. (Non-destructive alternative: poll /roster —
                      your callsign present = listener alive.)
  --quiet             suppress the default stdout dump of each message

if neither --on-message nor --inbox is given, messages print to stdout (one
line per message in the chosen --format).

NOTE: --on-message env vars (RR_MESSAGE, etc.) are always the raw structured
values regardless of --format. The format flag only affects what gets written
to stdout / --inbox.

cost: zero idle tokens. The process holds one long-lived HTTPS connection
to RogerThat and only fires --on-message when a real message arrives. Polling
agents pay tokens on every wake-up; this pays none.

examples:
  # Dump to a file the agent's Monitor tool can tail (human-readable lines):
  rogerthat listen-here --channel ch1 --token t --session s \\
    --inbox /tmp/rr.log --format text

  # Same, but JSONL for programmatic consumers:
  rogerthat listen-here --channel ch1 --token t --session s --inbox /tmp/rr.jsonl

  # Wake a parked Claude Code session each time a message arrives:
  rogerthat listen-here --channel ch1 --token t --session s \\
    --on-message 'claude -p "rogerthat msg from $RR_FROM: $RR_MESSAGE"'
`;

type Format = "jsonl" | "text";
type SelfMessagePolicy = "include_other_endpoints" | "exclude_member";
type ReceiveScope = "all_messages" | "mentions_only";

type Priority = "min" | "low" | "default" | "high" | "urgent";

const PRIORITY_RANK: Record<Priority, number> = {
  min: 0,
  low: 1,
  default: 2,
  high: 3,
  urgent: 4,
};

type Args = {
  channel: string;
  token: string;
  secretsStdin: boolean;
  /** X-Session-Id for the stream. Either passed directly via --session, or
   *  obtained automatically by joining with --identity-key (see runListenHere). */
  session: string;
  /** When --session is omitted, listen-here auto-joins the channel with this
   *  identity_key (+ optional --owner-password) to obtain a session_id. Makes
   *  the receiver command self-contained — no separate /join step / <SID>. */
  identityKey?: string;
  ownerPassword?: string;
  origin: string;
  since?: number;
  onMessage?: string;
  hostProvider?: string;
  hostConversation?: string;
  hostSourceConversation?: string;
  codexSocket?: string;
  channelName?: string;
  messageTemplate?: string;
  receiveScope: ReceiveScope;
  selfMessagePolicy: SelfMessagePolicy;
  selfEndpointId?: string;
  selfMemberId?: string;
  appSocket?: string;
  subscriptionId?: string;
  statusJson: boolean;
  inbox?: string;
  format: Format;
  quiet: boolean;
  /** When set, messages with priority below this threshold are silently
   *  dropped — they don't write to the inbox, don't fire --on-message, don't
   *  print. Useful for park-style channels: keep the listener wake-able only
   *  on real signals, let low-priority chatter accumulate silently. */
  minPriority?: Priority;
  /** Opt-in liveness heartbeat (seconds). When >0, writes a `♥ alive` line to
   *  the inbox every N seconds so an operator/Monitor can confirm the relay is
   *  still up WITHOUT consuming a real message (the non-destructive healthcheck
   *  the docs otherwise point at /roster for). Off by default to avoid noise. */
  heartbeat?: number;
};

function parseFlags(argv: string[]): Args | { help: true } | { error: string } {
  let parsed;
  try {
    parsed = parseArgs({
      args: argv,
      options: {
        channel: { type: "string" },
        token: { type: "string" },
        "secrets-stdin": { type: "boolean" },
        session: { type: "string" },
        "identity-key": { type: "string" },
        "owner-password": { type: "string" },
        origin: { type: "string" },
        since: { type: "string" },
        "on-message": { type: "string" },
        "host-provider": { type: "string" },
        "host-conversation": { type: "string" },
        "host-source-conversation": { type: "string" },
        "codex-socket": { type: "string" },
        "channel-name": { type: "string" },
        "message-template": { type: "string" },
        "receive-scope": { type: "string" },
        "self-message-policy": { type: "string" },
        "self-endpoint-id": { type: "string" },
        "self-member-id": { type: "string" },
        "app-socket": { type: "string" },
        "subscription-id": { type: "string" },
        "status-json": { type: "boolean" },
        inbox: { type: "string" },
        format: { type: "string" },
        "min-priority": { type: "string" },
        heartbeat: { type: "string" },
        quiet: { type: "boolean" },
        help: { type: "boolean", short: "h" },
      },
      strict: true,
      allowPositionals: false,
    });
  } catch (e) {
    return { error: (e as Error).message };
  }
  if (parsed.values.help) return { help: true };
  const channel = parsed.values.channel;
  const token = parsed.values.token;
  const session = parsed.values.session;
  const identityKey = parsed.values["identity-key"];
  const secretsStdin = parsed.values["secrets-stdin"] === true;
  if (!channel || (!token && !secretsStdin)) {
    return { error: "missing required flag(s): --channel and either --token or --secrets-stdin" };
  }
  if (token && secretsStdin) {
    return { error: "use only one of --token or --secrets-stdin" };
  }
  if (secretsStdin && parsed.values["owner-password"]) {
    return { error: "put ownerPassword in --secrets-stdin JSON instead of argv" };
  }
  // Either an explicit --session, or --identity-key to auto-join for one.
  if (!session && !identityKey) {
    return { error: "provide --session <sid> OR --identity-key <key> (auto-joins to get a session)" };
  }
  let since: number | undefined;
  if (parsed.values.since !== undefined) {
    const n = Number(parsed.values.since);
    if (!Number.isFinite(n)) return { error: "--since must be numeric" };
    since = n;
  }
  let format: Format = "jsonl";
  if (parsed.values.format !== undefined) {
    if (parsed.values.format !== "jsonl" && parsed.values.format !== "text") {
      return { error: "--format must be 'jsonl' or 'text'" };
    }
    format = parsed.values.format;
  }
  let minPriority: Priority | undefined;
  if (parsed.values["min-priority"] !== undefined) {
    const v = parsed.values["min-priority"];
    if (v !== "min" && v !== "low" && v !== "default" && v !== "high" && v !== "urgent") {
      return { error: "--min-priority must be one of min|low|default|high|urgent" };
    }
    minPriority = v;
  }
  let heartbeat: number | undefined;
  if (parsed.values.heartbeat !== undefined) {
    const n = Number(parsed.values.heartbeat);
    if (!Number.isFinite(n) || n <= 0) return { error: "--heartbeat must be a positive number of seconds" };
    heartbeat = n;
  }
  const selfMessagePolicy = parsed.values["self-message-policy"] ?? "include_other_endpoints";
  if (
    selfMessagePolicy !== "include_other_endpoints" && selfMessagePolicy !== "exclude_member"
  ) {
    return { error: "--self-message-policy must be include_other_endpoints|exclude_member" };
  }
  const receiveScope = parsed.values["receive-scope"] ?? "all_messages";
  if (receiveScope !== "all_messages" && receiveScope !== "mentions_only") {
    return { error: "--receive-scope must be all_messages|mentions_only" };
  }
  if (receiveScope === "mentions_only" && !parsed.values["self-member-id"]) {
    return { error: "--receive-scope mentions_only requires --self-member-id" };
  }
  const appSocket = parsed.values["app-socket"];
  const subscriptionId = parsed.values["subscription-id"];
  if (Boolean(appSocket) !== Boolean(subscriptionId)) {
    return { error: "--app-socket and --subscription-id must be provided together" };
  }
  if (subscriptionId && !/^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i.test(subscriptionId)) {
    return { error: "--subscription-id must be a UUID" };
  }
  const hostProvider = parsed.values["host-provider"];
  const hostConversation = parsed.values["host-conversation"];
  if (Boolean(hostProvider) !== Boolean(hostConversation)) {
    return { error: "--host-provider and --host-conversation must be provided together" };
  }
  if (appSocket && !hostConversation) {
    return { error: "--app-socket requires --host-conversation" };
  }
  return {
    channel,
    token: token ?? "",
    secretsStdin,
    session: session ?? "",
    identityKey,
    ownerPassword: parsed.values["owner-password"],
    origin: parsed.values.origin ?? "https://rogerthat.chat",
    since,
    onMessage: parsed.values["on-message"],
    hostProvider,
    hostConversation,
    hostSourceConversation: parsed.values["host-source-conversation"],
    codexSocket: parsed.values["codex-socket"],
    channelName: parsed.values["channel-name"],
    messageTemplate: parsed.values["message-template"],
    receiveScope,
    selfMessagePolicy,
    selfEndpointId: parsed.values["self-endpoint-id"],
    selfMemberId: parsed.values["self-member-id"],
    appSocket,
    subscriptionId,
    statusJson: parsed.values["status-json"] === true,
    inbox: parsed.values.inbox,
    format,
    quiet: parsed.values.quiet === true,
    minPriority,
    heartbeat,
  };
}

async function readSecretsFromStdin(
  input: AsyncIterable<string | Buffer>,
): Promise<{ token: string; ownerPassword?: string }> {
  let raw = "";
  for await (const chunk of input) {
    raw += String(chunk);
    if (Buffer.byteLength(raw) > 8 * 1024) throw new Error("secret input exceeds 8 KiB");
  }
  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch {
    throw new Error("--secrets-stdin expects one JSON object");
  }
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
    throw new Error("--secrets-stdin expects one JSON object");
  }
  const record = parsed as Record<string, unknown>;
  if (typeof record.token !== "string" || record.token.length === 0) {
    throw new Error("--secrets-stdin JSON requires a non-empty token");
  }
  if (record.ownerPassword !== undefined && typeof record.ownerPassword !== "string") {
    throw new Error("ownerPassword must be a string");
  }
  return {
    token: record.token,
    ...(typeof record.ownerPassword === "string" && record.ownerPassword
      ? { ownerPassword: record.ownerPassword }
      : {}),
  };
}

function emitStatus(args: Args, state: string, details: Record<string, unknown> = {}): void {
  if (!args.statusJson) return;
  console.error(`@pijoo ${JSON.stringify({ state, ...details })}`);
}

const BASE_RECONNECT_DELAY_MS = 1_000;
const HEALTHY_STREAM_MS = 60_000;
const RAILWAY_STREAM_ROTATION_MS = 14 * 60_000;

function headerValue(response: HttpResponse, name: string): string | undefined {
  const value = response.headers[name];
  return Array.isArray(value) ? value[0] : value;
}

function errorDiagnosticFields(error: unknown): Record<string, unknown> {
  const record = error && typeof error === "object" ? error as Record<string, unknown> : undefined;
  const cause = record?.cause && typeof record.cause === "object"
    ? record.cause as Record<string, unknown>
    : undefined;
  return {
    errorCode: record?.code,
    causeCode: cause?.code,
    syscall: record?.syscall ?? cause?.syscall,
  };
}

function formatConnectionDiagnostic(fields: Record<string, unknown>): string {
  const keys: Array<[string, string]> = [
    ["reason", "reason"],
    ["stage", "stage"],
    ["connectedMs", "connected_ms"],
    ["delayMs", "delay_ms"],
    ["errorCode", "error_code"],
    ["causeCode", "cause_code"],
    ["syscall", "syscall"],
    ["requestId", "request_id"],
    ["railwayEdge", "railway_edge"],
    ["railwayZone", "railway_zone"],
  ];
  return keys.flatMap(([key, label]) => {
    const value = fields[key];
    if (typeof value !== "string" && typeof value !== "number") return [];
    const safe = String(value).replace(/[\t\r\n]+/g, " ").trim().slice(0, 200);
    return safe ? [`${label}=${safe}`] : [];
  }).join(" ");
}

export function planReconnect(
  backoffMs: number,
  connectedMs: number | undefined,
  railway: boolean,
  reason: string,
): { waitMs: number; nextBackoffMs: number; expectedRotation: boolean } {
  const waitMs = connectedMs !== undefined && connectedMs >= HEALTHY_STREAM_MS
    ? BASE_RECONNECT_DELAY_MS
    : backoffMs;
  return {
    waitMs,
    nextBackoffMs: Math.min(60_000, Math.floor(waitMs * 3)),
    expectedRotation: railway && connectedMs !== undefined && connectedMs >= RAILWAY_STREAM_ROTATION_MS &&
      (reason === "stream_error" || reason === "stream_closed"),
  };
}

/** Mirror of the channel.ts Attachment shape on the wire. data_base64 is the
 *  raw base64 payload (no `data:` prefix). filename is optional and may be
 *  absent on programmatically-generated attachments. */
type WireAttachment = {
  mime: string;
  data_base64: string;
  filename?: string;
};

type IncomingMessage = {
  id: number;
  from: string;
  sender_name?: string;
  source?: {
    provider: string;
    conversation_id?: string;
    label?: string;
  };
  sender_member_id: string;
  sender_endpoint_id: string;
  to: string;
  text: string;
  at: number;
  mention?: MessageMention;
  /** "status" = ephemeral working/typing signal (not real content). */
  kind?: "message" | "status";
  priority?: Priority;
  suggested_replies?: string[];
  attachments?: WireAttachment[];
};

/** Sanitize a filename for use on disk: strip path separators, NUL, leading
 *  dots, and cap length. Empty input → a placeholder. */
function safeBaseName(name: string): string {
  const cleaned = name.replace(/[/\\\0]/g, "_").replace(/^\.+/, "").slice(0, 96).trim();
  return cleaned || "attachment";
}

/** Save attachments to disk alongside the inbox file. Returns the saved file
 *  paths (in attachment order). Without --inbox we have no directory context,
 *  so skip the save and return an empty list — the line still surfaces
 *  metadata so the agent knows something arrived.
 *
 *  Layout: if inbox is `/tmp/rr-X.log`, attachments go in
 *  `/tmp/rr-X-attachments/<msg_id>-<idx>-<safe_filename>`. This puts the
 *  binaries next to the line that announces them so an agent monitoring the
 *  inbox via tail can Read them by path directly. */
function saveAttachments(
  args: Args,
  msg: IncomingMessage,
): string[] {
  if (!args.inbox || !msg.attachments || msg.attachments.length === 0) return [];
  // Strip a trailing extension so `/tmp/rr-X.log` → `/tmp/rr-X-attachments`.
  const inboxDir = dirname(args.inbox);
  const inboxBase = basename(args.inbox).replace(/\.[^.]+$/, "");
  const attDir = join(inboxDir, `${inboxBase}-attachments`);
  try {
    if (!existsSync(attDir)) mkdirSync(attDir, { recursive: true, mode: 0o700 });
  } catch (err) {
    console.error(`[listen-here] failed to create attachment dir ${attDir}:`, (err as Error).message);
    return [];
  }
  const saved: string[] = [];
  for (let i = 0; i < msg.attachments.length; i++) {
    const att = msg.attachments[i];
    const safeName = safeBaseName(att.filename ?? `att-${i}`);
    const path = join(attDir, `${msg.id}-${i}-${safeName}`);
    try {
      writeFileSync(path, Buffer.from(att.data_base64, "base64"), { mode: 0o600 });
      saved.push(path);
    } catch (err) {
      console.error(`[listen-here] failed to save attachment ${path}:`, (err as Error).message);
    }
  }
  return saved;
}

/** Yield one SSE block (the lines between two blank-line separators) at a time.
 *  Takes a Node IncomingMessage rather than a Fetch-style ReadableStream so we
 *  don't need global `fetch` — listen-here must run on Node 16, which lacks
 *  it. IncomingMessage is async-iterable since Node 10. */
async function* readSseBlocks(body: HttpResponse): AsyncGenerator<string> {
  body.setEncoding("utf8");
  let buffer = "";
  for await (const chunk of body as AsyncIterable<string>) {
    buffer += chunk;
    let idx;
    while ((idx = buffer.indexOf("\n\n")) !== -1) {
      const block = buffer.slice(0, idx);
      buffer = buffer.slice(idx + 2);
      if (block.length > 0) yield block;
    }
  }
  if (buffer.length > 0) yield buffer;
}

function parseSseBlock(block: string): { event: string; data: string } | null {
  let event = "";
  const dataLines: string[] = [];
  for (const line of block.split("\n")) {
    if (line.startsWith(":")) continue; // comment / heartbeat
    if (line.startsWith("event: ")) event = line.slice(7);
    else if (line.startsWith("data: ")) dataLines.push(line.slice(6));
  }
  if (!event && dataLines.length === 0) return null;
  return { event: event || "message", data: dataLines.join("\n") };
}

function formatLine(args: Args, msg: IncomingMessage, savedPaths: string[]): string {
  if (args.format === "text") {
    // Collapse any newlines in the body so Monitor/tail consumers get exactly
    // one notification per message. Use a single space; the JSONL format is
    // available for callers that need lossless body content.
    const flat = msg.text.replace(/\r?\n/g, " ").trim();
    // Status signals get a distinct ⏳ marker so a Monitor/tail consumer (or
    // the agent reading the line) can tell "peer is working" apart from real
    // content — and grep it out if it only wants substantive messages.
    if (msg.kind === "status") {
      return `⏳ [${msg.from}] (working) ${flat}`;
    }
    // Surface non-default priority as a leading tag so a Monitor tail of the
    // inbox file can grep for urgency without parsing JSON. e.g. `[urgent] `
    const prio = msg.priority && msg.priority !== "default" ? `[${msg.priority}] ` : "";
    // Surface suggested_replies as a trailing  → [yes] [no]  hint so the
    // agent sees the canned options without parsing JSON.
    const replies =
      msg.suggested_replies && msg.suggested_replies.length > 0
        ? "  → " + msg.suggested_replies.map((r) => `[${r}]`).join(" ")
        : "";
    // Surface attachment paths so the agent can Read them directly. The 📎
    // marker keeps it easy to grep for. Without --inbox we never saved any
    // files, but we still announce that attachments arrived so the agent
    // can fall back to the JSONL stream or `history` over MCP to fetch them.
    let attTag = "";
    if (savedPaths.length > 0) {
      attTag = "  📎 " + savedPaths.join(", ");
    } else if (msg.attachments && msg.attachments.length > 0) {
      const summary = msg.attachments
        .map((a) => `${a.mime}${a.filename ? ` "${a.filename}"` : ""}`)
        .join(", ");
      attTag = `  📎 (${msg.attachments.length} inline, not saved: ${summary})`;
    }
    return `${prio}[${msg.from}] ${flat}${replies}${attTag}`;
  }
  // JSONL: pass the wire shape through, plus saved_paths so a jq consumer can
  // pick the on-disk locations without re-base64-decoding the body.
  if (savedPaths.length > 0) {
    return JSON.stringify({ ...msg, saved_paths: savedPaths });
  }
  return JSON.stringify(msg);
}

/** Append a raw status line to the inbox file (if --inbox is set). Used for the
 *  relay's own health signals — connect / reconnect notices — so an agent's
 *  Monitor (a `tail -F` of the inbox) sees a confirmation that the listener is
 *  actually attached, instead of having to inspect `ps`/`ss` to tell a healthy
 *  relay from a crashed one. Written even under --quiet: quiet silences stdout,
 *  not the inbox's own heartbeat. The `⟲` marker keeps it greppable/skippable.
 *  Best-effort — a failed append must never take the relay down. */
function writeInboxStatus(args: Args, text: string): void {
  if (!args.inbox) return;
  // Only in text mode. JSONL consumers parse each line (or the whole file) as
  // JSON, so a bare `⟲ …` line would break them — they get message objects only.
  if (args.format !== "text") return;
  try {
    const dir = dirname(args.inbox);
    if (dir && !existsSync(dir)) mkdirSync(dir, { recursive: true });
    appendFileSync(args.inbox, `⟲ [listen-here] ${text}\n`, { mode: 0o600 });
  } catch {
    /* never let a health-line write kill the relay */
  }
}

async function recordWithApp(
  args: Args,
  operation: "record_received" | "record_outcome",
  event: LocalLedgerRequest["event"],
): Promise<"recorded" | "already_processed" | "unresolved"> {
  if (!args.appSocket || !args.subscriptionId || !args.hostProvider || !args.hostConversation) return "recorded";
  const result = await requestViaLocalApp(args.appSocket, {
    version: 2,
    operation,
    source: {
      provider: args.hostProvider,
      conversationId: args.hostProvider === "codex"
        ? parseCodexThreadId(args.hostConversation)
        : args.hostConversation,
    },
    channel: args.channel,
    subscription_id: args.subscriptionId,
    event,
  }, 5_000);
  if (!result.ok) throw new Error(result.error);
  const message = result.result.message;
  return message === "already_processed" || message === "unresolved" ? message : "recorded";
}

async function dispatch(args: Args, msg: IncomingMessage, hostDelivery?: HostDelivery): Promise<void> {
  // --min-priority filter: drop messages below the threshold entirely (no
  // inbox write, no hook spawn, no stdout). Missing priority counts as
  // "default" (rank 2).
  if (args.minPriority) {
    const incomingRank = PRIORITY_RANK[msg.priority ?? "default"];
    if (incomingRank < PRIORITY_RANK[args.minPriority]) return;
  }
  if (!msg.sender_member_id || !msg.sender_endpoint_id) {
    throw new Error(`message ${msg.id} is missing authenticated sender identity`);
  }
  const senderName = msg.sender_name?.trim() || msg.from;
  if (msg.kind !== "status") {
    const ledgerResult = await recordWithApp(args, "record_received", {
      id: msg.id,
      from: msg.from,
      sender_name: senderName,
      source: msg.source,
      mention: msg.mention,
      to: msg.to,
      text: msg.text,
      at: msg.at,
      sender_member_id: msg.sender_member_id,
      sender_endpoint_id: msg.sender_endpoint_id,
      state: "received",
    });
    if (ledgerResult === "already_processed") return;
    if (ledgerResult === "unresolved") {
      throw new DeliveryOutcomeUnknownError(`App reported unresolved delivery for message ${msg.id}`);
    }
    emitStatus(args, "received", {
      message: {
        channel: args.channel,
        id: msg.id,
        from: senderName,
        to: msg.to,
        text: msg.text,
        at: msg.at,
        ...(msg.priority ? { priority: msg.priority } : {}),
        ...(msg.attachments?.length
          ? {
              attachments: msg.attachments.map((attachment) => ({
                mime: attachment.mime,
                ...(attachment.filename ? { filename: attachment.filename } : {}),
              })),
            }
          : {}),
      },
    });
  }
  const filteredSelfMessage =
    args.selfEndpointId === msg.sender_endpoint_id ||
    (args.selfMessagePolicy === "exclude_member" &&
      Boolean(args.selfMemberId) &&
      args.selfMemberId === msg.sender_member_id);
  if (filteredSelfMessage) {
    await recordWithApp(args, "record_outcome", { id: msg.id, state: "filtered", error: "self_message" });
    emitStatus(args, "filtered", { messageId: msg.id, reason: args.selfMessagePolicy });
    return;
  }
  const mentionedSelf = msg.mention?.kind === "all" || (
    msg.mention?.kind === "members" &&
    msg.mention.members.some((member) => member.member_id === args.selfMemberId)
  );
  if (args.receiveScope === "mentions_only" && !mentionedSelf) {
    await recordWithApp(args, "record_outcome", {
      id: msg.id,
      state: "filtered",
      error: "mention_not_matched",
    });
    emitStatus(args, "filtered", { messageId: msg.id, reason: "mention_not_matched" });
    return;
  }
  if (hostDelivery && msg.kind !== "status") {
    await recordWithApp(args, "record_outcome", { id: msg.id, state: "attempting" });
    let receipt;
    try {
      receipt = await hostDelivery({
        channelId: args.channel,
        messageId: msg.id,
        from: senderName,
        source: msg.source ? {
          provider: msg.source.provider,
          conversationId: msg.source.conversation_id,
          label: msg.source.label,
        } : undefined,
        text: msg.text,
        mention: msg.mention,
        receivedAt: msg.at,
        untrusted: true,
      });
    } catch (error) {
      const unknown = error instanceof DeliveryOutcomeUnknownError;
      try {
        await recordWithApp(args, "record_outcome", {
          id: msg.id,
          state: unknown ? "unknown" : "failed",
          error: (error as Error).message,
        });
      } catch {
        // The original Host result remains authoritative. A failed ledger ACK
        // cannot make an uncertain mutation safe to replay.
      }
      throw error;
    }
    if (!args.quiet) {
      const deliveryId = receipt.providerDeliveryId ? ` interaction ${receipt.providerDeliveryId}` : "";
      console.error(`[listen-here] delivered message ${msg.id} to ${receipt.provider}${deliveryId}`);
    }
    try {
      await recordWithApp(args, "record_outcome", { id: msg.id, state: "delivered" });
    } catch (error) {
      throw new DeliveryOutcomeUnknownError(
        `Host accepted message ${msg.id}, but the App could not record the receipt: ${(error as Error).message}`,
      );
    }
    emitStatus(args, "delivered", { messageId: msg.id, provider: receipt.provider });
  }
  // Save inline attachments to disk (alongside the inbox) BEFORE writing the
  // line, so the path the line announces actually exists when the agent's
  // Monitor tool fires on the new tail entry.
  const savedPaths = saveAttachments(args, msg);
  const line = formatLine(args, msg, savedPaths);
  if (args.inbox) {
    const dir = dirname(args.inbox);
    if (dir && !existsSync(dir)) mkdirSync(dir, { recursive: true });
    appendFileSync(args.inbox, line + "\n", { mode: 0o600 });
  }
  if (!args.inbox && !args.onMessage && !args.quiet) {
    process.stdout.write(line + "\n");
  }
  if (args.onMessage) {
    // child stdio inherits so the agent can see whatever the hook prints.
    // We DON'T await — the hook can be slow (e.g. `claude -p ...`); we want
    // to keep consuming the SSE stream in parallel so backed-up messages
    // don't block live ones. The shell command can itself sequence if needed.
    const child = spawn(args.onMessage, {
      shell: true,
      stdio: "inherit",
      env: {
        ...process.env,
        RR_MESSAGE: msg.text,
        RR_FROM: msg.from,
        RR_TO: msg.to,
        RR_MSG_ID: String(msg.id),
        RR_CHANNEL: args.channel,
        RR_PRIORITY: msg.priority ?? "default",
        // Tab-separated so the hook can split on $'\t' cleanly even if a reply
        // contains spaces or punctuation. Empty string when no suggestions.
        RR_REPLIES: (msg.suggested_replies ?? []).join("\t"),
        // Tab-separated paths to inline attachments saved to disk. Empty
        // string when no attachments arrived OR when --inbox wasn't set (no
        // directory context to save into).
        RR_ATTACHMENTS: savedPaths.join("\t"),
      },
    });
    child.on("error", (err) => {
      console.error(`[listen-here] --on-message spawn failed:`, err.message);
    });
  }
}

/** Issue a GET request and return the IncomingMessage. We use node:https/http
 *  directly (instead of global `fetch`) so listen-here works on Node 16. */
function openHttpStream(
  url: URL,
  headers: Record<string, string>,
  abortSignal: AbortSignal,
): Promise<HttpResponse> {
  return new Promise((resolve, reject) => {
    const reqFn = url.protocol === "https:" ? httpsRequest : httpRequest;
    const req = reqFn(
      {
        method: "GET",
        host: url.hostname,
        port: url.port ? Number(url.port) : url.protocol === "https:" ? 443 : 80,
        path: url.pathname + url.search,
        headers,
      },
      (res) => resolve(res),
    );
    req.on("error", reject);
    if (abortSignal.aborted) {
      req.destroy();
      reject(new Error("AbortError: signal was already aborted"));
      return;
    }
    const onAbort = () => {
      req.destroy();
      reject(new Error("AbortError"));
    };
    abortSignal.addEventListener("abort", onAbort, { once: true });
    req.end();
  });
}

/** Open one SSE connection and consume events until it closes. Returns the last
 *  seen message id (so the reconnect loop can resume from there) and the reason
 *  the connection ended ("aborted" for user-initiated, "ended" for network/server). */
async function runOneConnection(
  args: Args,
  sinceCursor: number | undefined,
  abortSignal: AbortSignal,
  hostDelivery?: HostDelivery,
): Promise<{
  lastId: number | undefined;
  reason: "aborted" | "ended" | "delivery-uncertain";
  statusError?: number;
  connectedMs?: number;
  railway?: boolean;
  reconnectReason?: string;
  diagnostics?: Record<string, unknown>;
}> {
  const url = new URL(`${args.origin.replace(/\/$/, "")}/api/channels/${args.channel}/stream`);
  if (sinceCursor !== undefined) url.searchParams.set("since", String(sinceCursor));
  let res: HttpResponse;
  try {
    res = await openHttpStream(
      url,
      {
        authorization: `Bearer ${args.token}`,
        "x-session-id": args.session,
        "x-railway-debug": "pijoo",
        accept: "text/event-stream",
      },
      abortSignal,
    );
  } catch (err) {
    if (abortSignal.aborted) return { lastId: sinceCursor, reason: "aborted" };
    throw err;
  }
  const status = res.statusCode ?? 0;
  if (status < 200 || status >= 300) {
    // Drain so the socket is freed.
    res.resume();
    return { lastId: sinceCursor, reason: "ended", statusError: status, reconnectReason: "http_status" };
  }
  const connectedAt = Date.now();
  const diagnostics = {
    requestId: headerValue(res, "x-railway-request-id"),
    railwayEdge: headerValue(res, "x-railway-edge"),
    railwayZone: headerValue(res, "x-railway-upstream-zone"),
  };
  const railway = Boolean(diagnostics.requestId || diagnostics.railwayEdge || diagnostics.railwayZone);
  // SSE handshake accepted → the relay is genuinely attached and will receive
  // phone messages from here on. Announce it in the inbox so the agent's Monitor
  // confirms "listening" without a manual selftest, and the operator's phone
  // sees a peer come online. (See writeInboxStatus.)
  writeInboxStatus(
    args,
    `● connected — listening on ${args.channel} as session ${(args.session ?? "").slice(0, 8)}…`,
  );
  emitStatus(args, "connected", {
    channel: args.channel,
    diagnostic: formatConnectionDiagnostic({ stage: "connected", ...diagnostics }),
  });
  let lastId = sinceCursor;
  const finish = (
    reason: "aborted" | "ended" | "delivery-uncertain",
    reconnectReason?: string,
    extraDiagnostics: Record<string, unknown> = {},
  ) => ({
    lastId,
    reason,
    connectedMs: Date.now() - connectedAt,
    railway,
    reconnectReason,
    diagnostics: { ...diagnostics, ...extraDiagnostics },
  });
  // If the operator aborts mid-stream, destroy() the response to unblock the
  // for-await on it.
  const onAbort = () => res.destroy();
  abortSignal.addEventListener("abort", onAbort, { once: true });
  try {
    for await (const block of readSseBlocks(res)) {
      if (abortSignal.aborted) return finish("aborted");
      const parsed = parseSseBlock(block);
      if (!parsed) continue;
      if (parsed.event === "message") {
        let msg: IncomingMessage;
        try {
          msg = JSON.parse(parsed.data);
        } catch {
          continue;
        }
        try {
          await dispatch(args, msg, hostDelivery);
          lastId = msg.id;
        } catch (err) {
          if (err instanceof DeliveryOutcomeUnknownError) {
            console.error(
              `[listen-here] delivery outcome unknown for message ${msg.id}; stopped without advancing the cursor to avoid an automatic duplicate: ${err.message}`,
            );
            emitStatus(args, "error", { kind: "delivery_outcome_unknown", messageId: msg.id });
            res.destroy();
            return finish("delivery-uncertain");
          }
          // The SSE server has already advanced its delivery cursor. Resume from
          // immediately before this message so a busy Host task cannot lose it.
          lastId ??= Math.max(0, msg.id - 1);
          console.error(`[listen-here] delivery error for message ${msg.id}:`, (err as Error).message);
          emitStatus(args, "error", { kind: "delivery", messageId: msg.id, error: (err as Error).message });
          res.destroy();
          return finish("ended", "delivery_error");
        }
      } else if (parsed.event === "error") {
        console.error(`[listen-here] server error:`, parsed.data);
      }
      // "hello" event ignored — we don't need the initial channel metadata
    }
  } catch (err) {
    if (abortSignal.aborted) return finish("aborted");
    const connectedMs = Date.now() - connectedAt;
    const extraDiagnostics = errorDiagnosticFields(err);
    const expectedRotation = planReconnect(1_000, connectedMs, railway, "stream_error").expectedRotation;
    const reconnectReason = expectedRotation ? "railway_request_limit" : "stream_error";
    const diagnostic = formatConnectionDiagnostic({
      reason: reconnectReason,
      stage: "stream",
      connectedMs,
      ...diagnostics,
      ...extraDiagnostics,
    });
    if (expectedRotation) {
      console.error(`[listen-here] Railway SSE request limit reached; reconnecting`);
    } else {
      console.error(`[listen-here] connection error:`, (err as Error).message);
      emitStatus(args, "error", { kind: "connection", error: (err as Error).message, diagnostic });
    }
    return finish("ended", reconnectReason, extraDiagnostics);
  } finally {
    abortSignal.removeEventListener("abort", onAbort);
  }
  const connectedMs = Date.now() - connectedAt;
  const expectedRotation = planReconnect(1_000, connectedMs, railway, "stream_closed").expectedRotation;
  return finish("ended", expectedRotation ? "railway_request_limit" : "stream_closed");
}

/** Auto-join the channel with an identity_key to obtain a session_id, so the
 *  receiver command can be a single self-contained line (no separate /join,
 *  no `<SID>` placeholder). Uses node:http/https directly (Node-16-safe, same
 *  as the SSE path). Returns the session_id or throws with a clear message. */
function joinForSession(args: Args): Promise<{ sessionId: string; memberId: string; endpointId: string }> {
  const url = new URL(`${args.origin.replace(/\/$/, "")}/api/channels/${args.channel}/join`);
  const payload = JSON.stringify({
    callsign: args.identityKey,
    ...(args.ownerPassword ? { owner_password: args.ownerPassword } : {}),
  });
  return new Promise((resolve, reject) => {
    const reqFn = url.protocol === "https:" ? httpsRequest : httpRequest;
    const req = reqFn(
      {
        method: "POST",
        host: url.hostname,
        port: url.port ? Number(url.port) : url.protocol === "https:" ? 443 : 80,
        path: url.pathname + url.search,
        headers: {
          authorization: `Bearer ${args.token}`,
          "content-type": "application/json",
          "content-length": Buffer.byteLength(payload),
          accept: "application/json",
        },
      },
      (res) => {
        let raw = "";
        res.setEncoding("utf8");
        res.on("data", (d) => (raw += d));
        res.on("end", () => {
          const status = res.statusCode ?? 0;
          let body: { session_id?: string; member_id?: string; endpoint_id?: string; error?: string } = {};
          try {
            body = JSON.parse(raw);
          } catch {
            /* leave empty */
          }
          if (status >= 200 && status < 300 && body.session_id && body.member_id && body.endpoint_id) {
            resolve({ sessionId: body.session_id, memberId: body.member_id, endpointId: body.endpoint_id });
          } else {
            reject(new Error(body.error || `join failed or returned no authenticated identity (HTTP ${status})`));
          }
        });
      },
    );
    req.on("error", reject);
    req.write(payload);
    req.end();
  });
}

export async function runListenHere(
  argv: string[],
  secretInput: AsyncIterable<string | Buffer> = process.stdin,
): Promise<number> {
  const parsed = parseFlags(argv);
  if ("help" in parsed) {
    console.log(HELP);
    return 0;
  }
  if ("error" in parsed) {
    console.error(`error: ${parsed.error}\n`);
    console.error(HELP);
    return 2;
  }
  const args: Args = parsed;
  if (args.secretsStdin) {
    try {
      const secrets = await readSecretsFromStdin(secretInput);
      args.token = secrets.token;
      args.ownerPassword = secrets.ownerPassword;
    } catch (error) {
      console.error(`error: ${(error as Error).message}`);
      return 2;
    }
  }
  if (args.hostSourceConversation && !args.hostConversation) {
    console.error("error: --host-source-conversation requires --host-conversation");
    return 2;
  }
  let hostDelivery: HostDelivery | undefined;
  if (args.hostProvider && args.hostConversation) {
    try {
      if (args.hostProvider !== "codex") {
        throw new Error(`Unsupported Host provider: ${args.hostProvider}`);
      }
      hostDelivery = createCodexDelivery({
        threadId: args.hostConversation,
        sourceThreadId: args.hostSourceConversation,
        socketPath: args.codexSocket,
        channelName: args.channelName,
        messageTemplate: args.messageTemplate,
      });
    } catch (err) {
      console.error(`error: ${(err as Error).message}`);
      return (err as Error).message.startsWith("Codex Desktop IPC socket not found") ? 1 : 2;
    }
  }
  // No explicit --session? Auto-join with the identity_key to get one. This is
  // what makes the receiver command self-contained (no <SID> to fill in).
  if (!args.session) {
    try {
      const joined = await joinForSession(args);
      args.session = joined.sessionId;
      args.selfMemberId ??= joined.memberId;
      if (!args.quiet) console.error(`[listen-here] joined as session ${args.session.slice(0, 8)}…`);
      emitStatus(args, "joined", { session: args.session.slice(0, 8) });
    } catch (err) {
      console.error(`[listen-here] auto-join failed: ${(err as Error).message}`);
      emitStatus(args, "error", { kind: "join", error: (err as Error).message });
      return 1;
    }
  }
  const ac = new AbortController();
  const shutdown = (sig: NodeJS.Signals) => {
    if (!args.quiet) console.error(`[listen-here] received ${sig}, closing stream`);
    ac.abort();
  };
  const onSigint = () => shutdown("SIGINT");
  const onSigterm = () => shutdown("SIGTERM");
  process.once("SIGINT", onSigint);
  process.once("SIGTERM", onSigterm);
  let heartbeat: NodeJS.Timeout | undefined;
  const cleanup = () => {
    process.off("SIGINT", onSigint);
    process.off("SIGTERM", onSigterm);
    if (heartbeat) clearInterval(heartbeat);
  };
  // Opt-in liveness heartbeat: write a `♥ alive` line to the inbox every N
  // seconds so an operator/Monitor can confirm the relay is up WITHOUT consuming
  // a real message. .unref() so it never keeps the process alive on its own;
  // cleared with the process signal handlers when this listener exits.
  if (args.heartbeat) {
    heartbeat = setInterval(() => {
      writeInboxStatus(args, `♥ alive — session ${args.session.slice(0, 8)}… (still listening)`);
    }, args.heartbeat * 1000);
    heartbeat.unref?.();
  }
  if (!args.quiet) {
    console.error(`[listen-here] connecting to ${args.origin}/api/channels/${args.channel}/stream`);
  }
  emitStatus(args, "connecting", { channel: args.channel });
  let cursor = args.since;
  let backoffMs = BASE_RECONNECT_DELAY_MS;
  while (!ac.signal.aborted) {
    let result;
    try {
      result = await runOneConnection(args, cursor, ac.signal, hostDelivery);
    } catch (err) {
      if (ac.signal.aborted) {
        cleanup();
        return 0;
      }
      console.error(`[listen-here] connection error:`, (err as Error).message);
      const diagnostics = { stage: "handshake", ...errorDiagnosticFields(err) };
      emitStatus(args, "error", {
        kind: "connection",
        error: (err as Error).message,
        diagnostic: formatConnectionDiagnostic({ reason: "handshake_error", ...diagnostics }),
      });
      result = {
        lastId: cursor,
        reason: "ended" as const,
        reconnectReason: "handshake_error",
        diagnostics,
      };
    }
    if (result.lastId !== undefined) cursor = result.lastId;
    if (result.reason === "aborted") {
      cleanup();
      emitStatus(args, "stopped");
      return 0;
    }
    if (result.reason === "delivery-uncertain") {
      cleanup();
      emitStatus(args, "stopped", { reason: "delivery_outcome_unknown" });
      return 1;
    }
    if (result.statusError !== undefined) {
      const status = result.statusError;
      // 4xx (except 408/429) usually mean our SESSION is gone, not that our
      // creds are bad: a server restart wipes in-memory sessions AND tombstones,
      // so the stream returns 400 not_joined (or 410) for the session we held.
      // Our join creds are durable, so the robust move is to mint a FRESH
      // session and resume — a restart should be transparent, not fatal. Only
      // bail if we have no identity to re-join with, or the re-join itself fails
      // (that's a genuinely bad token / identity_key).
      if (status >= 400 && status < 500 && status !== 408 && status !== 429) {
        // Re-join needs the identity_key (joinForSession auto-joins with it). If
        // the listener was started with an explicit --session and no
        // --identity-key, we have nothing to re-join with → bail as before.
        if (!args.identityKey) {
          console.error(`[listen-here] server returned ${status} and no --identity-key to re-join with; exiting`);
          cleanup();
          emitStatus(args, "error", { kind: "session", status });
          return 1;
        }
        try {
          const joined = await joinForSession(args);
          args.session = joined.sessionId;
          args.selfMemberId ??= joined.memberId;
          if (!args.quiet) {
            console.error(`[listen-here] re-joined after ${status} as session ${args.session.slice(0, 8)}… — resuming`);
          }
        } catch (err) {
          console.error(`[listen-here] re-join after ${status} failed (${(err as Error).message}); exiting`);
          cleanup();
          emitStatus(args, "error", { kind: "rejoin", status, error: (err as Error).message });
          return 1;
        }
      } else {
        console.error(`[listen-here] server returned ${status} — will retry`);
      }
    }
    // Connection closed cleanly or with retryable error. Backoff then reconnect.
    if (ac.signal.aborted) {
      cleanup();
      return 0;
    }
    const plan = planReconnect(
      backoffMs,
      result.connectedMs,
      result.railway === true,
      result.reconnectReason ?? "stream_closed",
    );
    const wait = plan.waitMs;
    backoffMs = plan.nextBackoffMs;
    const reconnectReason = plan.expectedRotation
      ? "railway_request_limit"
      : result.reconnectReason ?? "stream_closed";
    const diagnostic = formatConnectionDiagnostic({
      reason: reconnectReason,
      connectedMs: result.connectedMs,
      delayMs: wait,
      ...result.diagnostics,
    });
    if (!args.quiet) {
      console.error(`[listen-here] reconnecting in ${wait}ms (cursor=${cursor ?? "none"})`);
    }
    emitStatus(args, "reconnecting", {
      delayMs: wait,
      cursor: cursor ?? null,
      reason: reconnectReason,
      diagnostic,
    });
    await new Promise<void>((resolve) => {
      const t = setTimeout(resolve, wait);
      ac.signal.addEventListener(
        "abort",
        () => {
          clearTimeout(t);
          resolve();
        },
        { once: true },
      );
    });
  }
  cleanup();
  emitStatus(args, "stopped");
  return 0;
}
