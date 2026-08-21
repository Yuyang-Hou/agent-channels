// SSE /stream endpoint smoke test.
// Wires up createApp() and exercises the full path: create channel → join two
// callsigns → open SSE stream on one → send from the other → assert event delivered.

import { describe, it, expect } from "vitest";
import { createApp } from "../src/app.js";

const ORIGIN = "http://test.local";

function makeApp() {
  return createApp({ publicOrigin: ORIGIN, authRequired: true });
}

async function createChannel(app: ReturnType<typeof makeApp>): Promise<{ id: string; token: string }> {
  const res = await app.fetch(
    new Request(`${ORIGIN}/api/channels`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ retention: "none" }),
    }),
  );
  expect(res.status).toBe(200);
  const body = (await res.json()) as { channel_id: string; join_token: string };
  return { id: body.channel_id, token: body.join_token };
}

async function join(
  app: ReturnType<typeof makeApp>,
  ch: { id: string; token: string },
  callsign: string,
): Promise<{ session_id: string }> {
  const res = await app.fetch(
    new Request(`${ORIGIN}/api/channels/${ch.id}/join`, {
      method: "POST",
      headers: { "content-type": "application/json", authorization: `Bearer ${ch.token}` },
      body: JSON.stringify({ callsign }),
    }),
  );
  expect(res.status).toBe(200);
  return (await res.json()) as { session_id: string };
}

async function send(
  app: ReturnType<typeof makeApp>,
  ch: { id: string; token: string },
  sessionId: string,
  to: string,
  text: string,
): Promise<void> {
  const res = await app.fetch(
    new Request(`${ORIGIN}/api/channels/${ch.id}/send`, {
      method: "POST",
      headers: {
        "content-type": "application/json",
        authorization: `Bearer ${ch.token}`,
        "x-session-id": sessionId,
      },
      body: JSON.stringify({ to, text }),
    }),
  );
  expect(res.status).toBe(200);
}

/** Read SSE events from a streaming response body until `count` `message` events arrive
 *  (or timeoutMs elapses, in which case throw). Returns the parsed message bodies. */
async function readMessages(
  res: Response,
  count: number,
  timeoutMs = 2000,
): Promise<Array<{ id: number; from: string; text: string }>> {
  const reader = res.body!.getReader();
  const decoder = new TextDecoder();
  let buffer = "";
  const got: Array<{ id: number; from: string; text: string }> = [];
  const deadline = Date.now() + timeoutMs;
  while (got.length < count) {
    if (Date.now() > deadline) throw new Error(`timed out waiting for ${count} messages, got ${got.length}`);
    const { value, done } = await reader.read();
    if (done) break;
    buffer += decoder.decode(value, { stream: true });
    let idx;
    while ((idx = buffer.indexOf("\n\n")) !== -1) {
      const block = buffer.slice(0, idx);
      buffer = buffer.slice(idx + 2);
      let event = "";
      let data = "";
      for (const line of block.split("\n")) {
        if (line.startsWith("event: ")) event = line.slice(7);
        else if (line.startsWith("data: ")) data += (data ? "\n" : "") + line.slice(6);
      }
      if (event === "message") got.push(JSON.parse(data));
    }
  }
  await reader.cancel();
  return got;
}

describe("GET /api/channels/:id/stream (SSE)", () => {
  it("delivers a message sent after the stream is open", async () => {
    const app = makeApp();
    const ch = await createChannel(app);
    const alpha = await join(app, ch, "alpha");
    const beta = await join(app, ch, "beta");
    const streamRes = await app.fetch(
      new Request(`${ORIGIN}/api/channels/${ch.id}/stream`, {
        headers: { authorization: `Bearer ${ch.token}`, "x-session-id": alpha.session_id },
      }),
    );
    expect(streamRes.status).toBe(200);
    expect(streamRes.headers.get("content-type")).toContain("text/event-stream");
    await send(app, ch, beta.session_id, "alpha", "ping");
    const msgs = await readMessages(streamRes, 1);
    expect(msgs).toHaveLength(1);
    expect(msgs[0].from).toBe("beta");
    expect(msgs[0].text).toBe("ping");
  });

  it("delivers backlog buffered before stream is opened", async () => {
    const app = makeApp();
    const ch = await createChannel(app);
    const alpha = await join(app, ch, "alpha");
    const beta = await join(app, ch, "beta");
    await send(app, ch, beta.session_id, "alpha", "first");
    await send(app, ch, beta.session_id, "alpha", "second");
    const streamRes = await app.fetch(
      new Request(`${ORIGIN}/api/channels/${ch.id}/stream`, {
        headers: { authorization: `Bearer ${ch.token}`, "x-session-id": alpha.session_id },
      }),
    );
    expect(streamRes.status).toBe(200);
    const msgs = await readMessages(streamRes, 2);
    expect(msgs.map((m) => m.text)).toEqual(["first", "second"]);
  });

  it("rejects without X-Session-Id", async () => {
    const app = makeApp();
    const ch = await createChannel(app);
    const res = await app.fetch(
      new Request(`${ORIGIN}/api/channels/${ch.id}/stream`, {
        headers: { authorization: `Bearer ${ch.token}` },
      }),
    );
    expect(res.status).toBe(400);
  });

  it("rejects with bad bearer", async () => {
    const app = makeApp();
    const ch = await createChannel(app);
    const alpha = await join(app, ch, "alpha");
    const res = await app.fetch(
      new Request(`${ORIGIN}/api/channels/${ch.id}/stream`, {
        headers: { authorization: `Bearer wrong`, "x-session-id": alpha.session_id },
      }),
    );
    expect(res.status).toBe(401);
  });
});

/** Send with an explicit `kind` field — for status-signal tests. */
async function sendKind(
  app: ReturnType<typeof makeApp>,
  ch: { id: string; token: string },
  sessionId: string,
  to: string,
  text: string,
  kind: "message" | "status",
): Promise<Response> {
  return app.fetch(
    new Request(`${ORIGIN}/api/channels/${ch.id}/send`, {
      method: "POST",
      headers: {
        "content-type": "application/json",
        authorization: `Bearer ${ch.token}`,
        "x-session-id": sessionId,
      },
      body: JSON.stringify({ to, message: text, kind }),
    }),
  );
}

describe("status signals (kind:status)", () => {
  it("delivers a status signal to a live SSE stream", async () => {
    const app = makeApp();
    const ch = await createChannel(app);
    const alpha = await join(app, ch, "alpha");
    const beta = await join(app, ch, "beta");
    const streamRes = await app.fetch(
      new Request(`${ORIGIN}/api/channels/${ch.id}/stream`, {
        headers: { authorization: `Bearer ${ch.token}`, "x-session-id": alpha.session_id },
      }),
    );
    expect(streamRes.status).toBe(200);
    const res = await sendKind(app, ch, beta.session_id, "alpha", "on it, ~1 min", "status");
    expect(res.status).toBe(200);
    const body = (await res.json()) as { kind?: string };
    expect(body.kind).toBe("status");
    const msgs = (await readMessages(streamRes, 1)) as Array<{ from: string; text: string; kind?: string }>;
    expect(msgs[0].from).toBe("beta");
    expect(msgs[0].kind).toBe("status");
  });

  it("does NOT store status signals in history", async () => {
    const app = makeApp();
    const ch = await createChannel(app);
    const alpha = await join(app, ch, "alpha");
    const beta = await join(app, ch, "beta");
    // One real message, one status signal, one more real message.
    await send(app, ch, beta.session_id, "alpha", "real one");
    await sendKind(app, ch, beta.session_id, "alpha", "working…", "status");
    await send(app, ch, beta.session_id, "alpha", "real two");
    const histRes = await app.fetch(
      new Request(`${ORIGIN}/api/channels/${ch.id}/history?n=20`, {
        headers: { authorization: `Bearer ${ch.token}`, "x-session-id": alpha.session_id },
      }),
    );
    expect(histRes.status).toBe(200);
    const hist = (await histRes.json()) as { history: Array<{ text: string; kind?: string }> };
    // History has only the two real messages — the status signal is ephemeral.
    expect(hist.history.map((m) => m.text)).toEqual(["real one", "real two"]);
    expect(hist.history.some((m) => m.kind === "status")).toBe(false);
  });

  it("rejects an empty-text status signal", async () => {
    const app = makeApp();
    const ch = await createChannel(app);
    await join(app, ch, "alpha");
    const beta = await join(app, ch, "beta");
    const res = await sendKind(app, ch, beta.session_id, "alpha", "", "status");
    expect(res.status).toBe(400);
  });

  it("rejects an invalid kind value", async () => {
    const app = makeApp();
    const ch = await createChannel(app);
    const beta = await join(app, ch, "beta");
    const res = await app.fetch(
      new Request(`${ORIGIN}/api/channels/${ch.id}/send`, {
        method: "POST",
        headers: {
          "content-type": "application/json",
          authorization: `Bearer ${ch.token}`,
          "x-session-id": beta.session_id,
        },
        body: JSON.stringify({ to: "all", message: "hi", kind: "bogus" }),
      }),
    );
    expect(res.status).toBe(400);
  });
});
