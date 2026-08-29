import { spawn } from "node:child_process";
import { lstatSync, readFileSync } from "node:fs";
import { isAbsolute } from "node:path";
import { parseCodexThreadId } from "./codex-turn.js";

const MAX_ALLOWED_THREADS = 20;
const MAX_RESULTS = 12;
const MAX_RESULT_TEXT = 1_200;
const MAX_TOTAL_TEXT = 8_000;
const MAX_FRAME_BYTES = 256 * 1024 * 1024;

type ChannelHistoryConfig = {
  allowed_history_task_ids: string[];
};

export type CodexHistoryResult = {
  thread_id: string;
  title: string;
  role: "user" | "assistant";
  trust: "untrusted_history";
  text: string;
};

export type CodexHistorySearchResponse = {
  query: string;
  results: CodexHistoryResult[];
  truncated: boolean;
};

type ReadThread = (threadId: string) => Promise<unknown>;

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

export function parseChannelConfig(input: string, channelId: string): ChannelHistoryConfig {
  const value = JSON.parse(input) as unknown;
  if (!isRecord(value) || value.version !== 1 || !Array.isArray(value.channels)) {
    throw new Error("Channel config is invalid or unsupported");
  }
  const channel = value.channels.find((item) => isRecord(item) && item.channel_id === channelId);
  if (!isRecord(channel) || !Array.isArray(channel.allowed_history_task_ids)) {
    throw new Error("Channel history config is missing");
  }
  const allowed = [...new Set(channel.allowed_history_task_ids.map((item) => {
    if (typeof item !== "string") throw new Error("Channel history allowlist is invalid");
    return parseCodexThreadId(item).toLowerCase();
  }))];
  return { allowed_history_task_ids: allowed };
}

export function loadChannelConfig(path: string, channelId: string): ChannelHistoryConfig {
  const stat = lstatSync(path);
  if (!stat.isFile()) throw new Error("Channel config must be a regular file");
  if (process.platform !== "win32" && (stat.uid !== process.getuid?.() || (stat.mode & 0o077) !== 0)) {
    throw new Error("Channel config must be owned by the current user without group or other access");
  }
  return parseChannelConfig(readFileSync(path, "utf8"), channelId);
}

function textItems(threadId: string, value: unknown): CodexHistoryResult[] {
  if (!isRecord(value)) throw new Error("Codex app-server returned an incompatible thread");
  const thread = isRecord(value.thread) ? value.thread : value;
  if (!isRecord(thread) || thread.id !== threadId || !Array.isArray(thread.turns)) {
    throw new Error("Codex app-server returned an incompatible thread");
  }
  const titleValue = typeof thread.name === "string" && thread.name.trim()
    ? thread.name
    : typeof thread.preview === "string" && thread.preview.trim()
      ? thread.preview
      : threadId;
  const title = titleValue.trim().replace(/\s+/g, " ").slice(0, 200);
  const results: CodexHistoryResult[] = [];
  for (const turn of thread.turns) {
    if (!isRecord(turn) || !Array.isArray(turn.items)) continue;
    for (const item of turn.items) {
      if (!isRecord(item)) continue;
      if (item.type === "agentMessage" && typeof item.text === "string") {
        results.push({ thread_id: threadId, title, role: "assistant", trust: "untrusted_history", text: item.text });
      } else if (item.type === "userMessage" && Array.isArray(item.content)) {
        for (const content of item.content) {
          if (isRecord(content) && content.type === "text" && typeof content.text === "string") {
            results.push({ thread_id: threadId, title, role: "user", trust: "untrusted_history", text: content.text });
          }
        }
      }
    }
  }
  return results;
}

export async function searchAuthorizedCodexHistory(
  config: ChannelHistoryConfig,
  queryInput: string,
  readThread: ReadThread,
): Promise<CodexHistorySearchResponse> {
  const query = queryInput.trim().replace(/\s+/g, " ");
  if (!query || query.length > 200) throw new Error("History query must be 1 to 200 characters");
  const needle = query.toLocaleLowerCase();
  const allowed = config.allowed_history_task_ids.slice(0, MAX_ALLOWED_THREADS);
  const results: CodexHistoryResult[] = [];
  let totalText = 0;
  let truncated = config.allowed_history_task_ids.length > allowed.length;

  for (const [threadIndex, threadId] of allowed.entries()) {
    for (const item of textItems(threadId, await readThread(threadId))) {
      if (!item.text.toLocaleLowerCase().includes(needle)) continue;
      const remaining = MAX_TOTAL_TEXT - totalText;
      if (results.length >= MAX_RESULTS || remaining <= 0) {
        truncated = true;
        break;
      }
      const text = item.text.trim().replace(/\s+/g, " ");
      const bounded = text.slice(0, Math.min(MAX_RESULT_TEXT, remaining));
      if (!bounded) continue;
      truncated ||= bounded.length < text.length;
      results.push({ ...item, text: bounded });
      totalText += bounded.length;
    }
    if (results.length >= MAX_RESULTS || totalText >= MAX_TOTAL_TEXT) {
      truncated ||= threadIndex < allowed.length - 1;
      break;
    }
  }
  return { query, results, truncated };
}

export async function searchCodexHistoryViaAppServer(options: {
  config: ChannelHistoryConfig;
  query: string;
  codexExecutable: string;
  timeoutMs?: number;
}): Promise<CodexHistorySearchResponse> {
  const executable = options.codexExecutable.trim();
  if (!isAbsolute(executable) || !lstatSync(executable).isFile()) {
    throw new Error("Codex executable must be an existing absolute file");
  }
  if (options.config.allowed_history_task_ids.length === 0) {
    return searchAuthorizedCodexHistory(options.config, options.query, async () => {
      throw new Error("unreachable");
    });
  }

  const child = spawn(executable, ["app-server", "--stdio"], { stdio: ["pipe", "pipe", "pipe"] });
  let buffer = "";
  let stderr = "";
  let nextID = 1;
  let closing = false;
  const pending = new Map<number, {
    timer: NodeJS.Timeout;
    resolve: (value: unknown) => void;
    reject: (error: Error) => void;
  }>();
  const failAll = (error: Error) => {
    for (const request of pending.values()) {
      clearTimeout(request.timer);
      request.reject(error);
    }
    pending.clear();
  };
  const request = (method: string, params: object): Promise<unknown> => {
    const id = nextID++;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        pending.delete(id);
        reject(new Error(`Codex app-server ${method} timed out`));
      }, options.timeoutMs ?? 15_000);
      pending.set(id, { timer, resolve, reject });
      child.stdin.write(`${JSON.stringify({ id, method, params })}\n`);
    });
  };

  child.stderr.setEncoding("utf8");
  child.stderr.on("data", (chunk: string) => {
    stderr = `${stderr}${chunk}`.slice(-64 * 1024).trim();
  });
  child.stdout.setEncoding("utf8");
  child.stdout.on("data", (chunk: string) => {
    buffer += chunk;
    if (buffer.length > MAX_FRAME_BYTES) {
      failAll(new Error("Codex app-server response exceeds the supported size"));
      child.kill();
      return;
    }
    for (;;) {
      const newline = buffer.indexOf("\n");
      if (newline < 0) break;
      const line = buffer.slice(0, newline).trim();
      buffer = buffer.slice(newline + 1);
      if (!line) continue;
      let message: unknown;
      try {
        message = JSON.parse(line);
      } catch {
        failAll(new Error("Codex app-server returned invalid JSON"));
        child.kill();
        return;
      }
      if (!isRecord(message) || typeof message.id !== "number") continue;
      const pendingRequest = pending.get(message.id);
      if (!pendingRequest) continue;
      pending.delete(message.id);
      clearTimeout(pendingRequest.timer);
      if (message.error !== undefined) {
        const detail = isRecord(message.error) && typeof message.error.message === "string"
          ? message.error.message
          : JSON.stringify(message.error);
        pendingRequest.reject(new Error(`Codex app-server request failed: ${detail}`));
      } else {
        pendingRequest.resolve(message.result);
      }
    }
  });
  child.once("error", failAll);
  child.stdin.once("error", failAll);
  child.once("close", (code) => {
    if (!closing) failAll(new Error(`Codex app-server exited (${code ?? "unknown"})${stderr ? `: ${stderr}` : ""}`));
  });

  try {
    await request("initialize", { clientInfo: { name: "pijoo", title: "Pijoo", version: "1" } });
    child.stdin.write(`${JSON.stringify({ method: "initialized", params: {} })}\n`);
    return await searchAuthorizedCodexHistory(options.config, options.query, async (threadId) => {
      return request("thread/read", { threadId, includeTurns: true });
    });
  } finally {
    closing = true;
    child.stdin.end();
    const timer = setTimeout(() => child.kill(), 1_000);
    child.once("close", () => clearTimeout(timer));
  }
}
