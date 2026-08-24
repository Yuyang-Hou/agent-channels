import { randomUUID } from "node:crypto";
import { lstatSync } from "node:fs";
import { createConnection, type Socket } from "node:net";
import { homedir, tmpdir } from "node:os";
import { dirname, join } from "node:path";
import {
  DeliveryOutcomeUnknownError,
  serializeHostDelivery,
  type HostDelivery,
} from "./host-connector.js";

const CODEX_HOME = process.env.CODEX_HOME?.trim() || join(homedir(), ".codex");
export const DEFAULT_CODEX_SOCKET = process.platform === "win32"
  ? "\\\\.\\pipe\\codex-ipc"
  : join(CODEX_HOME, "ipc", "ipc.sock");
const FALLBACK_CODEX_SOCKET = join(
  tmpdir(),
  "codex-ipc",
  process.getuid?.() ? `ipc-${process.getuid?.()}.sock` : "ipc.sock",
);
const MAX_IPC_FRAME_BYTES = 256 * 1024 * 1024;
const INITIALIZING_CLIENT_ID = "initializing-client";
const START_TURN_BUSY_ERROR = "thread already has an active or pending turn";
const STEER_INACTIVE_ERROR = /active turn already ended|steerturninactiveerror|no active turn|noactiveturn/i;
const MUTATING_OUTCOME_UNKNOWN_ERRORS = new Set([
  "request-timeout",
  "client-disconnected",
  "server-closed",
]);

const THREAD_ID = /^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i;
const DEFAULT_CHANNEL_MESSAGE_TEMPLATE = [
  "> **↗ Agent Channels · 外部频道消息**",
  ">",
  "> **频道** `{channel_name}` · **来自** `{sender_name}` · `#{message_id}`",
  ">",
  "> {message_text}",
].join("\n");

export function parseCodexThreadId(value: string): string {
  const raw = value.trim();
  const id = raw.startsWith("codex://")
    ? (() => {
        const url = new URL(raw);
        if (url.protocol !== "codex:" || url.hostname !== "threads") throw new Error("invalid Codex task URL");
        return url.pathname.replace(/^\//, "");
      })()
    : raw;
  if (!THREAD_ID.test(id)) throw new Error("--codex-thread must be a task id or codex://threads/<id> URL");
  return id;
}

export function formatCodexChannelMessage(message: {
  channel: string;
  id: number;
  from: string;
  text: string;
  receivedAt?: number;
}, template?: string): string {
  const safeInlineValue = (value: string) => value.replace(/[\r\n]+/g, " ").replaceAll("`", "ˋ");
  const values: Record<string, string> = {
    "{channel_name}": safeInlineValue(message.channel),
    "{message_id}": String(message.id),
    "{sender_name}": safeInlineValue(message.from),
    "{message_text}": message.text.replace(/\r\n?/g, "\n"),
  };
  const source = (template || DEFAULT_CHANNEL_MESSAGE_TEMPLATE).replace(/\r\n?/g, "\n");
  return source.replace(
    /\{(?:channel_name|message_id|sender_name|message_text)\}/g,
    (key, offset: number) => {
      const value = values[key];
      const linePrefix = source.slice(source.lastIndexOf("\n", offset - 1) + 1, offset);
      const continuationPrefix = /^(?:[ \t]*>[ \t]?)+$/.test(linePrefix) ? linePrefix : "";
      return value.replaceAll("\n", `\n${continuationPrefix}`);
    },
  );
}

export function formatCodexDelegationMessage(sourceThreadId: string, input: string): string {
  const source = parseCodexThreadId(sourceThreadId);
  const escapeXml = (value: string) => value.replaceAll("&", "&amp;").replaceAll("<", "&lt;").replaceAll(">", "&gt;");
  return [
    "<codex_delegation>",
    `  <source_thread_id>${escapeXml(source)}</source_thread_id>`,
    `  <input>${escapeXml(input)}</input>`,
    "</codex_delegation>",
  ].join("\n");
}

export function createCodexDelivery(options: {
  threadId: string;
  sourceThreadId?: string;
  socketPath?: string;
  messageTemplate?: string;
}): HostDelivery {
  const threadId = parseCodexThreadId(options.threadId);
  const sourceThreadId = options.sourceThreadId
    ? parseCodexThreadId(options.sourceThreadId)
    : undefined;
  requireCodexSocket(options.socketPath);

  return serializeHostDelivery(async (message) => {
    const text = formatCodexChannelMessage({
      channel: message.channelId,
      id: message.messageId,
      from: message.from,
      text: message.text,
      receivedAt: message.receivedAt,
    }, options.messageTemplate);
    const turnId = await startCodexTurn({
      threadId,
      socketPath: options.socketPath,
      text: sourceThreadId ? formatCodexDelegationMessage(sourceThreadId, text) : text,
      clientUserMessageId: `agent-channels:${message.channelId}:${message.messageId}`,
    });
    return { provider: "codex", providerDeliveryId: turnId };
  });
}

type IpcResponse = {
  type: "response";
  requestId: string;
  resultType: "success" | "error";
  method?: string;
  handledByClientId?: string;
  result?: unknown;
  error?: string;
};

type PendingRequest = {
  requestId: string;
  timer: NodeJS.Timeout;
  resolve: (response: IpcResponse) => void;
  reject: (error: Error) => void;
};

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function isSecureUnixSocket(path: string): boolean {
  if (process.platform === "win32") return true;
  const uid = process.getuid?.();
  if (uid === undefined) return false;
  try {
    const socket = lstatSync(path);
    const parent = lstatSync(dirname(path));
    return socket.isSocket()
      && socket.uid === uid
      && parent.isDirectory()
      && parent.uid === uid
      && (parent.mode & 0o022) === 0;
  } catch {
    return false;
  }
}

function codexSocketCandidates(explicitPath?: string): string[] {
  const candidates = explicitPath?.trim()
    ? [explicitPath.trim()]
    : process.platform === "win32"
      ? [DEFAULT_CODEX_SOCKET]
      : [DEFAULT_CODEX_SOCKET, FALLBACK_CODEX_SOCKET];
  return [...new Set(candidates)].filter(isSecureUnixSocket);
}

function requireCodexSocket(explicitPath?: string): string[] {
  const candidates = codexSocketCandidates(explicitPath);
  if (candidates.length > 0) return candidates;
  if (explicitPath?.trim()) {
    throw new Error(`Codex Desktop IPC socket not found or unsafe: ${explicitPath.trim()}`);
  }
  throw new Error("Codex Desktop IPC socket not found. Open ChatGPT Desktop and retry.");
}

function connectSocket(path: string, timeoutMs: number): Promise<Socket> {
  return new Promise((resolve, reject) => {
    const socket = createConnection(path);
    const timer = setTimeout(() => {
      socket.destroy();
      reject(new Error(`timed out connecting to ${path}`));
    }, timeoutMs);
    const cleanup = () => {
      clearTimeout(timer);
      socket.off("connect", onConnect);
      socket.off("error", onError);
    };
    const onConnect = () => {
      cleanup();
      resolve(socket);
    };
    const onError = (error: Error) => {
      cleanup();
      socket.destroy();
      reject(error);
    };
    socket.once("connect", onConnect);
    socket.once("error", onError);
  });
}

async function connectCodexSocket(explicitPath: string | undefined, timeoutMs: number): Promise<Socket> {
  const errors: string[] = [];
  for (const path of requireCodexSocket(explicitPath)) {
    try {
      return await connectSocket(path, timeoutMs);
    } catch (error) {
      errors.push(`${path}: ${(error as Error).message}`);
    }
  }
  throw new Error(`Could not connect to ChatGPT Desktop IPC (${errors.join("; ")})`);
}

function writeFrame(socket: Socket, message: object): void {
  const payload = Buffer.from(JSON.stringify(message), "utf8");
  if (payload.length === 0 || payload.length > MAX_IPC_FRAME_BYTES) {
    throw new Error("Codex Desktop IPC frame exceeds the supported size");
  }
  const frame = Buffer.allocUnsafe(4 + payload.length);
  frame.writeUInt32LE(payload.length, 0);
  payload.copy(frame, 4);
  socket.write(frame);
}

function threadNeedsRebindError(threadId: string): Error {
  return new Error(`Codex task ${threadId} needs rebind: open it once in ChatGPT Desktop, then retry`);
}

function responseError(method: string, response: IpcResponse, threadId: string): Error {
  if (method === "thread-owner-discovery" && response.error === "no-client-found") {
    return threadNeedsRebindError(threadId);
  }
  return new Error(`Codex Desktop IPC ${method} failed: ${response.error ?? "unknown error"}`);
}

function assertMutatingOutcomeKnown(method: string, response: IpcResponse): void {
  if (response.resultType === "error" && MUTATING_OUTCOME_UNKNOWN_ERRORS.has(response.error ?? "")) {
    throw new DeliveryOutcomeUnknownError(
      `Codex Desktop IPC ${method} outcome is unknown: ${response.error}`,
    );
  }
}

type DesktopSessionBaseOptions = {
  threadId: string;
  discoveryTimeoutMs: number;
};

type DesktopPreflightOptions = DesktopSessionBaseOptions & {
  mode: "preflight";
};

type DesktopTurnOptions = DesktopSessionBaseOptions & {
  mode: "turn";
  text: string;
  clientUserMessageId: string;
  turnTimeoutMs: number;
};

async function runDesktopSession(socket: Socket, options: DesktopPreflightOptions): Promise<void>;
async function runDesktopSession(socket: Socket, options: DesktopTurnOptions): Promise<string>;
async function runDesktopSession(
  socket: Socket,
  options: DesktopPreflightOptions | DesktopTurnOptions,
): Promise<string | void> {
  let clientId = INITIALIZING_CLIENT_ID;
  let buffer: Buffer = Buffer.alloc(0);
  let pending: PendingRequest | undefined;
  let terminalError: Error | undefined;

  const fail = (error: Error) => {
    if (terminalError) return;
    terminalError = error;
    if (pending) {
      clearTimeout(pending.timer);
      pending.reject(error);
      pending = undefined;
    }
    socket.destroy();
  };

  const onMessage = (message: unknown) => {
    if (!isRecord(message)) return;
    if (message.type === "client-discovery-request" && typeof message.requestId === "string") {
      writeFrame(socket, {
        type: "client-discovery-response",
        requestId: message.requestId,
        response: { canHandle: false },
      });
      return;
    }
    if (message.type !== "response" || typeof message.requestId !== "string" || message.requestId !== pending?.requestId) {
      return;
    }
    const response = message as unknown as IpcResponse;
    clearTimeout(pending.timer);
    const resolve = pending.resolve;
    pending = undefined;
    resolve(response);
  };

  const onData = (chunk: Buffer) => {
    buffer = buffer.length === 0 ? chunk : Buffer.concat([buffer, chunk]);
    while (buffer.length >= 4) {
      const length = buffer.readUInt32LE(0);
      if (length === 0 || length > MAX_IPC_FRAME_BYTES) {
        fail(new Error(`Invalid Codex Desktop IPC frame length: ${length}`));
        return;
      }
      if (buffer.length < 4 + length) return;
      const payload = buffer.subarray(4, 4 + length);
      buffer = buffer.subarray(4 + length);
      try {
        onMessage(JSON.parse(payload.toString("utf8")));
      } catch (error) {
        fail(error instanceof Error ? error : new Error(String(error)));
        return;
      }
    }
  };
  const onError = (error: Error) => fail(error);
  const onClose = () => fail(new Error("ChatGPT Desktop IPC closed before completing the request"));
  socket.on("data", onData);
  socket.on("error", onError);
  socket.on("close", onClose);

  const request = (
    method: string,
    params: object,
    version: number,
    targetClientId?: string,
    timeoutMs = 5_000,
  ): Promise<IpcResponse> => {
    if (terminalError) return Promise.reject(terminalError);
    if (pending) return Promise.reject(new Error("Codex Desktop IPC request already pending"));
    const requestId = randomUUID();
    return new Promise((resolve, reject) => {
      const timer = setTimeout(
        () => fail(new Error(`Codex Desktop IPC ${method} timed out`)),
        timeoutMs,
      );
      pending = { requestId, timer, resolve, reject };
      try {
        writeFrame(socket, {
          type: "request",
          requestId,
          sourceClientId: clientId,
          version,
          method,
          params,
          ...(targetClientId ? { targetClientId } : {}),
          ...(method === "initialize" ? {} : { timeoutMs }),
        });
      } catch (error) {
        fail(error instanceof Error ? error : new Error(String(error)));
      }
    });
  };

  try {
    const initialized = await request(
      "initialize",
      { clientType: "agent-channels-cli" },
      0,
      undefined,
      options.discoveryTimeoutMs,
    );
    if (initialized.resultType !== "success") throw responseError("initialize", initialized, options.threadId);
    const initializedResult = isRecord(initialized.result) ? initialized.result : undefined;
    if (initialized.method !== "initialize" || typeof initializedResult?.clientId !== "string") {
      throw new Error("Codex Desktop IPC initialize returned an incompatible response");
    }
    clientId = initializedResult.clientId;

    const owner = await request(
      "thread-owner-discovery",
      { hostId: "local", conversationId: options.threadId },
      1,
      undefined,
      options.discoveryTimeoutMs,
    );
    if (owner.resultType !== "success") throw responseError("thread-owner-discovery", owner, options.threadId);
    if (typeof owner.handledByClientId !== "string") {
      throw threadNeedsRebindError(options.threadId);
    }
    if (options.mode === "preflight") return;

    const input = [{ type: "text", text: options.text, text_elements: [] }];
    const steer = async (): Promise<IpcResponse> => {
      try {
        const response = await request(
          "thread-follower-steer-turn",
          {
            conversationId: options.threadId,
            clientUserMessageId: options.clientUserMessageId,
            input,
            serviceTier: null,
            attachments: [],
            restoreMessage: {
              id: options.clientUserMessageId,
              text: options.text,
              context: {
                prompt: options.text,
                addedFiles: [],
                fileAttachments: [],
                commentAttachments: [],
                ideContext: null,
                imageAttachments: [],
                workspaceRoots: [],
              },
              createdAt: Date.now(),
            },
          },
          1,
          owner.handledByClientId,
          options.turnTimeoutMs,
        );
        assertMutatingOutcomeKnown("steer-turn", response);
        return response;
      } catch (error) {
        throw new DeliveryOutcomeUnknownError(
          `Codex Desktop IPC steer-turn outcome is unknown: ${(error as Error).message}`,
        );
      }
    };
    const steerTurnId = (response: IpcResponse): string => {
      const outer = isRecord(response.result) ? response.result : undefined;
      const inner = isRecord(outer?.result) ? outer.result : undefined;
      if (typeof inner?.turnId !== "string") {
        throw new DeliveryOutcomeUnknownError(
          "Codex Desktop IPC accepted steer-turn but returned an incompatible receipt",
        );
      }
      return inner.turnId;
    };

    let steered = await steer();
    if (steered.resultType === "success") return steerTurnId(steered);
    if (!STEER_INACTIVE_ERROR.test(steered.error ?? "")) {
      throw responseError("thread-follower-steer-turn", steered, options.threadId);
    }

    let started: IpcResponse;
    try {
      started = await request(
        "thread-follower-start-turn",
        {
          conversationId: options.threadId,
          turnStart: {
            request: {
              threadId: options.threadId,
              clientUserMessageId: options.clientUserMessageId,
              input,
            },
          },
        },
        2,
        owner.handledByClientId,
        options.turnTimeoutMs,
      );
      assertMutatingOutcomeKnown("start-turn", started);
    } catch (error) {
      throw new DeliveryOutcomeUnknownError(
        `Codex Desktop IPC start-turn outcome is unknown: ${(error as Error).message}`,
      );
    }
    if (started.resultType === "success") {
      const outer = isRecord(started.result) ? started.result : undefined;
      const inner = isRecord(outer?.result) ? outer.result : undefined;
      const turn = isRecord(inner?.turn) ? inner.turn : undefined;
      if (typeof turn?.id !== "string") {
        throw new DeliveryOutcomeUnknownError(
          "Codex Desktop IPC accepted start-turn but returned an incompatible receipt",
        );
      }
      return turn.id;
    }
    if (started.error === START_TURN_BUSY_ERROR) {
      steered = await steer();
      if (steered.resultType === "success") return steerTurnId(steered);
      throw responseError("thread-follower-steer-turn", steered, options.threadId);
    }
    throw responseError("thread-follower-start-turn", started, options.threadId);
  } finally {
    socket.off("data", onData);
    socket.off("error", onError);
    socket.off("close", onClose);
    if (pending) {
      clearTimeout(pending.timer);
      pending = undefined;
    }
    socket.destroy();
  }
}

export async function startCodexTurn(options: {
  threadId: string;
  text: string;
  clientUserMessageId?: string;
  socketPath?: string;
  timeoutMs?: number;
}): Promise<string> {
  const threadId = parseCodexThreadId(options.threadId);
  const socket = await connectCodexSocket(options.socketPath, 5_000);
  return runDesktopSession(socket, {
    mode: "turn",
    threadId,
    discoveryTimeoutMs: 5_000,
    text: options.text,
    clientUserMessageId: options.clientUserMessageId ?? randomUUID(),
    turnTimeoutMs: options.timeoutMs ?? 15_000,
  });
}

export async function preflightCodexThread(options: {
  threadId: string;
  socketPath?: string;
  timeoutMs?: number;
}): Promise<void> {
  const threadId = parseCodexThreadId(options.threadId);
  const timeoutMs = options.timeoutMs ?? 5_000;
  const socket = await connectCodexSocket(options.socketPath, timeoutMs);
  await runDesktopSession(socket, {
    mode: "preflight",
    threadId,
    discoveryTimeoutMs: timeoutMs,
  });
}
