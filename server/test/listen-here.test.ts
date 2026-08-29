// `npx rogerthat listen-here` smoke test.
// Boots the app on a real TCP port (since runListenHere uses global `fetch` with
// a URL string, we need a reachable origin) and exercises the receiver end-to-end:
// stdout dump, --inbox file, --on-message hook, and reconnect with `since`.

import { serve, type ServerType } from "@hono/node-server";
import { chmodSync, mkdtempSync, readFileSync, writeFileSync, existsSync } from "node:fs";
import { createServer as createHttpServer } from "node:http";
import { createServer, type Socket } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Readable } from "node:stream";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { createApp } from "../src/app.js";
import { planReconnect, runListenHere } from "../src/listen-here.js";

type ServerCtx = {
  server: ServerType;
  origin: string;
  channelId: string;
  channelToken: string;
  alphaSession: string;
  betaSession: string;
  tmp: string;
};

function ipcFrame(message: object): Buffer {
  const payload = Buffer.from(JSON.stringify(message), "utf8");
  const frame = Buffer.allocUnsafe(4 + payload.length);
  frame.writeUInt32LE(payload.length, 0);
  payload.copy(frame, 4);
  return frame;
}

function readIpcFrames(socket: Socket, onMessage: (message: Record<string, unknown>) => void): void {
  let buffer = Buffer.alloc(0);
  socket.on("data", (chunk) => {
    buffer = buffer.length === 0 ? chunk : Buffer.concat([buffer, chunk]);
    while (buffer.length >= 4) {
      const length = buffer.readUInt32LE(0);
      if (buffer.length < 4 + length) return;
      onMessage(JSON.parse(buffer.subarray(4, 4 + length).toString("utf8")) as Record<string, unknown>);
      buffer = buffer.subarray(4 + length);
    }
  });
}

async function boot(): Promise<ServerCtx> {
  const app = createApp({ publicOrigin: "http://127.0.0.1:0", authRequired: true });
  return new Promise((resolve, reject) => {
    const server = serve({ fetch: app.fetch, hostname: "127.0.0.1", port: 0 }, async (info) => {
      const origin = `http://127.0.0.1:${info.port}`;
      try {
        const created = await fetch(`${origin}/api/channels`, {
          method: "POST",
          headers: { "content-type": "application/json" },
          body: JSON.stringify({ retention: "none" }),
        }).then((r) => r.json() as Promise<{ channel_id: string; join_token: string }>);
        const channelId = created.channel_id;
        const channelToken = created.join_token;
        const joinOne = async (callsign: string) =>
          fetch(`${origin}/api/channels/${channelId}/join`, {
            method: "POST",
            headers: { "content-type": "application/json", authorization: `Bearer ${channelToken}` },
            body: JSON.stringify({ callsign }),
          }).then((r) => r.json() as Promise<{ session_id: string; member_id: string; endpoint_id: string }>);
        const alpha = await joinOne("alpha");
        const beta = await joinOne("beta");
        resolve({
          server,
          origin,
          channelId,
          channelToken,
          alphaSession: alpha.session_id,
          betaSession: beta.session_id,
          tmp: mkdtempSync(join(tmpdir(), "rogerthat-listen-here-")),
        });
      } catch (err) {
        reject(err);
      }
    });
  });
}

function shutdown(ctx: ServerCtx): Promise<void> {
  return new Promise((resolve) => ctx.server.close(() => resolve()));
}

async function sendFromBeta(
  ctx: ServerCtx,
  text: string,
  to = "alpha",
  priority?: "min" | "low" | "default" | "high" | "urgent",
  suggestedReplies?: string[],
  mentions?: string[],
): Promise<void> {
  await fetch(`${ctx.origin}/api/channels/${ctx.channelId}/send`, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      authorization: `Bearer ${ctx.channelToken}`,
      "x-session-id": ctx.betaSession,
    },
    body: JSON.stringify({
      to,
      text,
      ...(priority ? { priority } : {}),
      ...(suggestedReplies ? { suggested_replies: suggestedReplies } : {}),
      ...(mentions ? { mentions } : {}),
    }),
  });
}

/** Run runListenHere with a soft timeout; returns the exit code. The caller
 *  signals shutdown via SIGINT by sending it to the current process — vitest
 *  doesn't have a clean abort hook for an in-process call, so we just race
 *  the listen-here promise against a deadline.
 *
 *  IMPORTANT: clear the timeout once the listener resolves. Otherwise a stale
 *  setTimeout sits in the event loop and fires `process.emit("SIGINT")` after
 *  the test finishes — which lands on whichever listener happens to be running
 *  in the NEXT test and kills it prematurely. */
async function runListener(
  args: string[],
  deadlineMs: number,
  secretInput?: AsyncIterable<string | Buffer>,
): Promise<{ code: number }> {
  let timer: NodeJS.Timeout | undefined;
  const done = runListenHere(args, secretInput).then((code) => {
    if (timer) clearTimeout(timer);
    return { code };
  });
  const timeout = new Promise<{ code: number }>((resolve) => {
    timer = setTimeout(() => {
      process.emit("SIGINT");
      resolve({ code: -1 });
    }, deadlineMs);
  });
  return Promise.race([done, timeout]);
}

async function waitFor(check: () => boolean, timeoutMs = 2000): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (!check()) {
    if (Date.now() >= deadline) throw new Error("timed out waiting for listen-here output");
    await new Promise((resolve) => setTimeout(resolve, 25));
  }
}

function messageLineCount(path: string): number {
  if (!existsSync(path)) return 0;
  return readFileSync(path, "utf8").split("\n").filter((line) => line && !line.startsWith("⟲")).length;
}

let ctx: ServerCtx;

beforeEach(async () => {
  ctx = await boot();
});

afterEach(async () => {
  await shutdown(ctx);
});

describe("rogerthat listen-here", () => {
  it("--identity-key: auto-joins with the channel callsign", async () => {
    const inbox = join(ctx.tmp, "rr-auto-join.jsonl");
    const listener = runListener(
      [
        "--channel", ctx.channelId,
        "--token", ctx.channelToken,
        "--identity-key", "gamma",
        "--origin", ctx.origin,
        "--inbox", inbox,
        "--quiet",
      ],
      1500,
    );
    await new Promise((r) => setTimeout(r, 200));
    await sendFromBeta(ctx, "auto-joined", "gamma");
    await waitFor(() => messageLineCount(inbox) === 1);
    process.emit("SIGINT");
    await listener;
    expect(JSON.parse(readFileSync(inbox, "utf8"))).toMatchObject({
      from: "beta",
      to: "gamma",
      text: "auto-joined",
    });
  });

  it("--secrets-stdin keeps the channel token out of argv", async () => {
    const inbox = join(ctx.tmp, "rr-secret-stdin.jsonl");
    const args = [
      "--channel", ctx.channelId,
      "--secrets-stdin",
      "--identity-key", "secret-reader",
      "--origin", ctx.origin,
      "--inbox", inbox,
      "--quiet",
    ];
    expect(args).not.toContain(ctx.channelToken);
    const listener = runListener(
      args,
      1500,
      Readable.from([JSON.stringify({ token: ctx.channelToken })]),
    );
    await new Promise((resolve) => setTimeout(resolve, 200));
    await sendFromBeta(ctx, "secret-input-ok", "secret-reader");
    await waitFor(() => messageLineCount(inbox) === 1);
    process.emit("SIGINT");
    await listener;
    expect(JSON.parse(readFileSync(inbox, "utf8"))).toMatchObject({ text: "secret-input-ok" });
  });

  it("--inbox: appends each message as a JSON line", async () => {
    const inbox = join(ctx.tmp, "rr-inbox.jsonl");
    const listener = runListener(
      [
        "--channel", ctx.channelId,
        "--token", ctx.channelToken,
        "--session", ctx.alphaSession,
        "--origin", ctx.origin,
        "--inbox", inbox,
        "--quiet",
      ],
      1500,
    );
    // Give the SSE connection a tick to open before we send.
    await new Promise((r) => setTimeout(r, 200));
    await sendFromBeta(ctx, "hello-one");
    await sendFromBeta(ctx, "hello-two");
    await waitFor(() => messageLineCount(inbox) === 2);
    process.emit("SIGINT");
    await listener;
    expect(existsSync(inbox)).toBe(true);
    const lines = readFileSync(inbox, "utf8").trim().split("\n").filter((l) => !l.startsWith("⟲"));
    expect(lines).toHaveLength(2);
    const parsed = lines.map((l) => JSON.parse(l) as { from: string; text: string });
    expect(parsed[0].text).toBe("hello-one");
    expect(parsed[1].text).toBe("hello-two");
    expect(parsed[0].from).toBe("beta");
  });

  it("--status-json reports a received envelope before Host delivery", async () => {
    const errors = vi.spyOn(console, "error").mockImplementation(() => undefined);
    const listener = runListener(
      [
        "--channel", ctx.channelId,
        "--token", ctx.channelToken,
        "--session", ctx.alphaSession,
        "--origin", ctx.origin,
        "--status-json",
        "--quiet",
      ],
      1500,
    );
    await new Promise((resolve) => setTimeout(resolve, 200));
    await sendFromBeta(ctx, "ledger-first");
    await waitFor(() => errors.mock.calls.some(([line]) => String(line).includes('"state":"received"')));
    process.emit("SIGINT");
    await listener;

    const line = errors.mock.calls.map(([entry]) => String(entry))
      .find((entry) => entry.startsWith("@pijoo ") && entry.includes('"state":"received"'))!;
    expect(JSON.parse(line.slice("@pijoo ".length))).toMatchObject({
      state: "received",
      message: {
        channel: ctx.channelId,
        from: "beta",
        to: "alpha",
        text: "ledger-first",
      },
    });
    errors.mockRestore();
  });

  it("delivers every human message regardless of which member endpoint sent it", async () => {
    const inbox = join(ctx.tmp, "rr-human.jsonl");
    const errors = vi.spyOn(console, "error").mockImplementation(() => undefined);
    const listener = runListener(
      [
        "--channel", ctx.channelId,
        "--token", ctx.channelToken,
        "--session", ctx.alphaSession,
        "--origin", ctx.origin,
        "--status-json",
        "--inbox", inbox,
        "--quiet",
      ],
      1500,
    );
    await new Promise((resolve) => setTimeout(resolve, 200));
    await sendFromBeta(ctx, "deliver-human");
    await waitFor(() => messageLineCount(inbox) === 1);
    process.emit("SIGINT");
    await listener;
    expect(messageLineCount(inbox)).toBe(1);
    expect(errors.mock.calls.some(([line]) => String(line).includes('"state":"received"'))).toBe(true);
    expect(errors.mock.calls.some(([line]) => String(line).includes('"state":"filtered"'))).toBe(false);
    errors.mockRestore();
  });

  it("--format text: writes '[<from>] <text>' lines, newlines collapsed", async () => {
    const inbox = join(ctx.tmp, "rr-inbox.log");
    const listener = runListener(
      [
        "--channel", ctx.channelId,
        "--token", ctx.channelToken,
        "--session", ctx.alphaSession,
        "--origin", ctx.origin,
        "--inbox", inbox,
        "--format", "text",
        "--quiet",
      ],
      1500,
    );
    await new Promise((r) => setTimeout(r, 200));
    await sendFromBeta(ctx, "one-liner");
    await sendFromBeta(ctx, "multi\nline\nbody");
    await waitFor(() => messageLineCount(inbox) === 2);
    process.emit("SIGINT");
    await listener;
    expect(existsSync(inbox)).toBe(true);
    const lines = readFileSync(inbox, "utf8").trim().split("\n").filter((l) => !l.startsWith("⟲"));
    expect(lines).toEqual(["[beta] one-liner", "[beta] multi line body"]);
  });

  it("--format text: surfaces priority as a [priority] prefix", async () => {
    const inbox = join(ctx.tmp, "rr-prio.log");
    const listener = runListener(
      [
        "--channel", ctx.channelId,
        "--token", ctx.channelToken,
        "--session", ctx.alphaSession,
        "--origin", ctx.origin,
        "--inbox", inbox,
        "--format", "text",
        "--quiet",
      ],
      1500,
    );
    await new Promise((r) => setTimeout(r, 200));
    await sendFromBeta(ctx, "background update", "alpha", "low");
    await sendFromBeta(ctx, "regular thing", "alpha");
    await sendFromBeta(ctx, "wake up!", "alpha", "urgent");
    await waitFor(() => messageLineCount(inbox) === 3);
    process.emit("SIGINT");
    await listener;
    const lines = readFileSync(inbox, "utf8").trim().split("\n").filter((l) => !l.startsWith("⟲"));
    expect(lines).toEqual([
      "[low] [beta] background update",
      "[beta] regular thing",
      "[urgent] [beta] wake up!",
    ]);
  });

  it("--format text: appends suggested_replies as → [r1] [r2] suffix", async () => {
    const inbox = join(ctx.tmp, "rr-replies.log");
    const listener = runListener(
      [
        "--channel", ctx.channelId,
        "--token", ctx.channelToken,
        "--session", ctx.alphaSession,
        "--origin", ctx.origin,
        "--inbox", inbox,
        "--format", "text",
        "--quiet",
      ],
      1500,
    );
    await new Promise((r) => setTimeout(r, 200));
    await sendFromBeta(ctx, "deploy ahora?", "alpha", undefined, ["yes", "no", "show diff"]);
    await sendFromBeta(ctx, "no chips here", "alpha");
    await waitFor(() => messageLineCount(inbox) === 2);
    process.emit("SIGINT");
    await listener;
    const lines = readFileSync(inbox, "utf8").trim().split("\n").filter((l) => !l.startsWith("⟲"));
    expect(lines).toEqual([
      "[beta] deploy ahora?  → [yes] [no] [show diff]",
      "[beta] no chips here",
    ]);
  });

  it("--format jsonl: passes attachments through verbatim", async () => {
    const inbox = join(ctx.tmp, "rr-att.log");
    const listener = runListener(
      [
        "--channel", ctx.channelId,
        "--token", ctx.channelToken,
        "--session", ctx.alphaSession,
        "--origin", ctx.origin,
        "--inbox", inbox,
        "--quiet",
      ],
      1500,
    );
    await new Promise((r) => setTimeout(r, 200));
    // 1x1 transparent PNG, base64 ~68 chars
    const tinyPng =
      "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkAAIAAAoAAv/lxKUAAAAASUVORK5CYII=";
    await fetch(`${ctx.origin}/api/channels/${ctx.channelId}/send`, {
      method: "POST",
      headers: {
        "content-type": "application/json",
        authorization: `Bearer ${ctx.channelToken}`,
        "x-session-id": ctx.betaSession,
      },
      body: JSON.stringify({
        to: "alpha",
        text: "see attached",
        attachments: [{ mime: "image/png", data_base64: tinyPng, filename: "tiny.png" }],
      }),
    });
    await waitFor(() => messageLineCount(inbox) === 1);
    process.emit("SIGINT");
    await listener;
    const parsed = JSON.parse(readFileSync(inbox, "utf8").trim()) as {
      attachments?: { mime: string; data_base64: string; filename?: string }[];
    };
    expect(parsed.attachments).toBeTruthy();
    expect(parsed.attachments!).toHaveLength(1);
    expect(parsed.attachments![0].mime).toBe("image/png");
    expect(parsed.attachments![0].data_base64).toBe(tinyPng);
    expect(parsed.attachments![0].filename).toBe("tiny.png");
  });

  it("rejects attachments over the size cap (413)", async () => {
    // 600KB of valid base64 ('A' repeated produces valid base64)
    const huge = "A".repeat(600 * 1024);
    const res = await fetch(`${ctx.origin}/api/channels/${ctx.channelId}/send`, {
      method: "POST",
      headers: {
        "content-type": "application/json",
        authorization: `Bearer ${ctx.channelToken}`,
        "x-session-id": ctx.betaSession,
      },
      body: JSON.stringify({
        to: "alpha",
        text: "x",
        attachments: [{ mime: "image/png", data_base64: huge }],
      }),
    });
    expect(res.status).toBe(413);
    const body = (await res.json()) as { code: string };
    expect(body.code).toBe("invalid");
  });

  it("rejects attachments with non-allowlisted MIME (400)", async () => {
    const res = await fetch(`${ctx.origin}/api/channels/${ctx.channelId}/send`, {
      method: "POST",
      headers: {
        "content-type": "application/json",
        authorization: `Bearer ${ctx.channelToken}`,
        "x-session-id": ctx.betaSession,
      },
      body: JSON.stringify({
        to: "alpha",
        text: "x",
        attachments: [{ mime: "application/x-msdownload", data_base64: "AAAA" }],
      }),
    });
    expect(res.status).toBe(400);
  });

  it("--format jsonl: passes suggested_replies through verbatim", async () => {
    const inbox = join(ctx.tmp, "rr-replies-json.log");
    const listener = runListener(
      [
        "--channel", ctx.channelId,
        "--token", ctx.channelToken,
        "--session", ctx.alphaSession,
        "--origin", ctx.origin,
        "--inbox", inbox,
        "--quiet",
      ],
      1500,
    );
    await new Promise((r) => setTimeout(r, 200));
    await sendFromBeta(ctx, "approve?", "alpha", undefined, ["approve", "deny"]);
    await waitFor(() => messageLineCount(inbox) === 1);
    process.emit("SIGINT");
    await listener;
    const parsed = JSON.parse(readFileSync(inbox, "utf8").trim()) as { suggested_replies?: string[] };
    expect(parsed.suggested_replies).toEqual(["approve", "deny"]);
  });

  it("--min-priority filters out lower-priority messages entirely", async () => {
    const inbox = join(ctx.tmp, "rr-minprio.log");
    const listener = runListener(
      [
        "--channel", ctx.channelId,
        "--token", ctx.channelToken,
        "--session", ctx.alphaSession,
        "--origin", ctx.origin,
        "--inbox", inbox,
        "--format", "text",
        "--min-priority", "high",
        "--quiet",
      ],
      1500,
    );
    await new Promise((r) => setTimeout(r, 200));
    await sendFromBeta(ctx, "noise 1", "alpha", "low");
    await sendFromBeta(ctx, "noise 2", "alpha"); // default = rank 2 < high(3)
    await sendFromBeta(ctx, "signal!", "alpha", "high");
    await sendFromBeta(ctx, "EMERGENCY", "alpha", "urgent");
    await waitFor(() => messageLineCount(inbox) === 2);
    process.emit("SIGINT");
    await listener;
    const lines = readFileSync(inbox, "utf8").trim().split("\n").filter((l) => !l.startsWith("⟲"));
    expect(lines).toEqual([
      "[high] [beta] signal!",
      "[urgent] [beta] EMERGENCY",
    ]);
  });

  it("--on-message: spawns the hook with RR_* env vars set", async () => {
    const marker = join(ctx.tmp, "hook-marker.txt");
    // POSIX-friendly hook: append $RR_FROM:$RR_MESSAGE to a marker file.
    const hook = `printf '%s\\n' "$RR_FROM:$RR_MESSAGE" >> ${marker.replace(/'/g, "'\\''")}`;
    const listener = runListener(
      [
        "--channel", ctx.channelId,
        "--token", ctx.channelToken,
        "--session", ctx.alphaSession,
        "--origin", ctx.origin,
        "--on-message", hook,
        "--quiet",
      ],
      1500,
    );
    await new Promise((r) => setTimeout(r, 200));
    await sendFromBeta(ctx, "from-hook");
    await waitFor(() => existsSync(marker));
    process.emit("SIGINT");
    await listener;
    expect(existsSync(marker)).toBe(true);
    const out = readFileSync(marker, "utf8").trim();
    expect(out).toBe("beta:from-hook");
  });

  it("rejects bad bearer with non-zero exit", async () => {
    const listener = runListener(
      [
        "--channel", ctx.channelId,
        "--token", "wrong-token",
        "--session", ctx.alphaSession,
        "--origin", ctx.origin,
        "--quiet",
      ],
      1500,
    );
    const result = await listener;
    expect(result.code).toBe(1);
  });

  it("resets retry delay after a healthy stream and recognizes Railway rotation", () => {
    expect(planReconnect(60_000, 15 * 60_000, true, "stream_error")).toEqual({
      waitMs: 1_000,
      nextBackoffMs: 3_000,
      expectedRotation: true,
    });
    expect(planReconnect(3_000, 25, true, "stream_error")).toEqual({
      waitMs: 3_000,
      nextBackoffMs: 9_000,
      expectedRotation: false,
    });
  });

  it("reconnects from the latest delivered message after the SSE body fails", async () => {
    const messageId = 1_787_600_000_001;
    const requests: string[] = [];
    const streamServer = createHttpServer((request, response) => {
      requests.push(request.url ?? "");
      if (requests.length === 1) {
        response.writeHead(200, {
          "content-type": "text/event-stream",
          "cache-control": "no-cache",
          connection: "keep-alive",
          "x-railway-request-id": "request-test",
          "x-railway-edge": "edge-test",
        });
        response.write(`event: message\ndata: ${JSON.stringify({
          id: messageId,
          from: "beta",
          to: "alpha",
          text: "cursor-survives",
          at: messageId,
          sender_member_id: "member-beta",
          sender_endpoint_id: "endpoint-beta",
          author_kind: "human",
        })}\n\n`);
        setTimeout(() => response.destroy(), 25);
        return;
      }
      response.writeHead(401).end();
    });
    await new Promise<void>((resolve) => streamServer.listen(0, "127.0.0.1", resolve));
    const address = streamServer.address();
    if (!address || typeof address === "string") throw new Error("test server did not bind a TCP port");
    const errors = vi.spyOn(console, "error").mockImplementation(() => undefined);

    const result = await runListener(
      [
        "--channel", "cursor-test",
        "--token", "test-token",
        "--session", "test-session",
        "--origin", `http://127.0.0.1:${address.port}`,
        "--status-json",
        "--quiet",
      ],
      3500,
    );

    expect(result.code).toBe(1);
    expect(requests).toHaveLength(2);
    expect(requests[1]).toBe(`/api/channels/cursor-test/stream?since=${messageId}`);
    expect(errors.mock.calls.flat().join("\n")).toContain("connection error");
    const statusLines = errors.mock.calls.map(([line]) => String(line))
      .filter((line) => line.startsWith("@pijoo "))
      .map((line) => JSON.parse(line.slice("@pijoo ".length)) as Record<string, unknown>);
    expect(statusLines.find((event) => event.state === "error")).toMatchObject({
      kind: "connection",
    });
    expect(String(statusLines.find((event) => event.state === "error")?.diagnostic)).toContain(
      "request_id=request-test",
    );
    expect(statusLines.find((event) => event.state === "reconnecting")).toMatchObject({
      reason: "stream_error",
      delayMs: 1_000,
    });
    errors.mockRestore();
    await new Promise<void>((resolve) => streamServer.close(() => resolve()));
  });

  it("does not call the Host again when record_received reports already_processed", async () => {
    const socketPath = join(ctx.tmp, "codex-dedup.sock");
    const appSocketPath = join(ctx.tmp, "app-dedup.sock");
    const rpcServer = createServer();
    const appServer = createServer();
    let hostAttempts = 0;
    let receivedRecords = 0;
    const sequence: string[] = [];
    appServer.on("connection", (socket) => {
      let raw = "";
      socket.on("data", (chunk) => {
        raw += chunk.toString("utf8");
        const newline = raw.indexOf("\n");
        if (newline < 0) return;
        const request = JSON.parse(raw.slice(0, newline)) as {
          operation: string;
          event: { state: string };
        };
        sequence.push(`${request.operation}:${request.event.state}`);
        if (request.operation === "record_received") receivedRecords += 1;
        const message = request.operation === "record_received" && receivedRecords > 1
          ? "already_processed"
          : "recorded";
        socket.end(`${JSON.stringify({ version: 2, ok: true, result: { message } })}\n`);
      });
    });
    await new Promise<void>((resolve) => appServer.listen(appSocketPath, resolve));
    chmodSync(appSocketPath, 0o600);
    rpcServer.on("connection", (socket) => {
      readIpcFrames(socket, (message) => {
        if (message.type !== "request" || typeof message.method !== "string") return;
        const requestId = String(message.requestId);
        if (message.method === "initialize") {
          socket.write(ipcFrame({
            type: "response",
            requestId,
            resultType: "success",
            method: "initialize",
            result: { clientId: "bridge-client" },
          }));
        } else if (message.method === "thread-owner-discovery") {
          socket.write(ipcFrame({
            type: "response",
            requestId,
            resultType: "success",
            method: "thread-owner-discovery",
            handledByClientId: "desktop-owner",
            result: {},
          }));
        } else if (message.method === "thread-follower-steer-turn") {
          socket.write(ipcFrame({
            type: "response",
            requestId,
            resultType: "error",
            error: "no active turn",
          }));
        } else if (message.method === "thread-follower-start-turn") {
          hostAttempts += 1;
          socket.write(ipcFrame({
            type: "response",
            requestId,
            resultType: "success",
            method: "thread-follower-start-turn",
            handledByClientId: "desktop-owner",
            result: { result: { turn: { id: "turn-ok" } } },
          }));
        }
      });
    });
    await new Promise<void>((resolve) => rpcServer.listen(socketPath, resolve));

    const listenerArgs = [
      "--channel", ctx.channelId,
      "--token", ctx.channelToken,
      "--session", ctx.alphaSession,
      "--origin", ctx.origin,
      "--host-provider", "codex",
      "--host-conversation", "01900000-0000-7000-8000-000000000001",
      "--codex-socket", socketPath,
      "--app-socket", appSocketPath,
      "--subscription-id", "01900000-0000-7000-8000-000000000099",
      "--quiet",
    ];
    const first = runListener(listenerArgs, 2500);
    await new Promise((resolve) => setTimeout(resolve, 200));
    await sendFromBeta(ctx, "deliver-once");
    await waitFor(() => sequence.includes("record_outcome:delivered"));
    process.emit("SIGINT");
    await first;

    const replay = runListener([...listenerArgs, "--since", "0"], 2500);
    await waitFor(() => receivedRecords === 2);
    await new Promise((resolve) => setTimeout(resolve, 50));
    process.emit("SIGINT");
    const replayResult = await replay;

    expect(hostAttempts).toBe(1);
    expect(replayResult.code).toBe(0);
    expect(sequence).toEqual([
      "record_received:received",
      "record_outcome:attempting",
      "record_outcome:delivered",
      "record_received:received",
    ]);
    await new Promise<void>((resolve) => rpcServer.close(() => resolve()));
    await new Promise<void>((resolve) => appServer.close(() => resolve()));
  });

  it("stops without Host delivery when record_received reports unresolved", async () => {
    const appSocketPath = join(ctx.tmp, "app-unresolved.sock");
    const socketPath = join(ctx.tmp, "codex-unresolved.sock");
    const appServer = createServer((socket) => {
      socket.once("data", () => {
        socket.end(`${JSON.stringify({
          version: 2,
          ok: true,
          result: { message: "unresolved" },
        })}\n`);
      });
    });
    await new Promise<void>((resolve) => appServer.listen(appSocketPath, resolve));
    chmodSync(appSocketPath, 0o600);
    let hostRequests = 0;
    const rpcServer = createServer((socket) => {
      readIpcFrames(socket, (message) => {
        if (message.type !== "request" || typeof message.method !== "string") return;
        const requestId = String(message.requestId);
        if (message.method === "initialize") {
          socket.write(ipcFrame({
            type: "response",
            requestId,
            resultType: "success",
            method: "initialize",
            result: { clientId: "bridge-client" },
          }));
        } else if (message.method === "thread-owner-discovery") {
          socket.write(ipcFrame({
            type: "response",
            requestId,
            resultType: "success",
            method: "thread-owner-discovery",
            handledByClientId: "desktop-owner",
            result: {},
          }));
        } else {
          hostRequests += 1;
        }
      });
    });
    await new Promise<void>((resolve) => rpcServer.listen(socketPath, resolve));
    const errors = vi.spyOn(console, "error").mockImplementation(() => undefined);
    const listener = runListener(
      [
        "--channel", ctx.channelId,
        "--token", ctx.channelToken,
        "--session", ctx.alphaSession,
        "--origin", ctx.origin,
        "--host-provider", "codex",
        "--host-conversation", "01900000-0000-7000-8000-000000000001",
        "--codex-socket", socketPath,
        "--app-socket", appSocketPath,
        "--subscription-id", "01900000-0000-7000-8000-000000000099",
        "--quiet",
      ],
      2500,
    );
    await new Promise((resolve) => setTimeout(resolve, 200));
    await sendFromBeta(ctx, "wait-for-resolution");
    const result = await listener;

    expect(result.code).toBe(1);
    expect(hostRequests).toBe(0);
    expect(errors.mock.calls.flat().join("\n")).toContain("App reported unresolved delivery");
    errors.mockRestore();
    await new Promise<void>((resolve) => rpcServer.close(() => resolve()));
    await new Promise<void>((resolve) => appServer.close(() => resolve()));
  });

  it("retries a message after an explicit Codex rejection", async () => {
    const socketPath = join(ctx.tmp, "codex.sock");
    const appSocketPath = join(ctx.tmp, "app.sock");
    const rpcServer = createServer();
    const appServer = createServer();
    let attempts = 0;
    const received: string[] = [];
    const sequence: string[] = [];
    appServer.on("connection", (socket) => {
      let raw = "";
      socket.on("data", (chunk) => {
        raw += chunk.toString("utf8");
        const newline = raw.indexOf("\n");
        if (newline < 0) return;
        const request = JSON.parse(raw.slice(0, newline)) as {
          operation: string;
          event: { state: string };
        };
        sequence.push(`app:${request.operation}:${request.event.state}`);
        socket.end(`${JSON.stringify({ version: 2, ok: true, result: { message: "recorded" } })}\n`);
      });
    });
    await new Promise<void>((resolve) => appServer.listen(appSocketPath, resolve));
    chmodSync(appSocketPath, 0o600);
    rpcServer.on("connection", (socket) => {
      readIpcFrames(socket, (message) => {
        if (message.type !== "request" || typeof message.method !== "string") return;
        const requestId = String(message.requestId);
        if (message.method === "initialize") {
          socket.write(ipcFrame({
            type: "response",
            requestId,
            resultType: "success",
            method: "initialize",
            handledByClientId: "bridge-client",
            result: { clientId: "bridge-client" },
          }));
        } else if (message.method === "thread-owner-discovery") {
          socket.write(ipcFrame({
            type: "response",
            requestId,
            resultType: "success",
            method: "thread-owner-discovery",
            handledByClientId: "desktop-owner",
            result: {},
          }));
        } else if (message.method === "thread-follower-steer-turn") {
          socket.write(ipcFrame({
            type: "response",
            requestId,
            resultType: "error",
            error: "no active turn",
          }));
        } else if (message.method === "thread-follower-start-turn") {
          attempts += 1;
          sequence.push("host:start-turn");
          const params = message.params as {
            turnStart?: { request?: { input?: Array<{ text?: string }> } };
          };
          received.push(params.turnStart?.request?.input?.[0]?.text ?? "");
          socket.write(ipcFrame(attempts === 1
            ? {
                type: "response",
                requestId,
                resultType: "error",
                error: "temporary rejection",
              }
            : {
                type: "response",
                requestId,
                resultType: "success",
                method: "thread-follower-start-turn",
                handledByClientId: "desktop-owner",
                result: { result: { turn: { id: "turn-ok" } } },
              }));
        }
      });
    });
    await new Promise<void>((resolve) => rpcServer.listen(socketPath, resolve));

    const listener = runListener(
      [
        "--channel", ctx.channelId,
        "--token", ctx.channelToken,
        "--session", ctx.alphaSession,
        "--origin", ctx.origin,
        "--host-provider", "codex",
        "--host-conversation", "01900000-0000-7000-8000-000000000001",
        "--codex-socket", socketPath,
        "--app-socket", appSocketPath,
        "--subscription-id", "01900000-0000-7000-8000-000000000099",
        "--quiet",
      ],
      3500,
    );
    await new Promise((resolve) => setTimeout(resolve, 200));
    await sendFromBeta(ctx, "retry-me");
    await waitFor(() => attempts === 2, 2500);
    process.emit("SIGINT");
    await listener;
    expect(received).toHaveLength(2);
    expect(received[0]).toContain("> retry-me");
    expect(received[1]).toBe(received[0]);
    expect(sequence).toEqual([
      "app:record_received:received",
      "app:record_outcome:attempting",
      "host:start-turn",
      "app:record_outcome:failed",
      "app:record_received:received",
      "app:record_outcome:attempting",
      "host:start-turn",
      "app:record_outcome:delivered",
    ]);

    await new Promise<void>((resolve) => rpcServer.close(() => resolve()));
    await new Promise<void>((resolve) => appServer.close(() => resolve()));
  });

  it("stops instead of automatically replaying an uncertain Codex delivery", async () => {
    const socketPath = join(ctx.tmp, "codex-uncertain.sock");
    const rpcServer = createServer();
    let attempts = 0;
    rpcServer.on("connection", (socket) => {
      readIpcFrames(socket, (message) => {
        if (message.type !== "request" || typeof message.method !== "string") return;
        const requestId = String(message.requestId);
        if (message.method === "initialize") {
          socket.write(ipcFrame({
            type: "response",
            requestId,
            resultType: "success",
            method: "initialize",
            result: { clientId: "bridge-client" },
          }));
        } else if (message.method === "thread-owner-discovery") {
          socket.write(ipcFrame({
            type: "response",
            requestId,
            resultType: "success",
            method: "thread-owner-discovery",
            handledByClientId: "desktop-owner",
            result: {},
          }));
        } else if (message.method === "thread-follower-steer-turn") {
          attempts += 1;
          socket.write(ipcFrame({
            type: "response",
            requestId,
            resultType: "error",
            error: "request-timeout",
          }));
        }
      });
    });
    await new Promise<void>((resolve) => rpcServer.listen(socketPath, resolve));
    const error = vi.spyOn(console, "error").mockImplementation(() => undefined);

    const listener = runListener(
      [
        "--channel", ctx.channelId,
        "--token", ctx.channelToken,
        "--session", ctx.alphaSession,
        "--origin", ctx.origin,
        "--host-provider", "codex",
        "--host-conversation", "01900000-0000-7000-8000-000000000001",
        "--codex-socket", socketPath,
        "--quiet",
      ],
      2500,
    );
    await new Promise((resolve) => setTimeout(resolve, 200));
    await sendFromBeta(ctx, "maybe-delivered");
    const result = await listener;

    expect(result.code).toBe(1);
    expect(attempts).toBe(1);
    expect(error.mock.calls.flat().join("\n")).toContain("stopped without advancing the cursor");
    await new Promise<void>((resolve) => rpcServer.close(() => resolve()));
  });
});
