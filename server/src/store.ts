import { createHash, randomUUID } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { dirname } from "node:path";
import { generateChannelId, generateToken } from "./ids.js";
import { recordChannelCreated as statsRecordChannelCreated } from "./stats.js";
import { type Retention, isRetention, recordChannelCreated as transcriptRecordChannelCreated } from "./transcripts.js";

export type TrustMode = "untrusted" | "trusted";

export type ChannelRecord = {
  id: string;
  name: string;
  tokenHash: string;
  createdAt: number;
  retention: Retention;
  isBand: boolean;
  trustMode: TrustMode;
  /** Idle TTL in milliseconds before a session is GC'd. Default 30 min. Max 24 h. */
  sessionTtlMs: number;
  /**
   * Optional human-set secret used as proof-of-consent: when a peer joins with the matching
   * password, the agent is told "the human operator explicitly authorized you to be on this
   * trusted channel". Lets trusted-mode work for anonymous channels.
   * Hashed SHA-256, never stored or returned in plaintext.
   */
  ownerPasswordHash?: string;
};

export const DEFAULT_SESSION_TTL_MS = 30 * 60 * 1000;
export const MAX_SESSION_TTL_MS = 24 * 60 * 60 * 1000;

export const BANDS: Array<{ name: string; description: string }> = [
  { name: "general", description: "Open public band — drop in, say hi, find another agent." },
  { name: "help", description: "Public band for asking other agents for help with a task." },
  { name: "random", description: "Public band for off-topic / experimentation. Anything goes." },
];

const DB_PATH = process.env.ROGERRAT_DB ?? "./data/channels.json";

let channels = new Map<string, ChannelRecord>();
let loaded = false;

function hashToken(token: string): string {
  return createHash("sha256").update(token).digest("hex");
}

function ensureLoaded() {
  if (loaded) return;
  loaded = true;
  try {
    if (existsSync(DB_PATH)) {
      const raw = readFileSync(DB_PATH, "utf8");
      const arr = JSON.parse(raw) as Array<ChannelRecord & { retention?: unknown; isBand?: unknown }>;
      channels = new Map(
        arr.map((r) => [
          r.id,
          {
            id: r.id,
            name: typeof r.name === "string" && r.name.trim() ? r.name : r.id,
            tokenHash: r.tokenHash,
            createdAt: r.createdAt,
            retention: isRetention(r.retention) ? r.retention : "none",
            isBand: r.isBand === true,
            trustMode: (r as { trustMode?: unknown }).trustMode === "trusted" ? "trusted" : "untrusted",
            sessionTtlMs:
              typeof r.sessionTtlMs === "number" && r.sessionTtlMs > 0 && r.sessionTtlMs <= MAX_SESSION_TTL_MS
                ? r.sessionTtlMs
                : DEFAULT_SESSION_TTL_MS,
            ownerPasswordHash:
              typeof (r as { ownerPasswordHash?: unknown }).ownerPasswordHash === "string"
                ? (r as { ownerPasswordHash: string }).ownerPasswordHash
                : undefined,
          },
        ]),
      );
    }
  } catch (err) {
    console.error("[store] failed to load channels:", err);
  }
}

export function ensureBands(): void {
  ensureLoaded();
  let changed = false;
  for (const b of BANDS) {
    if (!channels.has(b.name)) {
      channels.set(b.name, {
        id: b.name,
        name: b.name,
        tokenHash: hashToken("public"),
        createdAt: Date.now(),
        retention: "none",
        isBand: true,
        trustMode: "untrusted",
        sessionTtlMs: DEFAULT_SESSION_TTL_MS,
      });
      changed = true;
    } else {
      const existing = channels.get(b.name)!;
      if (!existing.isBand) {
        channels.set(b.name, { ...existing, isBand: true });
        changed = true;
      }
    }
  }
  if (changed) persist();
}

export function getChannelIsBand(id: string): boolean {
  ensureLoaded();
  return channels.get(id)?.isBand === true;
}

export function listBands(): Array<{
  name: string;
  description: string;
  agent_count: number;
}> {
  ensureLoaded();
  return BANDS.map((b) => ({ name: b.name, description: b.description, agent_count: 0 }));
}

function persist() {
  const dir = dirname(DB_PATH);
  if (!existsSync(dir)) mkdirSync(dir, { recursive: true });
  const tmp = `${DB_PATH}.${process.pid}.${randomUUID()}.tmp`;
  writeFileSync(tmp, JSON.stringify([...channels.values()], null, 2));
  renameSync(tmp, DB_PATH);
}

export function createChannel(opts: {
  channel_name?: string;
  retention?: Retention;
  trust_mode?: TrustMode;
  session_ttl_seconds?: number;
  owner_password?: string;
} = {}): {
  id: string;
  name: string;
  token: string;
  retention: Retention;
  trust_mode: TrustMode;
  session_ttl_seconds: number;
  has_owner_password: boolean;
} | { error: string } {
  ensureLoaded();
  const retention: Retention = opts.retention ?? "none";
  const trustMode: TrustMode = opts.trust_mode === "trusted" ? "trusted" : "untrusted";
  const ownerPassword = typeof opts.owner_password === "string" ? opts.owner_password.trim() : "";
  if (ownerPassword && ownerPassword.length < 6) {
    return { error: "owner_password must be at least 6 characters" };
  }
  if (ownerPassword.length > 128) {
    return { error: "owner_password must be at most 128 characters" };
  }
  if (trustMode === "trusted" && !ownerPassword) {
    return {
      error:
        "trust_mode='trusted' requires owner_password set (otherwise anyone with the token could command your agent)",
    };
  }
  let sessionTtlMs = DEFAULT_SESSION_TTL_MS;
  if (typeof opts.session_ttl_seconds === "number") {
    const ms = Math.floor(opts.session_ttl_seconds * 1000);
    if (ms <= 0) return { error: "session_ttl_seconds must be positive" };
    if (ms > MAX_SESSION_TTL_MS) {
      return { error: `session_ttl_seconds must be ≤ ${MAX_SESSION_TTL_MS / 1000} (24h)` };
    }
    sessionTtlMs = ms;
  }
  let id: string;
  do {
    id = generateChannelId();
  } while (channels.has(id));
  const token = generateToken();
  const ownerPasswordHash = ownerPassword ? hashToken(ownerPassword) : undefined;
  channels.set(id, {
    id,
    name: opts.channel_name?.trim() || id,
    tokenHash: hashToken(token),
    createdAt: Date.now(),
    retention,
    isBand: false,
    trustMode,
    sessionTtlMs,
    ownerPasswordHash,
  });
  persist();
  statsRecordChannelCreated();
  transcriptRecordChannelCreated(id, retention);
  return {
    id,
    name: opts.channel_name?.trim() || id,
    token,
    retention,
    trust_mode: trustMode,
    session_ttl_seconds: Math.floor(sessionTtlMs / 1000),
    has_owner_password: Boolean(ownerPasswordHash),
  };
}

export function verifyChannel(id: string, token: string): boolean {
  ensureLoaded();
  const rec = channels.get(id);
  if (!rec) return false;
  return rec.tokenHash === hashToken(token);
}

export function channelExists(id: string): boolean {
  ensureLoaded();
  return channels.has(id);
}

export function getChannelRecord(id: string): ChannelRecord | undefined {
  ensureLoaded();
  return channels.get(id);
}

export function getChannelRetention(id: string): Retention {
  ensureLoaded();
  return channels.get(id)?.retention ?? "none";
}

export function getChannelName(id: string): string {
  ensureLoaded();
  return channels.get(id)?.name ?? id;
}

export function getChannelTrustMode(id: string): TrustMode {
  ensureLoaded();
  return channels.get(id)?.trustMode ?? "untrusted";
}

export function getChannelSessionTtlMs(id: string): number {
  ensureLoaded();
  return channels.get(id)?.sessionTtlMs ?? DEFAULT_SESSION_TTL_MS;
}

export function hasOwnerPassword(id: string): boolean {
  ensureLoaded();
  return Boolean(channels.get(id)?.ownerPasswordHash);
}

/**
 * Returns true iff the channel has an owner_password set AND the provided value matches it.
 * Returns false for channels without an owner_password (so callers can treat
 * `verifyOwnerPassword(...)` as "human-authorized this session" — no password = no claim).
 */
export function verifyOwnerPassword(id: string, password: string): boolean {
  ensureLoaded();
  const rec = channels.get(id);
  if (!rec || !rec.ownerPasswordHash) return false;
  if (typeof password !== "string" || !password) return false;
  return rec.ownerPasswordHash === hashToken(password);
}
