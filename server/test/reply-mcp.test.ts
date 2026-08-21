import { chmodSync, mkdtempSync, writeFileSync } from "node:fs";
import { createServer, type Socket } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Readable } from "node:stream";
import { afterEach, describe, expect, it, vi } from "vitest";
import {
  createReplyMcpHandler,
  runChannelMcp,
  sendViaLocalApp,
  type LocalSendResult,
} from "../src/reply-mcp.js";

const closers: Array<() => Promise<void>> = [];

function toolCall(message = "API is ready") {
  return {
    jsonrpc: "2.0" as const,
    id: 3,
    method: "tools/call",
    params: {
      name: "send_to_channel",
      arguments: { message },
    },
  };
}

async function startLocalAppServer(
  reply: (request: Record<string, unknown>) => Record<string, unknown>,
): Promise<string> {
  const directory = mkdtempSync(join(tmpdir(), "agent-channels-app-"));
  const socketPath = join(directory, "send.sock");
  const sockets = new Set<Socket>();
  const server = createServer((socket) => {
    sockets.add(socket);
    socket.once("close", () => sockets.delete(socket));
    let input = "";
    socket.setEncoding("utf8");
    socket.on("data", (chunk) => {
      input += chunk;
      const newline = input.indexOf("\n");
      if (newline < 0) return;
      const request = JSON.parse(input.slice(0, newline)) as Record<string, unknown>;
      socket.end(`${JSON.stringify(reply(request))}\n`);
    });
  });
  await new Promise<void>((resolve, reject) => {
    server.once("error", reject);
    server.listen(socketPath, () => {
      server.off("error", reject);
      chmodSync(socketPath, 0o600);
      resolve();
    });
  });
  closers.push(() => new Promise<void>((resolve) => {
    for (const socket of sockets) socket.destroy();
    server.close(() => resolve());
  }));
  return socketPath;
}

afterEach(async () => {
  await Promise.all(closers.splice(0).map((close) => close()));
});

describe("channel MCP", () => {
  it("exposes only send_to_channel and delegates message-only sends to the app", async () => {
    const sendViaApp = vi.fn(async (): Promise<LocalSendResult> => ({
      ok: true,
      id: "42",
      callsign: "frontend",
    }));
    const handle = createReplyMcpHandler({ sendViaApp });

    const listed = await handle({ jsonrpc: "2.0", id: 1, method: "tools/list" });
    const tools = (listed?.result as { tools: Array<Record<string, unknown>> }).tools;
    expect(tools).toHaveLength(1);
    expect(tools[0]).toMatchObject({
      name: "send_to_channel",
      inputSchema: { required: ["message"], additionalProperties: false },
    });
    expect(JSON.stringify(tools[0])).not.toContain("reply_ref");

    const result = await handle(toolCall());
    expect(sendViaApp).toHaveBeenCalledWith("API is ready");
    expect(result?.result).toMatchObject({
      content: [{ type: "text", text: "sent message #42 to all as frontend" }],
    });
  });

  it("validates message before contacting the app", async () => {
    const sendViaApp = vi.fn();
    const handle = createReplyMcpHandler({ sendViaApp });

    const empty = await handle(toolCall(""));
    const tooLong = await handle(toolCall("x".repeat(8193)));
    expect(empty?.result).toMatchObject({ isError: true });
    expect(tooLong?.result).toMatchObject({ isError: true });
    expect(sendViaApp).not.toHaveBeenCalled();
  });

  it("allows retry after a definitive app rejection", async () => {
    const sendViaApp = vi.fn()
      .mockResolvedValueOnce({ ok: false, outcome: "definitive", error: "channel join failed" })
      .mockResolvedValueOnce({ ok: true, id: "43", callsign: "frontend" });
    const handle = createReplyMcpHandler({ sendViaApp });

    const failed = await handle(toolCall());
    const retried = await handle(toolCall());
    expect(failed?.result).toMatchObject({ isError: true });
    expect(JSON.stringify(failed)).toContain("channel join failed");
    expect(retried?.result).toMatchObject({
      content: [{ text: "sent message #43 to all as frontend" }],
    });
  });

  it("blocks later sends after an unknown app outcome", async () => {
    const sendViaApp = vi.fn(async (): Promise<LocalSendResult> => ({
      ok: false,
      outcome: "unknown",
      error: "channel send outcome is unknown",
    }));
    const handle = createReplyMcpHandler({ sendViaApp });

    const uncertain = await handle(toolCall());
    const blocked = await handle(toolCall("different message"));
    expect(uncertain?.result).toMatchObject({ isError: true });
    expect(JSON.stringify(uncertain)).toContain("outcome is unknown");
    expect(blocked?.result).toMatchObject({ isError: true });
    expect(JSON.stringify(blocked)).toContain("previous channel send outcome is unknown");
    expect(sendViaApp).toHaveBeenCalledTimes(1);
  });

  it("sends only protocol version and message over the protected app socket", async () => {
    let received: Record<string, unknown> | undefined;
    const socketPath = await startLocalAppServer((request) => {
      received = request;
      return { version: 1, ok: true, id: "44", callsign: "frontend" };
    });

    const result = await sendViaLocalApp(socketPath, "backend ready");
    expect(received).toEqual({ version: 1, message: "backend ready" });
    expect(result).toEqual({ ok: true, id: "44", callsign: "frontend" });
    expect(JSON.stringify(received)).not.toMatch(/token|password|origin|channel|callsign/i);
  });

  it("fails definitively before dispatch when the app socket is absent", async () => {
    const directory = mkdtempSync(join(tmpdir(), "agent-channels-missing-"));
    const result = await sendViaLocalApp(join(directory, "send.sock"), "hello", 100);
    expect(result).toMatchObject({ ok: false, outcome: "definitive" });
    expect(JSON.stringify(result)).toContain("open it and retry");
  });

  it("treats an incompatible app response as unknown after dispatch", async () => {
    const socketPath = await startLocalAppServer(() => ({ version: 2, ok: true }));
    const result = await sendViaLocalApp(socketPath, "hello");
    expect(result).toMatchObject({ ok: false, outcome: "unknown" });
    expect(JSON.stringify(result)).toContain("incompatible");
  });

  it("speaks newline-delimited MCP JSON-RPC over stdio", async () => {
    const directory = mkdtempSync(join(tmpdir(), "agent-channels-mcp-"));
    const configPath = join(directory, "binding.json");
    writeFileSync(configPath, "{}");
    const input = Readable.from([
      `${JSON.stringify({ jsonrpc: "2.0", id: 1, method: "initialize" })}\n`,
      `${JSON.stringify({ jsonrpc: "2.0", method: "notifications/initialized" })}\n`,
      `${JSON.stringify({ jsonrpc: "2.0", id: 2, method: "ping" })}\n`,
      `${JSON.stringify({ jsonrpc: "2.0", id: 3, method: "tools/list" })}\n`,
    ]);
    let stdout = "";
    let stderr = "";
    const code = await runChannelMcp(["--config", configPath], {
      input,
      output: { write: (chunk) => (stdout += chunk) },
      error: { write: (chunk) => (stderr += chunk) },
    });

    expect(code).toBe(0);
    expect(stderr).toBe("");
    const lines = stdout.trim().split("\n").map((line) => JSON.parse(line));
    expect(lines).toHaveLength(3);
    expect(lines[0]).toMatchObject({
      id: 1,
      result: { protocolVersion: "2025-03-26", serverInfo: { name: "agent-channels" } },
    });
    expect(lines[1]).toEqual({ jsonrpc: "2.0", id: 2, result: {} });
    expect(lines[2].result.tools).toEqual([expect.objectContaining({ name: "send_to_channel" })]);
  });
});
