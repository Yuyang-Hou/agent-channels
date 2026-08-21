import { existsSync, mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Readable } from "node:stream";
import { describe, expect, it, vi } from "vitest";
import {
  createReplyMcpHandler,
  parseReplyMcpConfig,
  runReplyMcp,
  type ReplyMcpConfig,
} from "../src/reply-mcp.js";

const REF = "01900000-0000-7000-8000-000000000001";

function fixture(from = "backend") {
  const replyDirectory = mkdtempSync(join(tmpdir(), "agent-channels-reply-"));
  const pendingDirectory = join(replyDirectory, "pending");
  const config: ReplyMcpConfig = {
    origin: "https://channels.example",
    channel: "quiet-otter-3a8f",
    callsign: "frontend",
    replyDirectory,
    keychainService: "Agent Channels",
    keychainAccount: "binding-1",
  };
  mkdirSync(pendingDirectory, { recursive: true });
  const pendingPath = join(pendingDirectory, `${REF}.json`);
  writeFileSync(pendingPath, JSON.stringify({ channelId: config.channel, from }));
  return {
    config,
    pendingPath,
    claimedPath: join(replyDirectory, "claimed", `${REF}.json`),
  };
}

function toolCall(replyRef = REF, message = "API is ready") {
  return {
    jsonrpc: "2.0" as const,
    id: 3,
    method: "tools/call",
    params: {
      name: "reply_to_message",
      arguments: { reply_ref: replyRef, message },
    },
  };
}

describe("reply MCP", () => {
  it("exposes only reply_to_message and sends only to the claimed sender", async () => {
    const ctx = fixture();
    const requests: Array<{ url: string; init?: RequestInit }> = [];
    const fetchMock: typeof fetch = vi.fn(async (input, init) => {
      requests.push({ url: String(input), init });
      if (requests.length === 1) {
        return new Response(JSON.stringify({ session_id: "session-1" }), {
          status: 200,
          headers: { "content-type": "application/json" },
        });
      }
      return new Response(JSON.stringify({ ok: true, id: 42 }), {
        status: 200,
        headers: { "content-type": "application/json" },
      });
    }) as typeof fetch;
    const handle = createReplyMcpHandler(ctx.config, {
      fetch: fetchMock,
      readSecret: (service, account) => {
        expect(service).toBe("Agent Channels");
        expect(account).toBe("binding-1");
        return "channel-token";
      },
    });

    const listed = await handle({ jsonrpc: "2.0", id: 1, method: "tools/list" });
    expect(listed?.result).toMatchObject({ tools: [{ name: "reply_to_message" }] });
    expect((listed?.result as { tools: unknown[] }).tools).toHaveLength(1);

    const result = await handle(toolCall());
    expect(result?.result).toMatchObject({
      content: [{ type: "text", text: "sent reply #42 to backend" }],
    });
    expect(requests[0].url).toBe(
      "https://channels.example/api/channels/quiet-otter-3a8f/join",
    );
    expect(JSON.parse(String(requests[0].init?.body))).toEqual({ callsign: "frontend" });
    expect(requests[0].init?.headers).toMatchObject({ authorization: "Bearer channel-token" });
    expect(JSON.parse(String(requests[1].init?.body))).toEqual({
      to: "backend",
      message: "API is ready",
    });
    expect(requests[1].init?.headers).toMatchObject({ "x-session-id": "session-1" });
    expect(existsSync(ctx.pendingPath)).toBe(false);
    expect(existsSync(ctx.claimedPath)).toBe(false);
  });

  it("rejects invalid refs before claiming or accessing credentials", async () => {
    const ctx = fixture();
    const readSecret = vi.fn(() => "token");
    const fetchMock = vi.fn();
    const handle = createReplyMcpHandler(ctx.config, {
      readSecret,
      fetch: fetchMock as typeof fetch,
    });

    const result = await handle(toolCall("../../token"));
    expect(result?.result).toMatchObject({ isError: true });
    expect(readSecret).not.toHaveBeenCalled();
    expect(fetchMock).not.toHaveBeenCalled();
    expect(existsSync(ctx.pendingPath)).toBe(true);
  });

  it("does not send an expired reply claim", async () => {
    const ctx = fixture();
    writeFileSync(ctx.pendingPath, JSON.stringify({
      channelId: ctx.config.channel,
      from: "backend",
      expiresAt: Date.now() - 1,
    }));
    const readSecret = vi.fn(() => "token");
    const fetchMock = vi.fn();
    const handle = createReplyMcpHandler(ctx.config, {
      readSecret,
      fetch: fetchMock as typeof fetch,
    });

    const result = await handle(toolCall());
    expect(result?.result).toMatchObject({ isError: true });
    expect(JSON.stringify(result)).toContain("expired");
    expect(readSecret).not.toHaveBeenCalled();
    expect(fetchMock).not.toHaveBeenCalled();
    expect(existsSync(ctx.pendingPath)).toBe(true);
  });

  it("does not use a reply ref from another channel binding", async () => {
    const ctx = fixture();
    writeFileSync(ctx.pendingPath, JSON.stringify({ channelId: "other-channel", from: "backend" }));
    const readSecret = vi.fn(() => "token");
    const fetchMock = vi.fn();
    const handle = createReplyMcpHandler(ctx.config, {
      readSecret,
      fetch: fetchMock as typeof fetch,
    });

    const result = await handle(toolCall());
    expect(result?.result).toMatchObject({ isError: true });
    expect(JSON.stringify(result)).toContain("different channel binding");
    expect(readSecret).not.toHaveBeenCalled();
    expect(fetchMock).not.toHaveBeenCalled();
    expect(existsSync(ctx.pendingPath)).toBe(true);
  });

  it("restores a claim after a definitive validation or HTTP failure", async () => {
    const ctx = fixture("frontend");
    const handle = createReplyMcpHandler(ctx.config, {
      readSecret: () => "token",
      fetch: vi.fn() as unknown as typeof fetch,
    });
    const selfReply = await handle(toolCall());
    expect(selfReply?.result).toMatchObject({ isError: true });
    expect(existsSync(ctx.pendingPath)).toBe(true);
    expect(existsSync(ctx.claimedPath)).toBe(false);

    writeFileSync(ctx.pendingPath, JSON.stringify({ channelId: ctx.config.channel, from: "backend" }));
    const explicitFetch: typeof fetch = vi.fn(async (input) => {
      if (String(input).endsWith("/join")) {
        return new Response(JSON.stringify({ session_id: "session-1" }), { status: 200 });
      }
      return new Response(JSON.stringify({ error: "not joined" }), { status: 400 });
    }) as typeof fetch;
    const explicitHandle = createReplyMcpHandler(ctx.config, {
      readSecret: () => "token",
      fetch: explicitFetch,
    });
    const rejected = await explicitHandle(toolCall());
    expect(rejected?.result).toMatchObject({ isError: true });
    expect(existsSync(ctx.pendingPath)).toBe(true);
    expect(existsSync(ctx.claimedPath)).toBe(false);
  });

  it("retains the claim when send delivery outcome is unknown", async () => {
    const ctx = fixture();
    const fetchMock: typeof fetch = vi.fn(async (input) => {
      if (String(input).endsWith("/join")) {
        return new Response(JSON.stringify({ session_id: "session-1" }), { status: 200 });
      }
      throw new Error("connection reset");
    }) as typeof fetch;
    const handle = createReplyMcpHandler(ctx.config, {
      readSecret: () => "token",
      fetch: fetchMock,
    });

    const result = await handle(toolCall());
    expect(result?.result).toMatchObject({ isError: true });
    expect(JSON.stringify(result)).toContain("outcome is unknown");
    expect(existsSync(ctx.pendingPath)).toBe(false);
    expect(existsSync(ctx.claimedPath)).toBe(true);
  });

  it("speaks newline-delimited MCP JSON-RPC over stdio", async () => {
    const ctx = fixture();
    const configPath = join(ctx.config.replyDirectory, "binding.json");
    writeFileSync(configPath, JSON.stringify(ctx.config));
    const input = Readable.from([
      `${JSON.stringify({ jsonrpc: "2.0", id: 1, method: "initialize" })}\n`,
      `${JSON.stringify({ jsonrpc: "2.0", method: "notifications/initialized" })}\n`,
      `${JSON.stringify({ jsonrpc: "2.0", id: 2, method: "ping" })}\n`,
      `${JSON.stringify({ jsonrpc: "2.0", id: 3, method: "tools/list" })}\n`,
    ]);
    let stdout = "";
    let stderr = "";
    const code = await runReplyMcp(["--config", configPath], {
      input,
      output: { write: (chunk) => (stdout += chunk) },
      error: { write: (chunk) => (stderr += chunk) },
    });

    expect(code).toBe(0);
    expect(stderr).toBe("");
    const lines = stdout.trim().split("\n").map((line) => JSON.parse(line));
    expect(lines).toHaveLength(3);
    expect(lines[0]).toMatchObject({ id: 1, result: { protocolVersion: "2025-03-26" } });
    expect(lines[1]).toEqual({ jsonrpc: "2.0", id: 2, result: {} });
    expect(lines[2].result.tools).toEqual([expect.objectContaining({ name: "reply_to_message" })]);
  });

  it("normalizes and validates binding config", () => {
    const parsed = parseReplyMcpConfig({
      origin: "https://channels.example/path",
      channel: "quiet-otter-3a8f",
      callsign: " Frontend ",
      replyDirectory: "/tmp/replies",
      keychainService: "Agent Channels",
      keychainAccount: "binding-1",
    });
    expect(parsed.origin).toBe("https://channels.example");
    expect(parsed.callsign).toBe("frontend");
    expect(() => parseReplyMcpConfig({ ...parsed, callsign: "all" })).toThrow();
  });
});
