import { mkdtempSync } from "node:fs";
import { createServer, type Socket } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import {
  createCodexDelivery,
  formatCodexDelegationMessage,
  parseCodexThreadId,
  preflightCodexThread,
} from "../src/codex-turn.js";

const THREAD_ID = "01900000-0000-7000-8000-000000000001";
const UNBOUND_THREAD_ID = "01900000-0000-7000-8000-000000000002";
const closers: Array<() => Promise<void>> = [];

function frame(message: object): Buffer {
  const payload = Buffer.from(JSON.stringify(message), "utf8");
  const encoded = Buffer.allocUnsafe(4 + payload.length);
  encoded.writeUInt32LE(payload.length, 0);
  payload.copy(encoded, 4);
  return encoded;
}

function readFrames(socket: Socket, onMessage: (message: Record<string, unknown>) => void): void {
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

afterEach(async () => {
  await Promise.all(closers.splice(0).map((close) => close()));
});

describe("Codex task bridge", () => {
  it("accepts task ids and codex:// task URLs", () => {
    expect(parseCodexThreadId(THREAD_ID)).toBe(THREAD_ID);
    expect(parseCodexThreadId(`codex://threads/${THREAD_ID}`)).toBe(THREAD_ID);
    expect(() => parseCodexThreadId("codex://wrong/nope")).toThrow();
  });

  it("wraps trusted source metadata and escapes untrusted message text", () => {
    const wrapped = formatCodexDelegationMessage(THREAD_ID, "backend says: <deploy> & wait");
    expect(wrapped).toContain(`<source_thread_id>${THREAD_ID}</source_thread_id>`);
    expect(wrapped).toContain("<input>backend says: &lt;deploy&gt; &amp; wait</input>");
    expect(wrapped).not.toContain("<input>backend says: <deploy>");
  });

  it("preflights only owner discovery and explains when the task needs rebind", async () => {
    const socketPath = join(mkdtempSync(join(tmpdir(), "rogerthat-codex-")), "ipc.sock");
    const server = createServer();
    const methods: string[] = [];
    const sockets = new Set<Socket>();
    server.on("connection", (socket) => {
      sockets.add(socket);
      socket.once("close", () => sockets.delete(socket));
      readFrames(socket, (message) => {
        if (message.type !== "request" || typeof message.method !== "string") return;
        methods.push(message.method);
        const requestId = String(message.requestId);
        if (message.method === "initialize") {
          socket.write(frame({
            type: "response",
            requestId,
            resultType: "success",
            method: "initialize",
            result: { clientId: "bridge-client" },
          }));
        } else if (message.method === "thread-owner-discovery") {
          const params = message.params as { conversationId?: string };
          socket.write(frame(params.conversationId === THREAD_ID
            ? {
                type: "response",
                requestId,
                resultType: "success",
                method: "thread-owner-discovery",
                handledByClientId: "desktop-owner",
                result: {},
              }
            : {
                type: "response",
                requestId,
                resultType: "error",
                method: "thread-owner-discovery",
                error: "no-client-found",
              }));
        }
      });
    });
    await new Promise<void>((resolve) => server.listen(socketPath, resolve));
    closers.push(
      () =>
        new Promise<void>((resolve) => {
          for (const socket of sockets) socket.destroy();
          server.close(() => resolve());
        }),
    );

    await expect(preflightCodexThread({ threadId: THREAD_ID, socketPath })).resolves.toBeUndefined();
    await expect(preflightCodexThread({ threadId: UNBOUND_THREAD_ID, socketPath })).rejects.toThrow(
      `Codex task ${UNBOUND_THREAD_ID} needs rebind: open it once in ChatGPT Desktop, then retry`,
    );
    expect(methods).toEqual([
      "initialize",
      "thread-owner-discovery",
      "initialize",
      "thread-owner-discovery",
    ]);
  });

  it("discovers the Desktop owner and starts exactly one targeted turn", async () => {
    const socketPath = join(mkdtempSync(join(tmpdir(), "rogerthat-codex-")), "ipc.sock");
    const server = createServer();
    const methods: string[] = [];
    let turnText = "";
    let probeRejected = false;
    let startTarget = "";
    const clientId = "bridge-client";
    const ownerId = "desktop-owner";
    const sockets = new Set<Socket>();
    server.on("connection", (socket) => {
      sockets.add(socket);
      socket.once("close", () => sockets.delete(socket));
      readFrames(socket, (message) => {
        if (message.type === "client-discovery-response") {
          const response = message.response as { canHandle?: boolean };
          probeRejected = response.canHandle === false;
          return;
        }
        if (message.type !== "request" || typeof message.method !== "string") return;
        methods.push(message.method);
        const requestId = String(message.requestId);
        if (message.method === "initialize") {
          expect(message.version).toBe(0);
          const responses = Buffer.concat([
            frame({
              type: "response",
              requestId,
              resultType: "success",
              method: "initialize",
              handledByClientId: clientId,
              result: { clientId },
            }),
            frame({
              type: "client-discovery-request",
              requestId: "probe-1",
              request: { method: "unrelated-request" },
            }),
          ]);
          socket.write(responses.subarray(0, 3));
          socket.write(responses.subarray(3));
        } else if (message.method === "thread-owner-discovery") {
          expect(message.version).toBe(1);
          expect(message.sourceClientId).toBe(clientId);
          expect(message.params).toEqual({ hostId: "local", conversationId: THREAD_ID });
          socket.write(frame({
            type: "response",
            requestId,
            resultType: "success",
            method: "thread-owner-discovery",
            handledByClientId: ownerId,
            result: {},
          }));
        } else if (message.method === "thread-follower-steer-turn") {
          socket.write(frame({
            type: "response",
            requestId,
            resultType: "error",
            error: "no active turn",
          }));
        } else if (message.method === "thread-follower-start-turn") {
          expect(message.version).toBe(2);
          startTarget = String(message.targetClientId);
          const params = message.params as {
            turnStart?: { request?: { clientUserMessageId?: string; input?: Array<{ text?: string }> } };
          };
          expect(params.turnStart?.request?.clientUserMessageId).toBe("agent-channels:test-channel:7");
          turnText = params.turnStart?.request?.input?.[0]?.text ?? "";
          socket.write(frame({
            type: "response",
            requestId,
            resultType: "success",
            method: "thread-follower-start-turn",
            handledByClientId: ownerId,
            result: { result: { turn: { id: "turn-test", status: "inProgress" } } },
          }));
        }
      });
    });
    await new Promise<void>((resolve) => server.listen(socketPath, resolve));
    closers.push(
      () =>
        new Promise<void>((resolve) => {
          for (const socket of sockets) socket.destroy();
          server.close(() => resolve());
        }),
    );

    const delivery = createCodexDelivery({ threadId: THREAD_ID, socketPath });
    const receipt = await delivery({
      channelId: "test-channel",
      messageId: 7,
      from: "backend",
      text: "API is /v1",
      receivedAt: Date.now(),
      untrusted: true,
    });

    expect(receipt).toEqual({ provider: "codex", providerDeliveryId: "turn-test" });
    expect(methods).toEqual([
      "initialize",
      "thread-owner-discovery",
      "thread-follower-steer-turn",
      "thread-follower-start-turn",
    ]);
    expect(probeRejected).toBe(true);
    expect(startTarget).toBe(ownerId);
    expect(turnText).toContain('"from":"backend"');
    expect(turnText).toContain('"text":"API is /v1"');
    expect(turnText).not.toContain("reply_ref");
    expect(turnText).not.toContain("reply_to_message");
  });

  it("steers a busy task instead of waiting for its active turn to finish", async () => {
    const socketPath = join(mkdtempSync(join(tmpdir(), "rogerthat-codex-")), "ipc.sock");
    const server = createServer();
    const methods: string[] = [];
    const sockets = new Set<Socket>();
    let steerParams: Record<string, unknown> = {};
    server.on("connection", (socket) => {
      sockets.add(socket);
      socket.once("close", () => sockets.delete(socket));
      readFrames(socket, (message) => {
        if (message.type !== "request" || typeof message.method !== "string") return;
        methods.push(message.method);
        const requestId = String(message.requestId);
        if (message.method === "initialize") {
          socket.write(frame({
            type: "response",
            requestId,
            resultType: "success",
            method: "initialize",
            result: { clientId: "bridge-client" },
          }));
        } else if (message.method === "thread-owner-discovery") {
          socket.write(frame({
            type: "response",
            requestId,
            resultType: "success",
            method: "thread-owner-discovery",
            handledByClientId: "desktop-owner",
            result: {},
          }));
        } else if (message.method === "thread-follower-steer-turn") {
          expect(message.version).toBe(1);
          expect(message.targetClientId).toBe("desktop-owner");
          steerParams = message.params as Record<string, unknown>;
          socket.write(frame({
            type: "response",
            requestId,
            resultType: "success",
            method: "thread-follower-steer-turn",
            handledByClientId: "desktop-owner",
            result: { result: { turnId: "active-turn" } },
          }));
        }
      });
    });
    await new Promise<void>((resolve) => server.listen(socketPath, resolve));
    closers.push(
      () =>
        new Promise<void>((resolve) => {
          for (const socket of sockets) socket.destroy();
          server.close(() => resolve());
        }),
    );

    const delivery = createCodexDelivery({ threadId: THREAD_ID, socketPath });
    await expect(delivery({
      channelId: "test-channel",
      messageId: 8,
      from: "backend",
      text: "busy update",
      receivedAt: Date.now(),
      untrusted: true,
    })).resolves.toEqual({ provider: "codex", providerDeliveryId: "active-turn" });

    expect(methods).toEqual([
      "initialize",
      "thread-owner-discovery",
      "thread-follower-steer-turn",
    ]);
    expect(steerParams.clientUserMessageId).toBe("agent-channels:test-channel:8");
    expect(steerParams.restoreMessage).toMatchObject({
      id: "agent-channels:test-channel:8",
      context: { workspaceRoots: [] },
    });
  });
});
