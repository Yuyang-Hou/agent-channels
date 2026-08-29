import { chmodSync, mkdtempSync, writeFileSync } from "node:fs";
import { createServer, type Socket } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Readable } from "node:stream";
import { afterEach, describe, expect, it, vi } from "vitest";
import {
  createReplyMcpHandler,
  requestViaLocalApp,
  runChannelMcp,
  type LocalAppRequest,
  type LocalAppResult,
} from "../src/reply-mcp.js";

const THREAD_ID = "01a0236a-c478-7fc0-99f1-6f8fd6564b90";
const OTHER_THREAD_ID = "01a0236a-c478-7fc0-89f1-6f8fd6564b91";
const closers: Array<() => Promise<void>> = [];

function toolCall(
  name = "send_to_channel",
  args: Record<string, unknown> | undefined = { message: "API is ready" },
  meta: unknown = { threadId: THREAD_ID },
) {
  return {
    jsonrpc: "2.0" as const,
    id: 3,
    method: "tools/call",
    params: {
      name,
      ...(args === undefined ? {} : { arguments: args }),
      ...(meta === undefined ? {} : { _meta: meta }),
    },
  };
}

async function startLocalAppServer(
  reply: (request: Record<string, unknown>) => Record<string, unknown>,
): Promise<string> {
  const directory = mkdtempSync(join(tmpdir(), "pijoo-app-"));
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
  it("exposes the current-task channel tools and managed history search", async () => {
    const handle = createReplyMcpHandler();
    const listed = await handle({ jsonrpc: "2.0", id: 1, method: "tools/list" });
    const tools = (listed?.result as { tools: Array<Record<string, unknown>> }).tools;

    expect(tools.map((tool) => tool.name)).toEqual([
      "send_to_channel",
      "list_channels",
      "get_channel_settings",
      "update_channel_settings",
      "inspect_message_source",
      "search_authorized_history",
    ]);
    expect(tools[0]).toMatchObject({
      inputSchema: {
        required: ["message"],
        additionalProperties: false,
        properties: { mentions: { maxItems: 100, uniqueItems: true } },
      },
    });
    expect(tools[3]).toMatchObject({
      inputSchema: {
        required: ["channel"],
        properties: {
          sent_message_template: { type: "string" },
          default_send: { type: "boolean" },
        },
      },
    });
    expect(JSON.stringify(tools)).not.toContain("threadId");
  });

  it("reads the latest delivered channel message source only on explicit request", async () => {
    const provenance = {
      found: true,
      origin: "pijoo",
      channel: "api-work",
      channel_name: "API 协作",
      message_id: "42",
      sender_name: "backend",
      sender_member_id: "member-backend",
      source_kind: "codex_mcp",
      source_provider: "codex",
      received_at: 123,
    };
    const requestApp = vi.fn(async (): Promise<LocalAppResult> => ({
      ok: true,
      result: { message: "最近一条已投递消息来自 Pijoo", provenance },
    }));
    const handle = createReplyMcpHandler({ requestApp });

    const result = await handle(toolCall("inspect_message_source", {}));

    expect(requestApp).toHaveBeenCalledWith({
      version: 2,
      operation: "inspect_message_source",
      source: { provider: "codex", conversationId: THREAD_ID },
    });
    expect(result?.result).toMatchObject({
      content: [{ type: "text", text: "最近一条已投递消息来自 Pijoo" }],
      structuredContent: { provenance },
    });
  });

  it("delegates bounded history search with the protected current task id", async () => {
    const requestApp = vi.fn(async (): Promise<LocalAppResult> => ({
      ok: true,
      result: {
        query: "shipping",
        history: [{ thread_id: "01900000-0000-7000-8000-000000000002", trust: "untrusted_history", text: "shipping plan" }],
        truncated: false,
        message: "[1] shipping plan",
      },
    }));
    const handle = createReplyMcpHandler({ requestApp });

    const result = await handle(toolCall("search_authorized_history", { query: " shipping " }));

    expect(requestApp).toHaveBeenCalledWith({
      version: 2,
      operation: "search_history",
      source: { provider: "codex", conversationId: THREAD_ID },
      query: "shipping",
    });
    expect(result?.result).toMatchObject({
      content: [{ type: "text", text: "[1] shipping plan" }],
      structuredContent: { query: "shipping", truncated: false },
    });
  });

  it("takes the current task from protected call metadata and delegates protocol-v2 sends", async () => {
    const requestApp = vi.fn(async (): Promise<LocalAppResult> => ({
      ok: true,
      result: {
        id: "42",
        callsign: "frontend",
        channel: "api-work",
        message: "> **↗ Pijoo · 已发送到频道**\n>\n> API is ready",
      },
    }));
    const handle = createReplyMcpHandler({ requestApp });

    const result = await handle(toolCall("send_to_channel", {
      message: "API is ready",
      channel: " api-work ",
      mentions: [" member-a ", "member-b"],
    }));

    expect(requestApp).toHaveBeenCalledWith({
      version: 2,
      operation: "send",
      source: { provider: "codex", conversationId: THREAD_ID },
      message: "API is ready",
      channel: "api-work",
      mentions: ["member-a", "member-b"],
    });
    expect(result?.result).toMatchObject({
      content: [{ type: "text", text: "> **↗ Pijoo · 已发送到频道**\n>\n> API is ready" }],
      structuredContent: { id: "42", callsign: "frontend", channel: "api-work" },
    });
  });

  it("omits channel so the app can apply unique-subscription/default-send routing", async () => {
    const requestApp = vi.fn(async (): Promise<LocalAppResult> => ({
      ok: true,
      result: { id: "43", callsign: "frontend", channel: "default-channel" },
    }));
    const handle = createReplyMcpHandler({ requestApp });

    await handle(toolCall());
    expect(requestApp).toHaveBeenCalledWith({
      version: 2,
      operation: "send",
      source: { provider: "codex", conversationId: THREAD_ID },
      message: "API is ready",
    });
  });

  it("maps subscription and settings tools to task-scoped app operations", async () => {
    const requestApp = vi.fn(async (request: LocalAppRequest): Promise<LocalAppResult> => ({
      ok: true,
      result: { message: `${request.operation} ok` },
    }));
    const handle = createReplyMcpHandler({ requestApp });

    await handle(toolCall("list_channels", { channel: "frontend" }));
    await handle(toolCall("get_channel_settings", { channel: "frontend" }));
    await handle(toolCall("update_channel_settings", {
      channel: "frontend",
      template: "服务端说：{{message}}",
      sent_message_template: "已发到频道：{message_text}",
      default_send: true,
    }));

    const source = { provider: "codex", conversationId: THREAD_ID };
    expect(requestApp.mock.calls.map(([request]) => request)).toEqual([
      { version: 2, operation: "list_channels", source, channel: "frontend" },
      { version: 2, operation: "get_settings", source, channel: "frontend" },
      {
        version: 2,
        operation: "update_settings",
        source,
        channel: "frontend",
        settings: {
          template: "服务端说：{{message}}",
          sent_message_template: "已发到频道：{message_text}",
          default_send: true,
        },
      },
    ]);
  });

  it("fails closed when Codex does not provide a valid metadata threadId", async () => {
    const requestApp = vi.fn();
    const handle = createReplyMcpHandler({ requestApp });

    const missing = await handle({
      jsonrpc: "2.0",
      id: 3,
      method: "tools/call",
      params: {
        name: "send_to_channel",
        arguments: { message: "hello", threadId: THREAD_ID },
      },
    });
    const uri = await handle(toolCall("list_channels", {}, {
      threadId: `codex://threads/${THREAD_ID}`,
    }));
    const malformed = await handle(toolCall("list_channels", {}, { threadId: "not-a-uuid" }));

    for (const result of [missing, uri, malformed]) {
      expect(result?.result).toMatchObject({ isError: true });
      expect(JSON.stringify(result)).toContain("valid current task id");
    }
    expect(requestApp).not.toHaveBeenCalled();
  });

  it("validates tool arguments before contacting the app", async () => {
    const requestApp = vi.fn();
    const handle = createReplyMcpHandler({ requestApp });

    const results = await Promise.all([
      handle(toolCall("send_to_channel", { message: "" })),
      handle(toolCall("send_to_channel", { message: "x".repeat(8193) })),
      handle(toolCall("send_to_channel", { message: "x", mentions: [] })),
      handle(toolCall("send_to_channel", { message: "x", mentions: ["all", "member-a"] })),
      handle(toolCall("send_to_channel", { message: "x", mentions: ["member-a", "member-a"] })),
      handle(toolCall("update_channel_settings", { channel: "frontend" })),
      handle(toolCall("list_channels", { threadId: THREAD_ID })),
      handle(toolCall("inspect_message_source", { message_id: "42" })),
    ]);

    for (const result of results) expect(result?.result).toMatchObject({ isError: true });
    expect(requestApp).not.toHaveBeenCalled();
  });

  it("surfaces ambiguous app routing as a definitive error and allows retry", async () => {
    const requestApp = vi.fn()
      .mockResolvedValueOnce({
        ok: false,
        outcome: "definitive",
        error: "choose a channel because this task has multiple subscriptions",
      })
      .mockResolvedValueOnce({
        ok: true,
        result: { id: "44", callsign: "frontend", channel: "api-work" },
      });
    const handle = createReplyMcpHandler({ requestApp });

    const ambiguous = await handle(toolCall());
    const selected = await handle(toolCall("send_to_channel", {
      message: "API is ready",
      channel: "api-work",
    }));

    expect(ambiguous?.result).toMatchObject({ isError: true });
    expect(JSON.stringify(ambiguous)).toContain("multiple subscriptions");
    expect(selected?.result).toMatchObject({ content: [{ text: expect.stringContaining("#44") }] });
    expect(requestApp).toHaveBeenCalledTimes(2);
  });

  it("blocks unknown sends only for the affected current task", async () => {
    const requestApp = vi.fn(async (request: LocalAppRequest): Promise<LocalAppResult> => {
      if ("source" in request && request.source.conversationId === THREAD_ID) {
        return { ok: false, outcome: "unknown", error: "channel send outcome is unknown" };
      }
      return { ok: true, result: { id: "45", callsign: "backend", channel: "api-work" } };
    });
    const handle = createReplyMcpHandler({ requestApp });

    const uncertain = await handle(toolCall());
    const blocked = await handle(toolCall("send_to_channel", { message: "different message" }));
    const otherTask = await handle(toolCall(
      "send_to_channel",
      { message: "other task message" },
      { threadId: OTHER_THREAD_ID },
    ));

    expect(uncertain?.result).toMatchObject({ isError: true });
    expect(blocked?.result).toMatchObject({ isError: true });
    expect(JSON.stringify(blocked)).toContain("for this task is unknown");
    expect(otherTask?.result).toMatchObject({ content: [{ text: expect.stringContaining("#45") }] });
    expect(requestApp).toHaveBeenCalledTimes(2);
  });

  it("blocks later sends when the app reports success without a valid send receipt", async () => {
    const requestApp = vi.fn(async (): Promise<LocalAppResult> => ({
      ok: true,
      result: { channel: "api-work" },
    }));
    const handle = createReplyMcpHandler({ requestApp });

    const malformed = await handle(toolCall());
    const blocked = await handle(toolCall("send_to_channel", { message: "retry" }));

    expect(malformed?.result).toMatchObject({ isError: true });
    expect(JSON.stringify(malformed)).toContain("send outcome is unknown");
    expect(blocked?.result).toMatchObject({ isError: true });
    expect(requestApp).toHaveBeenCalledTimes(1);
  });

  it("sends the operation and host-provided source over the protected app socket", async () => {
    let received: Record<string, unknown> | undefined;
    const socketPath = await startLocalAppServer((request) => {
      received = request;
      return {
        version: 2,
        ok: true,
        result: { id: "46", callsign: "frontend", channel: "api-work" },
      };
    });
    const request: LocalAppRequest = {
      version: 2,
      operation: "send",
      source: { provider: "codex", conversationId: THREAD_ID },
      message: "backend ready",
      channel: "api-work",
    };

    const result = await requestViaLocalApp(socketPath, request);
    expect(received).toEqual(request);
    expect(result).toEqual({
      ok: true,
      result: { id: "46", callsign: "frontend", channel: "api-work" },
    });
    expect(JSON.stringify(received)).not.toMatch(/token|password|origin|callsign/i);
  });

  it("fails definitively before dispatch when the app socket is absent", async () => {
    const directory = mkdtempSync(join(tmpdir(), "pijoo-missing-"));
    const result = await requestViaLocalApp(join(directory, "send.sock"), {
      version: 2,
      operation: "send",
      source: { provider: "codex", conversationId: THREAD_ID },
      message: "hello",
    }, 100);
    expect(result).toMatchObject({ ok: false, outcome: "definitive" });
    expect(JSON.stringify(result)).toContain("open it and retry");
  });

  it("treats incompatible post-dispatch send responses as unknown but reads as retryable", async () => {
    const sendSocket = await startLocalAppServer(() => ({ version: 1, ok: true }));
    const readSocket = await startLocalAppServer(() => ({ version: 1, ok: true }));

    const send = await requestViaLocalApp(sendSocket, {
      version: 2,
      operation: "send",
      source: { provider: "codex", conversationId: THREAD_ID },
      message: "hello",
    });
    const read = await requestViaLocalApp(readSocket, {
      version: 2,
      operation: "list_channels",
      source: { provider: "codex", conversationId: THREAD_ID },
    });

    expect(send).toMatchObject({ ok: false, outcome: "unknown" });
    expect(read).toMatchObject({ ok: false, outcome: "definitive" });
    expect(JSON.stringify(send)).toContain("incompatible");
  });

  it("speaks newline-delimited MCP JSON-RPC over stdio", async () => {
    const directory = mkdtempSync(join(tmpdir(), "pijoo-mcp-"));
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
    const requestApp = vi.fn(async (): Promise<LocalAppResult> => ({
      ok: true,
      result: { message: "recorded" },
    }));
    const code = await runChannelMcp(["--config", configPath], {
      input,
      output: { write: (chunk) => (stdout += chunk) },
      error: { write: (chunk) => (stderr += chunk) },
      requestApp,
    });

    expect(code).toBe(0);
    expect(stderr).toBe("");
    const lines = stdout.trim().split("\n").map((line) => JSON.parse(line));
    expect(lines).toHaveLength(3);
    expect(lines[0]).toMatchObject({
      id: 1,
      result: {
        protocolVersion: "2025-03-26",
        serverInfo: { name: "pijoo", version: "dev" },
      },
    });
    expect(lines[1]).toEqual({ jsonrpc: "2.0", id: 2, result: {} });
    expect(lines[2].result.tools).toHaveLength(6);
    expect(lines[2].result.tools).toContainEqual(expect.objectContaining({ name: "list_channels" }));
    expect(requestApp).toHaveBeenCalledWith({
      version: 2,
      operation: "mcp_ready",
      client_version: "dev",
    });
  });
});
