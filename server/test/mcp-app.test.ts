import { describe, expect, it } from "vitest";
import { createApp } from "../src/app.js";
import { CHANNEL_VIEW_MIME_TYPE, CHANNEL_VIEW_URI } from "../src/channel-view.js";

const ORIGIN = "https://rogerthat.example";

async function createChannel(app: ReturnType<typeof createApp>) {
  const response = await app.fetch(
    new Request(`${ORIGIN}/api/channels`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ retention: "none" }),
    }),
  );
  expect(response.status).toBe(200);
  const body = (await response.json()) as { channel_id: string; join_token: string };
  return { id: body.channel_id, token: body.join_token };
}

async function mcp(
  app: ReturnType<typeof createApp>,
  method: string,
  params: Record<string, unknown> = {},
  sessionId?: string,
) {
  const response = await app.fetch(
    new Request(`${ORIGIN}/mcp`, {
      method: "POST",
      headers: {
        "content-type": "application/json",
        ...(sessionId ? { "mcp-session-id": sessionId } : {}),
      },
      body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }),
    }),
  );
  return {
    response,
    sessionId: response.headers.get("mcp-session-id") ?? sessionId,
    body: (await response.json()) as {
      result?: Record<string, unknown>;
      error?: { message: string };
    },
  };
}

describe("MCP App channel view", () => {
  it("advertises and serves the MCP Apps resource", async () => {
    const app = createApp({ publicOrigin: ORIGIN, authRequired: true });
    const initialized = await mcp(app, "initialize", {
      protocolVersion: "2025-03-26",
      capabilities: {},
      clientInfo: { name: "test", version: "1" },
    });
    expect(initialized.sessionId).toBeTruthy();
    expect(initialized.body.result?.capabilities).toMatchObject({ tools: {}, resources: {} });

    const tools = await mcp(app, "tools/list", {}, initialized.sessionId);
    const tool = (tools.body.result?.tools as Array<Record<string, unknown>>).find(
      (candidate) => candidate.name === "open_channel_view",
    );
    expect(tool?._meta).toMatchObject({ ui: { resourceUri: CHANNEL_VIEW_URI } });

    const resource = await mcp(app, "resources/read", { uri: CHANNEL_VIEW_URI }, initialized.sessionId);
    const contents = resource.body.result?.contents as Array<Record<string, unknown>>;
    expect(contents[0]).toMatchObject({ uri: CHANNEL_VIEW_URI, mimeType: CHANNEL_VIEW_MIME_TYPE });
    expect(contents[0].text).toContain("request('ui/message'");
    const script = String(contents[0].text).match(/<script>([\s\S]*)<\/script>/)?.[1];
    expect(script).toBeTruthy();
    expect(() => new Function(script!)).not.toThrow();
    expect(contents[0]._meta).toMatchObject({
      ui: { csp: { connectDomains: [ORIGIN] } },
    });
  });

  it("opens the View on the same MCP session without exposing the token to model content", async () => {
    const app = createApp({ publicOrigin: ORIGIN, authRequired: true });
    const channel = await createChannel(app);
    const initialized = await mcp(app, "initialize");
    const opened = await mcp(
      app,
      "tools/call",
      {
        name: "open_channel_view",
        arguments: { channel_id: channel.id, token: channel.token, callsign: "view-agent" },
      },
      initialized.sessionId,
    );
    expect(opened.body.error).toBeUndefined();
    const result = opened.body.result as {
      content: Array<{ text: string }>;
      structuredContent: Record<string, unknown>;
      _meta: { channelView: { token: string; sessionId: string } };
    };
    expect(result.structuredContent).toMatchObject({
      channel_id: channel.id,
      callsign: "view-agent",
      session_id: initialized.sessionId,
      state: "listening",
    });
    expect(JSON.stringify({ content: result.content, structuredContent: result.structuredContent })).not.toContain(
      channel.token,
    );
    expect(result._meta.channelView).toMatchObject({ token: channel.token, sessionId: initialized.sessionId });

    const stream = await app.fetch(
      new Request(`${ORIGIN}/api/channels/${channel.id}/stream`, {
        headers: {
          authorization: `Bearer ${channel.token}`,
          "x-session-id": initialized.sessionId!,
          origin: "https://host.example",
        },
      }),
    );
    expect(stream.status).toBe(200);
    expect(stream.headers.get("access-control-allow-origin")).toBe("*");
    await stream.body?.cancel();
  });

  it("answers browser preflight for MCP and channel APIs", async () => {
    const app = createApp({ publicOrigin: ORIGIN, authRequired: true });
    for (const path of ["/mcp", "/api/channels/example/stream"]) {
      const response = await app.fetch(
        new Request(`${ORIGIN}${path}`, {
          method: "OPTIONS",
          headers: { origin: "https://host.example", "access-control-request-method": "POST" },
        }),
      );
      expect(response.status).toBe(204);
      expect(response.headers.get("access-control-allow-origin")).toBe("*");
      expect(response.headers.get("access-control-allow-headers")).toContain("x-session-id");
    }
  });
});
