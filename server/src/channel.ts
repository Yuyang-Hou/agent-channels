/** Priority levels (ntfy-style). Senders mark messages so receivers can decide
 *  whether to wake up immediately, queue until later, or filter out. The server
 *  does NOT enforce semantics — receivers (listen-here, agents, webhook
 *  consumers) interpret. Default is omitted on the wire to save bytes; treat
 *  missing priority as "default". */
export type Priority = "min" | "low" | "default" | "high" | "urgent";

export const PRIORITY_RANK: Record<Priority, number> = {
  min: 0,
  low: 1,
  default: 2,
  high: 3,
  urgent: 4,
};

export function isPriority(v: unknown): v is Priority {
  return v === "min" || v === "low" || v === "default" || v === "high" || v === "urgent";
}

/** Inline attachment — base64-encoded bytes carried in the message itself.
 *  Designed for sporadic small images / PDFs (screenshots, photos, a quick
 *  reference doc) without introducing storage infra. For anything bigger
 *  than the cap, the sender should host externally and paste the URL. */
export type Attachment = {
  /** MIME type from the allowlist (see ATTACHMENT_MIME_ALLOWLIST). */
  mime: string;
  /** Base64-encoded bytes. Standard alphabet, padding optional. */
  data_base64: string;
  /** Optional display name. Trimmed to 128 chars. */
  filename?: string;
};

export const ATTACHMENT_MIME_ALLOWLIST = new Set([
  "image/jpeg",
  "image/png",
  "image/webp",
  "image/gif",
  "application/pdf",
]);

/** Per-message cap on TOTAL base64 size (sum across attachments). 512KB of
 *  base64 = ~384KB of raw bytes — enough for a screenshot or a small PDF.
 *  Worst case with ring buffer of 100 messages = 50MB RAM. */
export const MAX_ATTACHMENTS_BYTES_PER_MESSAGE = 512 * 1024;
export const MAX_ATTACHMENTS_PER_MESSAGE = 4;

/** Message kind. "message" (default, omitted on the wire) is normal content —
 *  persisted in the ring buffer, returned by history(). "status" is an
 *  ephemeral working/typing signal: delivered to whoever is listening RIGHT
 *  NOW, but never stored — it doesn't appear in history() and a peer that was
 *  offline when it fired simply never sees it. Use it for "received, give me
 *  a minute" acks so the other side's UI can show a loading indicator. */
export type MessageKind = "message" | "status";

export type Message = {
  id: number;
  from: string;
  /** Human-facing member nickname resolved from the authenticated member. */
  sender_name?: string;
  /** Authenticated channel member resolved from the credential-bound session. */
  sender_member_id: string;
  /** Stable server-derived endpoint for this member + callsign. Never client supplied. */
  sender_endpoint_id: string;
  to: string;
  text: string;
  at: number;
  /** Optional. Omitted on the wire = "message". See MessageKind. */
  kind?: MessageKind;
  /** Optional. Omitted on the wire = "default". Receivers interpret. */
  priority?: Priority;
  /** Optional. Up to 4 strings (max 64 chars each). Hint to the receiver's UI
   *  that these are reasonable canned replies — useful for human-in-the-loop
   *  channels (the /remote phone view renders them as tappable chips). Agent
   *  receivers can read them as `suggested_replies` and pick one, ignore, or
   *  reply freeform. The "click" is just a normal /send with that text. */
  suggested_replies?: string[];
  /** Optional. Up to 4 inline attachments, total ≤512KB base64. Designed for
   *  sporadic image/PDF uploads (screenshots, photos of an error) — anything
   *  larger should be hosted externally and pasted as a URL. */
  attachments?: Attachment[];
};

export type AuthenticatedSource = {
  memberId: string;
  endpointId: string;
  memberName?: string;
};

export const MAX_SUGGESTED_REPLIES = 4;
export const MAX_SUGGESTED_REPLY_LENGTH = 64;

/** Validate + normalize attachments. Returns the cleaned array (with filenames
 *  trimmed, base64 stripped of whitespace) or throws ChannelError. Returns
 *  undefined if input is undefined/empty (caller meant "no attachments"). */
export function validateAttachments(v: unknown): Attachment[] | undefined {
  if (v === undefined || v === null) return undefined;
  if (!Array.isArray(v)) {
    throw new ChannelError("attachments must be an array", "invalid", 400);
  }
  if (v.length === 0) return undefined;
  if (v.length > MAX_ATTACHMENTS_PER_MESSAGE) {
    throw new ChannelError(
      `attachments: max ${MAX_ATTACHMENTS_PER_MESSAGE} per message (got ${v.length})`,
      "invalid",
      400,
    );
  }
  const out: Attachment[] = [];
  let totalBytes = 0;
  for (let i = 0; i < v.length; i++) {
    const item = v[i];
    if (!item || typeof item !== "object" || Array.isArray(item)) {
      throw new ChannelError(`attachments[${i}]: must be an object`, "invalid", 400);
    }
    const rec = item as Record<string, unknown>;
    const mime = rec.mime;
    if (typeof mime !== "string" || !ATTACHMENT_MIME_ALLOWLIST.has(mime)) {
      throw new ChannelError(
        `attachments[${i}].mime: must be one of ${Array.from(ATTACHMENT_MIME_ALLOWLIST).join(", ")}`,
        "invalid",
        400,
      );
    }
    const dataRaw = rec.data_base64;
    if (typeof dataRaw !== "string" || dataRaw.length === 0) {
      throw new ChannelError(`attachments[${i}].data_base64: required string`, "invalid", 400);
    }
    // Strip whitespace from base64 (clients sometimes line-wrap).
    const data = dataRaw.replace(/\s+/g, "");
    if (!/^[A-Za-z0-9+/]+={0,2}$/.test(data)) {
      throw new ChannelError(
        `attachments[${i}].data_base64: not valid base64`,
        "invalid",
        400,
      );
    }
    totalBytes += data.length;
    if (totalBytes > MAX_ATTACHMENTS_BYTES_PER_MESSAGE) {
      throw new ChannelError(
        `attachments total base64 size exceeds ${MAX_ATTACHMENTS_BYTES_PER_MESSAGE} bytes; host externally and paste a URL instead`,
        "invalid",
        413,
      );
    }
    // Verify decodability (catches truncation that the regex misses).
    try {
      Buffer.from(data, "base64");
    } catch {
      throw new ChannelError(`attachments[${i}].data_base64: decode failed`, "invalid", 400);
    }
    const attachment: Attachment = { mime, data_base64: data };
    if (typeof rec.filename === "string") {
      const fn = rec.filename.trim().slice(0, 128);
      if (fn) attachment.filename = fn;
    }
    out.push(attachment);
  }
  return out;
}

/** Validate + normalize a suggested_replies array. Returns the cleaned array
 *  or throws a ChannelError describing what's wrong. Returns undefined if
 *  the input is undefined (the caller meant "no suggestions"). */
export function validateSuggestedReplies(v: unknown): string[] | undefined {
  if (v === undefined || v === null) return undefined;
  if (!Array.isArray(v)) {
    throw new ChannelError("suggested_replies must be an array of strings", "invalid", 400);
  }
  if (v.length === 0) return undefined; // empty array = same as omitted
  if (v.length > MAX_SUGGESTED_REPLIES) {
    throw new ChannelError(
      `suggested_replies: max ${MAX_SUGGESTED_REPLIES} entries (got ${v.length})`,
      "invalid",
      400,
    );
  }
  const out: string[] = [];
  for (const item of v) {
    if (typeof item !== "string") {
      throw new ChannelError("suggested_replies entries must all be strings", "invalid", 400);
    }
    const trimmed = item.trim();
    if (!trimmed) continue; // skip empty strings silently
    if (trimmed.length > MAX_SUGGESTED_REPLY_LENGTH) {
      throw new ChannelError(
        `suggested_replies entry too long (max ${MAX_SUGGESTED_REPLY_LENGTH} chars)`,
        "invalid",
        400,
      );
    }
    out.push(trimmed);
  }
  return out.length > 0 ? out : undefined;
}

type Listener = {
  resolve: (msgs: Message[]) => void;
  timer: NodeJS.Timeout;
};

const HISTORY_CAP = 100;
// Default idle TTL; channels can override via session_ttl_seconds at creation (max 24h).
const DEFAULT_ROSTER_IDLE_MS = 30 * 60 * 1000;
const EVICTION_TOMBSTONE_MS = 60 * 60 * 1000; // remember evicted sessions for 1h so we can return 410 instead of 400

export class ChannelError extends Error {
  constructor(
    message: string,
    public readonly code: "not_joined" | "session_expired" | "invalid" | "unauthorized" | "callsign_taken",
    public readonly status: number,
  ) {
    super(message);
  }
}

export class Channel {
  readonly id: string;
  private callsignBySession = new Map<string, string>();
  private sessionByCallsign = new Map<string, string>();
  private lastSeen = new Map<string, number>();
  private sourceBySession = new Map<string, AuthenticatedSource>();
  private messages: Message[] = [];
  // Per-callsign delivery cursor: last msg id delivered to that callsign. Persists across
  // session expiry so offline messages get delivered when the callsign rejoins.
  private cursorByCallsign = new Map<string, number>();
  // Every callsign that has joined the channel at least once. Used to allow DMing offline agents.
  private historicCallsigns = new Set<string>();
  private listenersBySession = new Map<string, Listener>();
  // Persistent stream listeners (SSE). Unlike long-poll listeners, these are NOT removed
  // after a single delivery — they keep receiving until the consumer explicitly detaches
  // or the session is evicted. Sessions with an active streamer also count as "alive"
  // for GC purposes, so a parked agent with an open SSE connection won't be reaped.
  private streamersBySession = new Map<string, (msg: Message) => void>();
  private evictedSessions = new Map<string, number>(); // sessionId -> evictedAt (tombstones)
  // Monotonic ID generator using current epoch time. Guarantees strict-increase
  // across restarts as long as the system clock doesn't go backwards.
  private nextMsgId: number = Date.now();
  private joinOrder: Array<{ callsign: string; joinedAt: number }> = [];
  firstJoinedAt: number | null = null;
  lastActivityAt: number = Date.now();
  /** Idle TTL in ms before sessions are GC'd. Settable per channel; defaults to 30 min. */
  sessionTtlMs: number = DEFAULT_ROSTER_IDLE_MS;

  constructor(id: string) {
    this.id = id;
  }

  private touch(sessionId: string) {
    const now = Date.now();
    this.lastSeen.set(sessionId, now);
    this.lastActivityAt = now;
  }

  gcRoster() {
    const now = Date.now();
    for (const [session, last] of this.lastSeen) {
      if (
        now - last > this.sessionTtlMs &&
        !this.listenersBySession.has(session) &&
        !this.streamersBySession.has(session)
      ) {
        this.evictSession(session);
      }
    }
    for (const [session, evictedAt] of this.evictedSessions) {
      if (now - evictedAt > EVICTION_TOMBSTONE_MS) this.evictedSessions.delete(session);
    }
  }

  private ensureJoined(sessionId: string): void {
    if (this.callsignBySession.has(sessionId)) return;
    if (this.evictedSessions.has(sessionId)) {
      throw new ChannelError(
        "session expired; call /join with the same callsign+token to refresh (session_id is reusable)",
        "session_expired",
        410,
      );
    }
    throw new ChannelError(
      "not joined to channel; call /join with {callsign, token} first",
      "not_joined",
      400,
    );
  }

  /**
   * Idempotent join.
   * - Same `(sessionId, callsign)` is a no-op (refreshes lastSeen).
   * - `opts.selfGenerated=true` means the caller has no prior identity (REST minted a UUID for
   *   them); if the callsign is already taken, we return the existing session_id so the caller
   *   can adopt it. Enables the "defensively re-join every turn" pattern.
   * - `opts.selfGenerated=false` (default) means the caller's sessionId IS their identity (MCP
   *   Mcp-Session-Id, or REST with X-Session-Id). If the callsign is taken by a *different*
   *   session, throws `callsign_taken` (409) rather than silently mapping them to someone
   *   else's session. Previous behavior silently broke send/listen for the conflicting caller.
   */
  join(
    sessionId: string,
    callsign: string,
    opts: { selfGenerated?: boolean; source?: AuthenticatedSource } = {},
  ): { sessionId: string; roster: string[]; history: Message[]; idempotent: boolean } {
    const normalized = callsign.trim().toLowerCase();
    if (!/^[a-z0-9][a-z0-9_-]{0,31}$/.test(normalized)) {
      throw new ChannelError(
        "callsign must be 1-32 chars, alphanumeric/underscore/dash, starting with letter or digit",
        "invalid",
        400,
      );
    }
    if (normalized === "all") {
      throw new ChannelError('callsign "all" is reserved for broadcast', "invalid", 400);
    }
    // Source and callsign form one identity binding. Validate the existing
    // session before touching either callsign map so a rejected cross-member
    // session reuse cannot rename or otherwise corrupt the victim session.
    const currentCallsign = this.callsignBySession.get(sessionId);
    const currentSource = this.sourceBySession.get(sessionId);
    if (currentSource) {
      if (!opts.source) {
        if (currentCallsign !== normalized) {
          throw new ChannelError(
            "authenticated session cannot change callsign without a matching source binding",
            "unauthorized",
            401,
          );
        }
      } else {
        if (currentSource.memberId !== opts.source.memberId) {
          throw new ChannelError("session belongs to a different authenticated member", "unauthorized", 401);
        }
        if (currentCallsign === normalized && currentSource.endpointId !== opts.source.endpointId) {
          throw new ChannelError("session endpoint does not match its authenticated callsign", "unauthorized", 401);
        }
      }
    }
    const existingSession = this.sessionByCallsign.get(normalized);
    let idempotent = false;
    const effectiveId = sessionId;
    if (existingSession) {
      if (existingSession === sessionId) {
        idempotent = true;
      } else if (opts.selfGenerated) {
        // Caller had no identity (REST minted a UUID for them) and the callsign is taken —
        // hand back the existing session_id so they can adopt it.
        const adoptedSource = this.sourceBySession.get(existingSession);
        if (opts.source && adoptedSource) {
          if (
            adoptedSource.memberId !== opts.source.memberId ||
            adoptedSource.endpointId !== opts.source.endpointId
          ) {
            throw new ChannelError("callsign belongs to a different authenticated endpoint", "unauthorized", 401);
          }
        }
        if (opts.source && !adoptedSource) this.sourceBySession.set(existingSession, opts.source);
        this.evictedSessions.delete(sessionId);
        this.touch(existingSession);
        return {
          sessionId: existingSession,
          roster: this.roster(),
          history: this.history(20),
          idempotent: true,
        };
      } else {
        throw new ChannelError(
          `callsign "${normalized}" is already in use on this channel; pick a different one or have the current holder leave first`,
          "callsign_taken",
          409,
        );
      }
    }
    const prevCallsign = this.callsignBySession.get(sessionId);
    if (prevCallsign && prevCallsign !== normalized) {
      this.sessionByCallsign.delete(prevCallsign);
      this.joinOrder = this.joinOrder.filter((a) => a.callsign !== prevCallsign);
    }
    this.callsignBySession.set(sessionId, normalized);
    this.sessionByCallsign.set(normalized, sessionId);
    if (opts.source) this.sourceBySession.set(sessionId, opts.source);
    this.evictedSessions.delete(sessionId);
    this.touch(sessionId);
    if (this.firstJoinedAt === null) this.firstJoinedAt = Date.now();
    // First time we see this callsign on this channel: cursor starts at 0 so all queued
    // offline messages to=callsign get delivered on the next listen. Subsequent joins
    // preserve the existing cursor so we don't re-deliver.
    if (!this.cursorByCallsign.has(normalized)) {
      this.cursorByCallsign.set(normalized, 0);
    }
    this.historicCallsigns.add(normalized);
    if (!this.joinOrder.some((a) => a.callsign === normalized)) {
      this.joinOrder.push({ callsign: normalized, joinedAt: Date.now() });
    }
    return { sessionId: effectiveId, roster: this.roster(), history: this.history(20), idempotent };
  }

  isCallsignOnline(callsign: string): boolean {
    if (callsign === "all") return true;
    return this.sessionByCallsign.has(callsign.trim().toLowerCase());
  }

  knowsCallsign(callsign: string): boolean {
    const cs = callsign.trim().toLowerCase();
    return cs === "all" || this.historicCallsigns.has(cs);
  }

  keepalive(sessionId: string): void {
    this.ensureJoined(sessionId);
    this.touch(sessionId);
  }

  bindAuthenticatedSource(
    sessionId: string,
    source: AuthenticatedSource,
  ): AuthenticatedSource {
    this.ensureJoined(sessionId);
    const existing = this.sourceBySession.get(sessionId);
    if (existing && (existing.memberId !== source.memberId || existing.endpointId !== source.endpointId)) {
      throw new ChannelError("session is already bound to a different authenticated endpoint", "unauthorized", 401);
    }
    this.sourceBySession.set(sessionId, source);
    return source;
  }

  private evictSession(sessionId: string) {
    const listener = this.listenersBySession.get(sessionId);
    if (listener) {
      clearTimeout(listener.timer);
      listener.resolve([]);
      this.listenersBySession.delete(sessionId);
    }
    // Drop any persistent stream listener too. The SSE handler detects the next
    // write failure (or its own abort signal) and closes the connection.
    this.streamersBySession.delete(sessionId);
    const cs = this.callsignBySession.get(sessionId);
    if (cs) {
      this.sessionByCallsign.delete(cs);
      this.joinOrder = this.joinOrder.filter((a) => a.callsign !== cs);
    }
    if (this.callsignBySession.has(sessionId)) {
      this.evictedSessions.set(sessionId, Date.now());
    }
    this.callsignBySession.delete(sessionId);
    this.sourceBySession.delete(sessionId);
    this.lastSeen.delete(sessionId);
    // Note: do NOT delete cursorByCallsign[cs] — keeps the offline-delivery pointer alive
    // so when this callsign rejoins, they get the messages queued for them while away.
  }

  leave(sessionId: string): void {
    this.evictSession(sessionId);
  }

  callsignOf(sessionId: string): string | undefined {
    return this.callsignBySession.get(sessionId);
  }

  resolveAddress(to: string): string {
    const trimmed = to.trim().toLowerCase();
    if (!trimmed) return "";
    if (trimmed === "all") return "all";
    const idxMatch = /^#?(\d+)$/.exec(trimmed);
    if (idxMatch) {
      const idx = Number.parseInt(idxMatch[1], 10);
      if (idx >= 1 && idx <= this.joinOrder.length) {
        return this.joinOrder[idx - 1].callsign;
      }
      return trimmed;
    }
    return trimmed;
  }

  sessionExists(sessionId: string): boolean {
    return this.callsignBySession.has(sessionId);
  }

  send(
    sessionId: string,
    to: string,
    text: string,
    priority?: Priority,
    suggestedReplies?: string[],
    attachments?: Attachment[],
    kind?: MessageKind,
  ): Message {
    this.ensureJoined(sessionId);
    const from = this.callsignBySession.get(sessionId)!;
    const source = this.sourceBySession.get(sessionId);
    if (!source) {
      throw new ChannelError("session has no authenticated source binding; rejoin the channel", "unauthorized", 401);
    }
    // Empty/missing `to` defaults to broadcast. Walkie-talkie physical default —
    // press-to-talk goes to everyone on the channel. Agents that omit the field
    // (a common first-call mistake) get sensible behavior instead of an error.
    const dest = this.resolveAddress(to) || "all";
    if (dest !== "all" && !this.sessionByCallsign.has(dest) && !this.historicCallsigns.has(dest)) {
      throw new ChannelError(
        `no callsign "${to}" has ever been on this channel (roster: ${this.rosterWithIndex().map((a) => `#${a.idx} ${a.callsign}`).join(", ") || "empty"}). DM to historic callsigns is supported — but they must have joined at least once.`,
        "invalid",
        400,
      );
    }
    if (typeof text !== "string") {
      throw new ChannelError("message text must be a string", "invalid", 400);
    }
    const isStatus = kind === "status";
    // A status signal is a note (e.g. "on it, ~1 min") — it always needs text,
    // and attachments / suggested_replies don't apply. Normal messages allow
    // empty text only when an attachment carries the payload.
    if (isStatus) {
      if (text.length === 0) {
        throw new ChannelError("status message requires text (e.g. 'received, working on it')", "invalid", 400);
      }
      if (text.length > 280) {
        throw new ChannelError("status message too long (max 280 chars — it's a short note, not content)", "invalid", 400);
      }
    } else {
      if (text.length === 0 && (!attachments || attachments.length === 0)) {
        throw new ChannelError("message text required (or send at least one attachment)", "invalid", 400);
      }
      if (text.length > 8192) {
        throw new ChannelError("message too long (max 8192 chars)", "invalid", 400);
      }
    }
    this.touch(sessionId);
    // Strictly-monotonic timestamp ID: at least one millisecond ahead of the prior id, and at
    // least the current wall clock. Survives restarts as long as the clock advances.
    const now = Date.now();
    this.nextMsgId = Math.max(now, this.nextMsgId + 1);
    const msg: Message = {
      id: this.nextMsgId,
      from,
      sender_name: source.memberName || from,
      sender_member_id: source.memberId,
      sender_endpoint_id: source.endpointId,
      to: dest,
      text,
      at: now,
    };
    if (isStatus) msg.kind = "status";
    // Only attach `priority` when explicitly non-default — keeps the wire format
    // backward-compatible for consumers that don't know about priorities.
    if (priority && priority !== "default") msg.priority = priority;
    // suggested_replies + attachments are content-message features — a status
    // ping is a bare note, so they're dropped even if passed.
    if (!isStatus && suggestedReplies && suggestedReplies.length > 0) {
      msg.suggested_replies = suggestedReplies;
    }
    if (!isStatus && attachments && attachments.length > 0) {
      msg.attachments = attachments;
    }
    // Status signals are ephemeral: delivered to whoever is listening right
    // now, but NOT stored — they never enter the ring buffer, so history()
    // stays clean and an offline peer simply misses the "working" note
    // (by the time it reconnects, the real reply is what matters).
    if (!isStatus) {
      this.messages.push(msg);
      if (this.messages.length > HISTORY_CAP) this.messages.shift();
    }
    this.notify(msg);
    return msg;
  }

  private notify(msg: Message) {
    for (const [session, listener] of [...this.listenersBySession]) {
      const cs = this.callsignBySession.get(session);
      if (!cs) continue;
      if (msg.from === cs) continue;
      if (msg.to !== "all" && msg.to !== cs) continue;
      this.listenersBySession.delete(session);
      clearTimeout(listener.timer);
      this.cursorByCallsign.set(cs, msg.id);
      listener.resolve([msg]);
    }
    // Persistent stream listeners (SSE). Not removed after delivery — keep firing.
    // Refresh the per-session lastSeen so streamers count as activity for GC.
    for (const [session, onMessage] of this.streamersBySession) {
      const cs = this.callsignBySession.get(session);
      if (!cs) continue;
      if (msg.from === cs) continue;
      if (msg.to !== "all" && msg.to !== cs) continue;
      this.cursorByCallsign.set(cs, msg.id);
      this.touch(session);
      try {
        onMessage(msg);
      } catch (err) {
        console.error(`[stream ${this.id}/${cs}] handler threw:`, err);
      }
    }
  }

  /**
   * Register a persistent listener for incoming messages addressed to this session's
   * callsign (DMs or broadcasts). Unlike `listen`, the listener is NOT removed after
   * a single delivery — the caller keeps receiving until they call the returned
   * cleanup function (or the session is evicted). Designed for SSE / WebSocket-style
   * push consumers.
   *
   * Callers typically want to call `drainSince(sessionId, since)` immediately after
   * registering, to flush any backlog the cursor was sitting on, then rely on this
   * listener for everything after.
   */
  addStreamListener(sessionId: string, onMessage: (msg: Message) => void): () => void {
    this.ensureJoined(sessionId);
    this.touch(sessionId);
    this.streamersBySession.set(sessionId, onMessage);
    return () => {
      if (this.streamersBySession.get(sessionId) === onMessage) {
        this.streamersBySession.delete(sessionId);
      }
    };
  }

  /**
   * Return any messages already in the buffer that this session's callsign hasn't
   * seen yet, and advance the per-callsign cursor past them. Same selection logic
   * as `listen()` but returns immediately (no long-poll). Use with `addStreamListener`
   * to bootstrap an SSE/streaming subscription without losing the backlog.
   */
  drainSince(sessionId: string, since?: number): Message[] {
    this.ensureJoined(sessionId);
    this.touch(sessionId);
    const cs = this.callsignBySession.get(sessionId)!;
    const cursor = since !== undefined ? since : (this.cursorByCallsign.get(cs) ?? 0);
    const pending = this.messages.filter(
      (m) => m.id > cursor && m.from !== cs && (m.to === "all" || m.to === cs),
    );
    if (pending.length > 0) {
      this.cursorByCallsign.set(cs, pending[pending.length - 1].id);
    }
    return pending;
  }

  /**
   * Long-poll for incoming messages.
   * - When `since` is undefined, returns messages newer than this session's per-session cursor
   *   (default behaviour, equivalent to a read pointer the server manages for you).
   * - When `since` is provided, returns messages with `id > since` regardless of the per-session
   *   cursor. Useful after a session expiry/restart to catch up reliably from a known id.
   */
  async listen(sessionId: string, timeoutMs: number, since?: number): Promise<Message[]> {
    this.ensureJoined(sessionId);
    this.touch(sessionId);
    const cs = this.callsignBySession.get(sessionId)!;
    // Per-callsign cursor → offline delivery: if alpha was offline, then someone sent to=alpha,
    // alpha rejoins, listen returns those messages because the cursor stayed at the last-delivered id.
    const cursor = since !== undefined ? since : (this.cursorByCallsign.get(cs) ?? 0);
    const pending = this.messages.filter(
      (m) => m.id > cursor && m.from !== cs && (m.to === "all" || m.to === cs),
    );
    if (pending.length > 0) {
      this.cursorByCallsign.set(cs, pending[pending.length - 1].id);
      return pending;
    }
    const existing = this.listenersBySession.get(sessionId);
    if (existing) {
      clearTimeout(existing.timer);
      existing.resolve([]);
      this.listenersBySession.delete(sessionId);
    }
    return new Promise<Message[]>((resolve) => {
      const timer = setTimeout(() => {
        this.listenersBySession.delete(sessionId);
        resolve([]);
      }, timeoutMs);
      this.listenersBySession.set(sessionId, { resolve, timer });
    });
  }

  roster(): string[] {
    return [...this.sessionByCallsign.keys()].sort();
  }

  rosterWithIndex(): Array<{ idx: number; callsign: string; joined_at: number }> {
    return this.joinOrder
      .filter((a) => this.sessionByCallsign.has(a.callsign))
      .map((a, i) => ({ idx: i + 1, callsign: a.callsign, joined_at: a.joinedAt }));
  }

  /**
   * Roster including historic (offline) callsigns with an `online` flag.
   * Useful for "show me everyone who's ever been on this channel" — and lets
   * a sender know who's currently reachable vs queued.
   */
  rosterAll(): Array<{ callsign: string; online: boolean; idx: number | null }> {
    const onlineIdx = new Map<string, number>();
    const onlineList = this.rosterWithIndex();
    for (const a of onlineList) onlineIdx.set(a.callsign, a.idx);
    const all = [...this.historicCallsigns];
    all.sort((a, b) => a.localeCompare(b));
    return all.map((cs) => ({
      callsign: cs,
      online: this.sessionByCallsign.has(cs),
      idx: onlineIdx.get(cs) ?? null,
    }));
  }

  history(n: number): Message[] {
    const clamped = Math.max(1, Math.min(HISTORY_CAP, Math.floor(n)));
    return this.messages.slice(-clamped);
  }

  size(): number {
    return this.callsignBySession.size;
  }
}

const channels = new Map<string, Channel>();

type SessionTtlLookup = (channelId: string) => number;
let sessionTtlLookup: SessionTtlLookup = () => DEFAULT_ROSTER_IDLE_MS;
export function setSessionTtlLookup(fn: SessionTtlLookup): void {
  sessionTtlLookup = fn;
}

export function getOrCreateChannel(id: string): Channel {
  let ch = channels.get(id);
  if (!ch) {
    ch = new Channel(id);
    ch.sessionTtlMs = sessionTtlLookup(id);
    channels.set(id, ch);
  }
  return ch;
}

let gcTimer: NodeJS.Timeout | null = null;
export function startPeriodicGc(intervalMs = 60_000): void {
  if (gcTimer) return;
  gcTimer = setInterval(() => {
    for (const ch of channels.values()) ch.gcRoster();
  }, intervalMs);
  gcTimer.unref?.();
}

export type ChannelSummary = {
  id: string;
  retention: string;
  trust_mode: string;
  roster: string[];
  agent_count: number;
  message_count: number;
  first_joined_at: number | null;
  last_activity_at: number;
};

export function listActiveChannels(
  retentionFor: (id: string) => string,
  trustModeFor: (id: string) => string,
): ChannelSummary[] {
  return [...channels.values()]
    .filter((c) => c.size() > 0 || c.firstJoinedAt !== null)
    .map((c) => ({
      id: c.id,
      retention: retentionFor(c.id),
      trust_mode: trustModeFor(c.id),
      roster: c.roster(),
      agent_count: c.size(),
      message_count: c.history(100).length,
      first_joined_at: c.firstJoinedAt,
      last_activity_at: c.lastActivityAt,
    }))
    .sort((a, b) => b.last_activity_at - a.last_activity_at);
}
