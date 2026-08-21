import { existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { dirname } from "node:path";

type Stats = {
  channels_created: number;
  joins_total: number;
  messages_total: number;
  started_at: number;
};

const STATS_PATH = process.env.ROGERRAT_STATS ?? "./data/stats.json";

let stats: Stats = { channels_created: 0, joins_total: 0, messages_total: 0, started_at: Date.now() };
let loaded = false;
let dirty = false;
let saveTimer: NodeJS.Timeout | null = null;

function load() {
  if (loaded) return;
  loaded = true;
  try {
    if (existsSync(STATS_PATH)) {
      const parsed = JSON.parse(readFileSync(STATS_PATH, "utf8")) as Partial<Stats>;
      stats = {
        channels_created: parsed.channels_created ?? 0,
        joins_total: parsed.joins_total ?? 0,
        messages_total: parsed.messages_total ?? 0,
        started_at: parsed.started_at ?? Date.now(),
      };
    }
  } catch (err) {
    console.error("[stats] failed to load:", err);
  }
}

function scheduleSave() {
  dirty = true;
  if (saveTimer) return;
  saveTimer = setTimeout(() => {
    saveTimer = null;
    if (!dirty) return;
    dirty = false;
    try {
      const dir = dirname(STATS_PATH);
      if (!existsSync(dir)) mkdirSync(dir, { recursive: true });
      const tmp = `${STATS_PATH}.tmp`;
      writeFileSync(tmp, JSON.stringify(stats, null, 2));
      renameSync(tmp, STATS_PATH);
    } catch (err) {
      console.error("[stats] failed to save:", err);
    }
  }, 5000);
}

export function recordChannelCreated() {
  load();
  stats.channels_created++;
  scheduleSave();
}

export function recordJoin() {
  load();
  stats.joins_total++;
  scheduleSave();
}

export function recordMessage() {
  load();
  stats.messages_total++;
  scheduleSave();
}

export function getStats(): Stats {
  load();
  return { ...stats };
}
