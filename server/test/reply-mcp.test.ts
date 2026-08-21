import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Readable } from "node:stream";
import { describe, expect, it, vi } from "vitest";
import {
  createReplyMcpHandler,
  parseReplyMcpConfig,
  runChannelMcp,
  type ReplyMcpConfig,
} from "../src/reply-mcp.js";

function fixture(): ReplyMcpConfig {
  return {
    origin: "https://channels.example",
    channel: "quiet-otter-3a8f",
    callsign: "frontend",
    keychainService: "Agent Channels",
    keychainAccount: "binding-1",
    ownerPasswordAccount: "binding-1-owner",
  };
}

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

function joinResponse() {
  return new Response(JSON.stringify({ session_id: "session-1" }), {
    status: 200,
    headers: { "content-type": "application/json" },
  });
}

function sendResponse(id = 42) {
  return new Response(JSON.stringify({ ok: true, id }), {
    status: 200,
    headers: { "content-type": "application/json" },
  });
}

describe("channel MCP", () => {
  it("exposes only send_to_channel and broadcasts as the bound callsign", async () => {
    const requests: Array<{ url: string; init?: RequestInit }> = [];
    const fetchMock: typeof fetch = vi.fn(async (input, init) => {
      requests.push({ url: String(input), init });
      return requests.length === 1 ? joinResponse() : sendResponse();
    }) as typeof fetch;
    const readSecret = vi.fn((service: string, account: string) => {
      expect(service).toBe("Agent Channels");
      expect(account).toBe("binding-1");
      return "channel-token";
    });
    const readOptionalSecret = vi.fn((service: string, account: string) => {
      expect(service).toBe("Agent Channels");
      expect(account).toBe("binding-1-owner");
      return "owner-secret";
    });
    const handle = createReplyMcpHandler(fixture(), {
      fetch: fetchMock,
      readSecret,
      readOptionalSecret,
    });

    const listed = await handle({ jsonrpc: "2.0", id: 1, method: "tools/list" });
    const tools = (listed?.result as { tools: Array<Record<string, unknown>> }).tools;
    expect(tools).toHaveLength(1);
    expect(tools[0]).toMatchObject({
      name: "send_to_channel",
      inputSchema: { required: ["message"], additionalProperties: false },
    });
    expect(JSON.stringify(tools[0])).not.toContain("reply_ref");

    const result = await handle(toolCall());
    expect(result?.result).toMatchObject({
      content: [{ type: "text", text: "sent message #42 to all as frontend" }],
    });
    expect(requests[0].url).toBe(
      "https://channels.example/api/channels/quiet-otter-3a8f/join",
    );
    expect(JSON.parse(String(requests[0].init?.body))).toEqual({
      callsign: "frontend",
      owner_password: "owner-secret",
    });
    expect(requests[0].init?.headers).toMatchObject({ authorization: "Bearer channel-token" });
    expect(JSON.parse(String(requests[1].init?.body))).toEqual({
      to: "all",
      message: "API is ready",
    });
    expect(requests[1].init?.headers).toMatchObject({ "x-session-id": "session-1" });
  });

  it("validates message before accessing credentials or the network", async () => {
    const readSecret = vi.fn(() => "token");
    const fetchMock = vi.fn();
    const handle = createReplyMcpHandler(fixture(), {
      readSecret,
      readOptionalSecret: () => undefined,
      fetch: fetchMock as typeof fetch,
    });

    const empty = await handle(toolCall(""));
    const tooLong = await handle(toolCall("x".repeat(8193)));
    expect(empty?.result).toMatchObject({ isError: true });
    expect(tooLong?.result).toMatchObject({ isError: true });
    expect(readSecret).not.toHaveBeenCalled();
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it("omits owner_password when the binding has no owner password account", async () => {
    const requests: RequestInit[] = [];
    const fetchMock: typeof fetch = vi.fn(async (_input, init) => {
      requests.push(init ?? {});
      return requests.length === 1 ? joinResponse() : sendResponse();
    }) as typeof fetch;
    const readOptionalSecret = vi.fn(() => undefined);
    const config = fixture();
    delete config.ownerPasswordAccount;
    const handle = createReplyMcpHandler(config, {
      fetch: fetchMock,
      readSecret: () => "token",
      readOptionalSecret,
    });

    await handle(toolCall());
    expect(readOptionalSecret).not.toHaveBeenCalled();
    expect(JSON.parse(String(requests[0].body))).toEqual({ callsign: "frontend" });
  });

  it("allows retry after join fails because no message was sent", async () => {
    let request = 0;
    const fetchMock: typeof fetch = vi.fn(async () => {
      request += 1;
      if (request === 1) throw new Error("join connection reset");
      return request === 2 ? joinResponse() : sendResponse(43);
    }) as typeof fetch;
    const handle = createReplyMcpHandler(fixture(), {
      fetch: fetchMock,
      readSecret: () => "token",
      readOptionalSecret: () => undefined,
    });

    const failed = await handle(toolCall());
    const retried = await handle(toolCall());
    expect(failed?.result).toMatchObject({ isError: true });
    expect(JSON.stringify(failed)).toContain("join connection reset");
    expect(retried?.result).toMatchObject({
      content: [{ text: "sent message #43 to all as frontend" }],
    });
  });

  it("allows retry after a definitive client-side send rejection", async () => {
    let request = 0;
    const fetchMock: typeof fetch = vi.fn(async () => {
      request += 1;
      if (request === 1 || request === 3) return joinResponse();
      if (request === 2) return new Response(JSON.stringify({ error: "not joined" }), { status: 400 });
      return sendResponse(44);
    }) as typeof fetch;
    const handle = createReplyMcpHandler(fixture(), {
      fetch: fetchMock,
      readSecret: () => "token",
      readOptionalSecret: () => undefined,
    });

    const rejected = await handle(toolCall());
    const retried = await handle(toolCall());
    expect(rejected?.result).toMatchObject({ isError: true });
    expect(JSON.stringify(rejected)).toContain("channel send failed: 400");
    expect(retried?.result).toMatchObject({
      content: [{ text: "sent message #44 to all as frontend" }],
    });
  });

  it("blocks later sends after an uncertain send outcome", async () => {
    const fetchMock: typeof fetch = vi.fn(async (input) => {
      if (String(input).endsWith("/join")) return joinResponse();
      throw new Error("connection reset");
    }) as typeof fetch;
    const readSecret = vi.fn(() => "token");
    const handle = createReplyMcpHandler(fixture(), {
      fetch: fetchMock,
      readSecret,
      readOptionalSecret: () => undefined,
    });

    const uncertain = await handle(toolCall());
    const blocked = await handle(toolCall("different message"));
    expect(uncertain?.result).toMatchObject({ isError: true });
    expect(JSON.stringify(uncertain)).toContain("outcome is unknown");
    expect(blocked?.result).toMatchObject({ isError: true });
    expect(JSON.stringify(blocked)).toContain("previous channel send outcome is unknown");
    expect(fetchMock).toHaveBeenCalledTimes(2);
    expect(readSecret).toHaveBeenCalledTimes(1);
  });

  it("speaks newline-delimited MCP JSON-RPC over stdio", async () => {
    const directory = mkdtempSync(join(tmpdir(), "agent-channels-mcp-"));
    const configPath = join(directory, "binding.json");
    writeFileSync(configPath, JSON.stringify(fixture()));
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

  it("normalizes and validates binding config", () => {
    const parsed = parseReplyMcpConfig({
      origin: "https://channels.example/path",
      channel: "quiet-otter-3a8f",
      callsign: " Frontend ",
      keychainService: "Agent Channels",
      keychainAccount: "binding-1",
      ownerPasswordAccount: "binding-1-owner",
    });
    expect(parsed.origin).toBe("https://channels.example");
    expect(parsed.callsign).toBe("frontend");
    expect(parsed.ownerPasswordAccount).toBe("binding-1-owner");
    expect(() => parseReplyMcpConfig({ ...parsed, callsign: "all" })).toThrow();
    expect(() => parseReplyMcpConfig({ ...parsed, ownerPasswordAccount: "" })).toThrow();
  });
});
