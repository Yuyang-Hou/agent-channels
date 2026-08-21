import { appendFileSync, existsSync, mkdirSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";

export type Retention = "none" | "metadata" | "prompts" | "full";

export const RETENTION_VALUES: readonly Retention[] = ["none", "metadata", "prompts", "full"] as const;

export function isRetention(v: unknown): v is Retention {
  return typeof v === "string" && (RETENTION_VALUES as readonly string[]).includes(v);
}

export type TranscriptEvent =
  | { ts: number; type: "channel_created"; retention: Retention }
  | { ts: number; type: "join"; callsign: string }
  | { ts: number; type: "leave"; callsign: string }
  | { ts: number; type: "message"; from: string; to: string; text: string }
  | { ts: number; type: "message_meta"; from: string; to: string; bytes: number };

const TRANSCRIPTS_DIR = process.env.ROGERRAT_TRANSCRIPTS ?? "./data/transcripts";
const firstSenderByChannel = new Map<string, Set<string>>();

function pathFor(channelId: string): string {
  return join(TRANSCRIPTS_DIR, `${channelId}.jsonl`);
}

function ensureDir() {
  if (!existsSync(TRANSCRIPTS_DIR)) mkdirSync(TRANSCRIPTS_DIR, { recursive: true });
}

function appendLine(channelId: string, event: TranscriptEvent) {
  ensureDir();
  appendFileSync(pathFor(channelId), JSON.stringify(event) + "\n");
}

export function recordChannelCreated(channelId: string, retention: Retention) {
  if (retention === "none") return;
  appendLine(channelId, { ts: Date.now(), type: "channel_created", retention });
}

export function recordJoin(channelId: string, retention: Retention, callsign: string) {
  if (retention === "none") return;
  appendLine(channelId, { ts: Date.now(), type: "join", callsign });
}

export function recordLeave(channelId: string, retention: Retention, callsign: string) {
  if (retention === "none") return;
  appendLine(channelId, { ts: Date.now(), type: "leave", callsign });
}

export function recordMessage(
  channelId: string,
  retention: Retention,
  msg: { from: string; to: string; text: string; at: number },
) {
  if (retention === "none") return;
  if (retention === "metadata") {
    appendLine(channelId, {
      ts: msg.at,
      type: "message_meta",
      from: msg.from,
      to: msg.to,
      bytes: msg.text.length,
    });
    return;
  }
  if (retention === "prompts") {
    const seen = firstSenderByChannel.get(channelId) ?? new Set<string>();
    if (seen.has(msg.from)) return;
    seen.add(msg.from);
    firstSenderByChannel.set(channelId, seen);
  }
  appendLine(channelId, { ts: msg.at, type: "message", from: msg.from, to: msg.to, text: msg.text });
}

export function readTranscript(channelId: string, limit = 1000): TranscriptEvent[] {
  const p = pathFor(channelId);
  if (!existsSync(p)) return [];
  const lines = readFileSync(p, "utf8").trim().split("\n").filter(Boolean);
  const events = lines.map((line) => JSON.parse(line) as TranscriptEvent);
  const clamped = Math.max(1, Math.min(10000, Math.floor(limit)));
  return events.slice(-clamped);
}

export function hasTranscript(channelId: string): boolean {
  return existsSync(pathFor(channelId));
}
