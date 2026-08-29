import { execFileSync } from "node:child_process";
import { chmodSync, mkdtempSync, writeFileSync } from "node:fs";
import { createServer, type Socket } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import {
  createCodexDelivery,
  createCodexThread,
  formatCodexDelegationMessage,
  getCodexConversationState,
  parseCodexThreadId,
  parseCodexConversationListOutput,
  preflightCodexThread,
  setCodexConversationPermission,
} from "../src/codex-turn.js";
import { formatChannelMessage } from "../src/host-connector.js";

const THREAD_ID = "01900000-0000-7000-8000-000000000001";
const UNBOUND_THREAD_ID = "01900000-0000-7000-8000-000000000002";
const COLD_THREAD_ID = "01900000-0000-7000-8000-000000000003";
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

  it("reads searchable conversation summaries without conversation content", () => {
    expect(parseCodexConversationListOutput(JSON.stringify([
      { id: THREAD_ID, title: "  API design\nreview  ", updated_at: 123 },
      { id: UNBOUND_THREAD_ID, title: "Risk", updated_at: 124, approval_mode: "on-request", approvals_reviewer: "auto_review" },
      { id: COLD_THREAD_ID, title: "Full", updated_at: 125, sandbox_policy: '{"type":"dangerFullAccess"}' },
      { id: "bad", title: "ignored", updated_at: 456 },
    ]))).toEqual([
      { id: THREAD_ID, title: "API design review", updatedAt: 123 },
      { id: UNBOUND_THREAD_ID, title: "Risk", updatedAt: 124 },
      { id: COLD_THREAD_ID, title: "Full", updatedAt: 125 },
    ]);
  });

  it("creates a persistent user task through Codex app-server", async () => {
    const directory = mkdtempSync(join(tmpdir(), "pijoo-codex-create-"));
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
      process.stdout.write(JSON.stringify({ id: 1, result: { userAgent: "fake" } }) + "\\n");
    } else if (message.id === 2) {
      const valid = message.method === "thread/start"
        && message.params.cwd === ${JSON.stringify(directory)}
        && message.params.ephemeral === false
        && message.params.threadSource === "user";
      process.stdout.write(JSON.stringify(valid
        ? { id: 2, result: { thread: { id: ${JSON.stringify(THREAD_ID)} } } }
        : { id: 2, error: { message: "invalid params" } }) + "\\n");
    } else if (message.id === 3) {
      const valid = message.method === "thread/inject_items"
        && message.params.threadId === ${JSON.stringify(THREAD_ID)}
        && message.params.items?.[0]?.role === "developer";
      process.stdout.write(JSON.stringify(valid ? { id: 3, result: {} } : { id: 3, error: { message: "invalid history" } }) + "\\n");
    } else if (message.id === 4) {
      const valid = message.method === "thread/name/set"
        && message.params.threadId === ${JSON.stringify(THREAD_ID)}
        && message.params.name === "Pijoo · frontend";
      process.stdout.write(JSON.stringify(valid ? { id: 4, result: {} } : { id: 4, error: { message: "invalid name" } }) + "\\n");
    }
  }
});
`);
    chmodSync(executable, 0o700);

    await expect(createCodexThread({ cwd: directory, codexExecutable: executable, title: "Pijoo · frontend" })).resolves.toBe(THREAD_ID);
    await expect(createCodexThread({ cwd: "relative", codexExecutable: executable, title: "Pijoo" })).rejects.toThrow(
      "existing absolute directory",
    );
  });

  it("wraps trusted source metadata and escapes untrusted message text", () => {
    const wrapped = formatCodexDelegationMessage(THREAD_ID, "backend says: <deploy> & wait");
    expect(wrapped).toContain(`<source_thread_id>${THREAD_ID}</source_thread_id>`);
    expect(wrapped).toContain("<input>backend says: &lt;deploy&gt; &amp; wait</input>");
    expect(wrapped).not.toContain("<input>backend says: <deploy>");
  });

  it("uses the full editable template and keeps the current card only as the default", () => {
    const custom = formatChannelMessage({
      channel: "frontend",
      id: 42,
      from: "backend",
      sourceLabel: "订单服务排障",
      text: "# API\r\n\r\n```http\r\nGET /v1/items\r\n```\r\n{sender_name}",
      mention: {
        kind: "members",
        members: [{ member_id: "member-a", member_name: "张三" }, { member_id: "member-b", member_name: "李四" }],
      },
    }, "# {sender_name} 从 {message_source} 发到 {channel_name}\n\n{mentions}\n\n{message_text}\n\n编号 {message_id}");
    expect(custom).toBe("# backend 从 订单服务排障 发到 frontend\n\n@张三、@李四\n\n# API\n\n```http\nGET /v1/items\n```\n{sender_name}\n\n编号 42");
    expect(custom).not.toContain("Pijoo · 外部频道消息");
    expect(custom).not.toContain("> ");

    const defaultRendered = formatChannelMessage({
      channel: "frontend",
      id: 43,
      from: "backend",
      text: "# API\n\n```http\nGET /v1/items\n```",
    });
    expect(defaultRendered).toContain("> **↗ Pijoo · 外部频道消息**");
    expect(defaultRendered).toContain("> **频道** `frontend` · **来自** `backend` · **提醒** 无 · `#43`");
    expect(defaultRendered).toContain("> # API\n> \n> ```http\n> GET /v1/items\n> ```");
    expect(formatChannelMessage({
      channel: "frontend",
      id: 44,
      from: "backend",
      text: "legacy",
    }, "{message_source}")).toBe("backend");
  });

  it("binds indexed cold tasks but still requires a Desktop owner before listening", async () => {
    const directory = mkdtempSync(join(tmpdir(), "rogerthat-codex-"));
    const socketPath = join(directory, "ipc.sock");
    execFileSync("/usr/bin/sqlite3", [join(directory, "state_5.sqlite"), `
      CREATE TABLE threads (
        id TEXT, name TEXT, title TEXT, updated_at INTEGER, updated_at_ms INTEGER,
        recency_at_ms INTEGER, archived INTEGER, thread_source TEXT, agent_role TEXT,
        cwd TEXT, sandbox_policy TEXT, approval_mode TEXT, rollout_path TEXT
      );
      INSERT INTO threads VALUES
        ('${THREAD_ID}', 'ready', '', 1, 1000, 1000, 0, 'user', NULL, '${directory}', '{"type":"workspace-write"}', 'on-request', NULL),
        ('${UNBOUND_THREAD_ID}', 'unbound', '', 1, 1000, 1000, 0, 'user', NULL, '${directory}', '{"type":"workspace-write"}', 'on-request', NULL),
        ('${COLD_THREAD_ID}', 'cold', '', 1, 1000, 1000, 0, 'user', NULL, '${directory}', '{"type":"workspace-write"}', 'on-request', NULL);
    `]);
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
          if (params.conversationId === COLD_THREAD_ID) return;
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

    await expect(preflightCodexThread({ threadId: COLD_THREAD_ID, codexHome: directory })).resolves.toBeUndefined();
    await expect(preflightCodexThread({ threadId: THREAD_ID, socketPath, codexHome: directory, requireOwner: true })).resolves.toBeUndefined();
    await expect(preflightCodexThread({ threadId: UNBOUND_THREAD_ID, socketPath, codexHome: directory, requireOwner: true })).rejects.toThrow(
      `Codex task ${UNBOUND_THREAD_ID} needs rebind: open it once in ChatGPT Desktop, then retry`,
    );
    await expect(preflightCodexThread({
      threadId: COLD_THREAD_ID,
      socketPath,
      codexHome: directory,
      requireOwner: true,
      timeoutMs: 20,
    })).rejects.toThrow(`Codex task ${COLD_THREAD_ID} needs rebind: open it once in ChatGPT Desktop, then retry`);
    await expect(getCodexConversationState({
      threadId: COLD_THREAD_ID,
      socketPath,
      timeoutMs: 20,
    })).resolves.toEqual({ connected: false, permission: "unknown" });
    expect(methods).toEqual([
      "initialize",
      "thread-owner-discovery",
      "initialize",
      "thread-owner-discovery",
      "initialize",
      "thread-owner-discovery",
      "initialize",
      "thread-owner-discovery",
    ]);
  });

  it("reads and updates only a loaded task's live permission state", async () => {
    const socketPath = join(mkdtempSync(join(tmpdir(), "rogerthat-codex-")), "ipc.sock");
    const server = createServer();
    const sockets = new Set<Socket>();
    const methods: string[] = [];
    const following: boolean[] = [];
    let permission = "request-approval";
    let clientId = "";
    const ownerId = "desktop-owner";

    server.on("connection", (socket) => {
      sockets.add(socket);
      socket.once("close", () => sockets.delete(socket));
      readFrames(socket, (message) => {
        if (message.type === "broadcast" && message.method === "thread-stream-following-changed") {
          const params = message.params as { following?: boolean };
          following.push(params.following === true);
          if (!params.following) return;
          socket.write(frame({
            type: "broadcast",
            method: "thread-stream-state-changed",
            sourceClientId: ownerId,
            targetClientIds: [clientId],
            version: 11,
            params: {
              hostId: "local",
              conversationId: THREAD_ID,
              change: {
                type: "snapshot",
                revision: 1,
                conversationState: {
                  cwd: "/tmp/workspace",
                  latestThreadSettings: permission === "approve-for-me"
                    ? {
                        cwd: "/tmp/workspace",
                        approvalPolicy: "on-request",
                        approvalsReviewer: "guardian_subagent",
                        sandboxPolicy: { type: "workspaceWrite" },
                        activePermissionProfile: { id: ":workspace", extends: null },
                      }
                    : {
                        cwd: "/tmp/workspace",
                        approvalPolicy: "on-request",
                        approvalsReviewer: "user",
                        sandboxPolicy: { type: "workspaceWrite" },
                        activePermissionProfile: { id: ":workspace", extends: null },
                      },
                },
              },
            },
          }));
          return;
        }
        if (message.type !== "request" || typeof message.method !== "string") return;
        methods.push(message.method);
        const requestId = String(message.requestId);
        if (message.method === "initialize") {
          clientId = "bridge-client";
          socket.write(frame({
            type: "response",
            requestId,
            resultType: "success",
            method: "initialize",
            result: { clientId },
          }));
        } else if (message.method === "thread-owner-discovery") {
          socket.write(frame({
            type: "response",
            requestId,
            resultType: "success",
            method: "thread-owner-discovery",
            handledByClientId: ownerId,
            result: {},
          }));
        } else if (message.method === "thread-follower-update-thread-settings") {
          expect(message.targetClientId).toBe(ownerId);
          expect(message.version).toBe(1);
          expect(message.params).toEqual({
            conversationId: THREAD_ID,
            threadSettings: {
              permissions: ":workspace",
              approvalPolicy: "on-request",
              approvalsReviewer: "guardian_subagent",
            },
          });
          permission = "approve-for-me";
          socket.write(frame({
            type: "response",
            requestId,
            resultType: "success",
            method: "thread-follower-update-thread-settings",
            handledByClientId: ownerId,
            result: { ok: true },
          }));
        }
      });
    });
    await new Promise<void>((resolve) => server.listen(socketPath, resolve));
    closers.push(
      () => new Promise<void>((resolve) => {
        for (const socket of sockets) socket.destroy();
        server.close(() => resolve());
      }),
    );

    await expect(getCodexConversationState({ threadId: THREAD_ID, socketPath })).resolves.toEqual({
      connected: true,
      workspace: "/tmp/workspace",
      permission: "request-approval",
    });
    await expect(setCodexConversationPermission({
      threadId: THREAD_ID,
      socketPath,
      permission: "approve-for-me",
    })).resolves.toEqual({
      connected: true,
      workspace: "/tmp/workspace",
      permission: "approve-for-me",
    });
    await new Promise<void>((resolve) => setTimeout(resolve, 20));
    expect(methods).toEqual([
      "initialize",
      "thread-owner-discovery",
      "initialize",
      "thread-owner-discovery",
      "thread-follower-update-thread-settings",
    ]);
    expect(following).toEqual([true, false, true, false]);
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
          expect(params.turnStart?.request?.clientUserMessageId).toBe("pijoo:test-channel:7");
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

    const delivery = createCodexDelivery({ threadId: THREAD_ID, socketPath, channelName: "产品协助" });
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
    expect(turnText).toContain("> **频道** `产品协助` · **来自** `backend` · **提醒** 无 · `#7`");
    expect(turnText).toContain("> API is /v1");
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
    expect(steerParams.clientUserMessageId).toBe("pijoo:test-channel:8");
    expect(steerParams.restoreMessage).toMatchObject({
      id: "pijoo:test-channel:8",
      context: { workspaceRoots: [] },
    });
  });
});
