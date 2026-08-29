import { chmodSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import {
  parseChannelConfig,
  searchAuthorizedCodexHistory,
  searchCodexHistoryViaAppServer,
} from "../src/codex-history.js";

const ALLOWED = "01900000-0000-7000-8000-000000000001";
const DENIED = "01900000-0000-7000-8000-000000000002";
const CHANNEL = "00000000-0000-4000-8000-000000000001";

function config(allowed = [ALLOWED]) {
  return parseChannelConfig(JSON.stringify({
    version: 1,
    channels: [{ channel_id: CHANNEL, allowed_history_task_ids: allowed }],
  }), CHANNEL);
}

function thread(id: string, text: string): unknown {
  return {
    thread: {
      id,
      name: `Task ${id.slice(-4)}`,
      turns: [{
        items: [
          { type: "userMessage", content: [{ type: "text", text: `User ${text}` }] },
          { type: "agentMessage", text: `Assistant ${text}` },
        ],
      }],
    },
  };
}

describe("authorized Codex history", () => {
  it("reads only the local allowlist and revocation takes effect on the next search", async () => {
    const reads: string[] = [];
    const read = async (id: string) => {
      reads.push(id);
      return thread(id, "shipping decision");
    };
    const allowed = config();
    const result = await searchAuthorizedCodexHistory(allowed, "shipping", read);
    expect(reads).toEqual([ALLOWED]);
    expect(result.results).toHaveLength(2);
    expect(result.results.every((item) => item.thread_id === ALLOWED)).toBe(true);
    expect(result.results.every((item) => item.trust === "untrusted_history")).toBe(true);
    expect(JSON.stringify(result)).not.toContain(DENIED);

    const revoked = { ...allowed, allowed_history_task_ids: [] };
    reads.length = 0;
    await expect(searchAuthorizedCodexHistory(revoked, "shipping", read)).resolves.toEqual({
      query: "shipping",
      results: [],
      truncated: false,
    });
    expect(reads).toEqual([]);
  });

  it("bounds returned snippets", async () => {
    const result = await searchAuthorizedCodexHistory(config(), "match", async (id) => thread(id, `match ${"x".repeat(2_000)}`));
    expect(result.truncated).toBe(true);
    expect(result.results.every((item) => item.text.length <= 1_200)).toBe(true);
  });

  it("uses thread/read without resuming or mutating the authorized task", async () => {
    const directory = mkdtempSync(join(tmpdir(), "pijoo-history-"));
    const executable = join(directory, "codex");
    writeFileSync(executable, `#!${process.execPath}
let buffer = "";
process.stdin.setEncoding("utf8");
process.stdin.on("data", (chunk) => {
  buffer += chunk;
  for (;;) {
    const newline = buffer.indexOf("\\n");
    if (newline < 0) break;
    const message = JSON.parse(buffer.slice(0, newline));
    buffer = buffer.slice(newline + 1);
    if (message.id === 1) {
      process.stdout.write(JSON.stringify({ id: 1, result: {} }) + "\\n");
    } else if (message.id === 2 && message.method === "thread/read"
      && message.params.threadId === ${JSON.stringify(ALLOWED)}
      && message.params.includeTurns === true) {
      process.stdout.write(JSON.stringify({ id: 2, result: ${JSON.stringify(thread(ALLOWED, "shipping decision"))} }) + "\\n");
    } else if (message.id) {
      process.stdout.write(JSON.stringify({ id: message.id, error: { message: "unexpected request" } }) + "\\n");
    }
  }
});
`);
    chmodSync(executable, 0o700);
    const result = await searchCodexHistoryViaAppServer({ config: config(), query: "shipping", codexExecutable: executable });
    expect(result.results).toHaveLength(2);
  });
});
