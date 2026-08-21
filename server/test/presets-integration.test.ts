// Integration test for the subdomain → preset pipeline.
//
// Boots the app on a real TCP port and hits POST /api/channels with a Host
// header for each preset, asserting that the channel comes out with the right
// defaults — and that an explicit body field overrides the preset.
//
// We can't use fetch() here: Node's fetch treats `Host` as a forbidden header
// and silently drops it, so the request always arrives at the server with
// host="127.0.0.1:<port>" and the mode resolver returns "default". Instead we
// hit the socket directly via http.request, which lets us set the Host header
// the same way a real browser or reverse-proxy (Caddy) would.

import { serve, type ServerType } from "@hono/node-server";
import { request as httpRequest } from "node:http";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { createApp } from "../src/app.js";

type Ctx = { server: ServerType; port: number };

async function boot(): Promise<Ctx> {
  const app = createApp({ publicOrigin: "http://127.0.0.1:0" });
  return new Promise((resolve, reject) => {
    const server = serve({ fetch: app.fetch, hostname: "127.0.0.1", port: 0 }, (info) => {
      resolve({ server, port: info.port });
    });
    server.on?.("error", reject);
  });
}

async function shutdown(ctx: Ctx): Promise<void> {
  return new Promise((resolve) => ctx.server.close(() => resolve()));
}

type RawResp = { status: number; headers: Record<string, string | string[] | undefined>; body: string };

function rawRequest(
  ctx: Ctx,
  method: string,
  path: string,
  host: string,
  body?: string,
  extraHeaders: Record<string, string> = {},
): Promise<RawResp> {
  return new Promise((resolve, reject) => {
    const req = httpRequest(
      {
        host: "127.0.0.1",
        port: ctx.port,
        method,
        path,
        headers: {
          host,
          ...(body ? { "content-type": "application/json", "content-length": Buffer.byteLength(body).toString() } : {}),
          ...extraHeaders,
        },
      },
      (res) => {
        const chunks: Buffer[] = [];
        res.on("data", (c: Buffer) => chunks.push(c));
        res.on("end", () =>
          resolve({
            status: res.statusCode ?? 0,
            headers: res.headers as Record<string, string | string[] | undefined>,
            body: Buffer.concat(chunks).toString("utf8"),
          }),
        );
        res.on("error", reject);
      },
    );
    req.on("error", reject);
    if (body) req.write(body);
    req.end();
  });
}

async function createWithHost(ctx: Ctx, host: string, body: Record<string, unknown> = {}) {
  const res = await rawRequest(ctx, "POST", "/api/channels", host, JSON.stringify(body));
  return JSON.parse(res.body) as {
    retention: string;
    trust_mode: string;
    session_ttl_seconds: number;
    has_owner_password: boolean;
    owner_password: string | null;
  };
}

let ctx: Ctx;
beforeEach(async () => { ctx = await boot(); });
afterEach(async () => { await shutdown(ctx); });

describe("subdomain → preset defaults", () => {
  it("default host: existing behavior (untrusted, no retention)", async () => {
    const ch = await createWithHost(ctx, "rogerthat.chat");
    expect(ch.trust_mode).toBe("untrusted");
    expect(ch.retention).toBe("none");
  });

  it("park. host: 24h TTL, metadata retention, untrusted", async () => {
    const ch = await createWithHost(ctx, "park.rogerthat.chat");
    expect(ch.session_ttl_seconds).toBe(86400);
    expect(ch.retention).toBe("metadata");
    expect(ch.trust_mode).toBe("untrusted");
  });

  it("live. host: 5min TTL, no retention, untrusted", async () => {
    const ch = await createWithHost(ctx, "live.rogerthat.chat");
    expect(ch.session_ttl_seconds).toBe(300);
    expect(ch.retention).toBe("none");
    expect(ch.trust_mode).toBe("untrusted");
  });

  it("go. host: trusted + owner_password auto-minted", async () => {
    const ch = await createWithHost(ctx, "go.rogerthat.chat");
    expect(ch.trust_mode).toBe("trusted");
    expect(ch.has_owner_password).toBe(true);
    expect(ch.owner_password).toBeTruthy();
    expect(typeof ch.owner_password).toBe("string");
  });

  it("body explicit field overrides the preset (escape hatch)", async () => {
    const ch = await createWithHost(ctx, "park.rogerthat.chat", { retention: "full" });
    expect(ch.retention).toBe("full");
    // Other park defaults still apply
    expect(ch.session_ttl_seconds).toBe(86400);
  });
});

describe("/llms.txt mode-banner", () => {
  it("default host: no mode banner", async () => {
    const res = await rawRequest(ctx, "GET", "/llms.txt", "rogerthat.chat");
    expect(res.body).not.toMatch(/^# PARK MODE/m);
    expect(res.body).not.toMatch(/^# GO MODE/m);
    expect(res.body).toMatch(/^# RogerThat/m);
  });
  it("go. host: leads with GO MODE banner", async () => {
    const res = await rawRequest(ctx, "GET", "/llms.txt", "go.rogerthat.chat");
    expect(res.body).toMatch(/^# GO MODE/m);
    expect(res.body).toMatch(/trust_mode.*trusted/);
  });
  it("live. host: recommends polling", async () => {
    const res = await rawRequest(ctx, "GET", "/llms.txt", "live.rogerthat.chat");
    expect(res.body).toMatch(/^# LIVE MODE/m);
    expect(res.body).toMatch(/tight long-polling/);
  });
  it("park. host: recommends listen-here", async () => {
    const res = await rawRequest(ctx, "GET", "/llms.txt", "park.rogerthat.chat");
    expect(res.body).toMatch(/^# PARK MODE/m);
    expect(res.body).toMatch(/listen-here/);
  });
});

describe("MCP tools/list per mode", () => {
  async function mcpToolsList(host: string) {
    const initBody = JSON.stringify({
      jsonrpc: "2.0",
      id: 1,
      method: "initialize",
      params: { protocolVersion: "2025-03-26", capabilities: {}, clientInfo: { name: "t", version: "0" } },
    });
    const init = await rawRequest(ctx, "POST", "/mcp", host, initBody);
    const sid = init.headers["mcp-session-id"] as string | undefined;
    expect(sid).toBeTruthy();
    const listBody = JSON.stringify({ jsonrpc: "2.0", id: 2, method: "tools/list", params: {} });
    const list = await rawRequest(ctx, "POST", "/mcp", host, listBody, { "mcp-session-id": sid! });
    const j = JSON.parse(list.body) as { result: { tools: { name: string; description: string }[] } };
    return j.result.tools;
  }

  it("default host: create_channel description asks the one short question", async () => {
    const tools = await mcpToolsList("rogerthat.chat");
    const create = tools.find((t) => t.name === "create_channel")!;
    expect(create.description).toMatch(/ask ONE short question/);
  });

  it("go. host: create_channel description is thinned for the mode", async () => {
    const tools = await mcpToolsList("go.rogerthat.chat");
    const create = tools.find((t) => t.name === "create_channel")!;
    expect(create.description).toMatch(/GO mode/);
    expect(create.description).toMatch(/trust_mode=trusted/);
    expect(create.description).not.toMatch(/ask ONE short question/);
  });
});
