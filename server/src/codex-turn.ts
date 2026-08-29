import { randomUUID } from "node:crypto";
import { execFile, spawn } from "node:child_process";
import { lstatSync, realpathSync } from "node:fs";
import { createConnection, type Socket } from "node:net";
import { homedir, tmpdir } from "node:os";
import { dirname, isAbsolute, join } from "node:path";
import {
  DeliveryOutcomeUnknownError,
  formatChannelMessage,
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
export function parseCodexThreadId(value: string): string {
  const raw = value.trim();
  const id = raw.startsWith("codex://")
    ? (() => {
        const url = new URL(raw);
        if (url.protocol !== "codex:" || url.hostname !== "threads") throw new Error("invalid Codex task URL");
        return url.pathname.replace(/^\//, "");
      })()
    : raw;
  if (!THREAD_ID.test(id)) throw new Error("Codex conversation must be a task id or codex://threads/<id> URL");
  return id;
}

export type CodexPermission = "request-approval" | "approve-for-me" | "full-access" | "unknown";

export type CodexConversationSummary = {
  id: string;
  title: string;
  updatedAt: number;
  workspace?: string;
};

export type CodexConversationState = {
  connected: boolean;
  workspace?: string;
  permission: CodexPermission;
};

function permissionState(
  approvalMode: unknown,
  approvalsReviewer: unknown,
  sandboxPolicy: unknown,
  activePermissionProfile?: unknown,
): CodexPermission {
  const sandboxType = isRecord(sandboxPolicy) ? sandboxPolicy.type : undefined;
  const profileId = isRecord(activePermissionProfile) ? activePermissionProfile.id : undefined;
  const dangerSandbox = sandboxType === "dangerFullAccess"
    || sandboxType === "danger-full-access"
    || profileId === ":danger-full-access";
  const workspaceSandbox = !dangerSandbox && (
    sandboxType === "workspaceWrite"
    || sandboxType === "workspace-write"
    || profileId === ":workspace"
  );
  if (
    approvalMode === "never" &&
    dangerSandbox
  ) return "full-access";
  if (
    approvalMode === "on-request" &&
    workspaceSandbox &&
    (approvalsReviewer === "auto_review" || approvalsReviewer === "guardian_subagent")
  ) return "approve-for-me";
  if (approvalMode === "on-request" && workspaceSandbox && approvalsReviewer === "user") return "request-approval";
  return "unknown";
}

export function parseCodexConversationListOutput(output: string): CodexConversationSummary[] {
  try {
    const rows = JSON.parse(output) as unknown;
    if (!Array.isArray(rows)) return [];
    return rows.flatMap((row) => {
      if (!isRecord(row) || typeof row.id !== "string" || !THREAD_ID.test(row.id)) return [];
      const title = typeof row.title === "string"
        ? row.title.trim().replace(/\s+/g, " ").slice(0, 200)
        : "";
      return [{
        id: row.id.toLowerCase(),
        title: title || row.id,
        updatedAt: typeof row.updated_at === "number" ? row.updated_at : 0,
        workspace: typeof row.cwd === "string" && isAbsolute(row.cwd) ? row.cwd : undefined,
      }];
    });
  } catch {
    return [];
  }
}

export async function listCodexConversations(options: {
  query?: string;
  limit?: number;
  codexHome?: string;
} = {}): Promise<CodexConversationSummary[]> {
  const database = join(options.codexHome ?? CODEX_HOME, "state_5.sqlite");
  const query = options.query?.trim().replaceAll("'", "''") ?? "";
  const limit = Math.max(1, Math.min(100, Math.floor(options.limit ?? 30)));
  const filter = query
    ? ` AND (LOWER(id) LIKE '%' || LOWER('${query}') || '%' OR LOWER(COALESCE(NULLIF(TRIM(name), ''), NULLIF(TRIM(title), ''), id)) LIKE '%' || LOWER('${query}') || '%')`
    : "";
  const sql = `SELECT id, COALESCE(NULLIF(TRIM(name), ''), NULLIF(TRIM(title), ''), id) AS title, COALESCE(updated_at_ms, updated_at * 1000) AS updated_at, cwd FROM threads WHERE archived = 0 AND (thread_source IS NULL OR thread_source = 'user') AND agent_role IS NULL${filter} ORDER BY recency_at_ms DESC, id DESC LIMIT ${limit}`;
  const output = await new Promise<string>((resolve, reject) => {
    execFile(
      "/usr/bin/sqlite3",
      ["-readonly", "-json", database, sql],
      { encoding: "utf8", maxBuffer: 512 * 1024 },
      (error, stdout) => error ? reject(error) : resolve(stdout),
    );
  });
  return parseCodexConversationListOutput(output);
}

export async function createCodexThread(options: {
  cwd: string;
  codexExecutable: string;
  title: string;
  timeoutMs?: number;
}): Promise<string> {
  const cwd = options.cwd.trim();
  const executable = options.codexExecutable.trim();
  const title = options.title.trim().replace(/\s+/g, " ").slice(0, 200);
  if (!isAbsolute(cwd) || !lstatSync(cwd).isDirectory()) {
    throw new Error("Codex workspace must be an existing absolute directory");
  }
  if (!isAbsolute(executable) || !lstatSync(executable).isFile()) {
    throw new Error("Codex executable must be an existing absolute file");
  }
  if (!title) throw new Error("Codex task title is required");

  return new Promise((resolve, reject) => {
    const child = spawn(executable, ["app-server", "--stdio"], {
      stdio: ["pipe", "pipe", "pipe"],
    });
    let buffer = "";
    let stderr = "";
    let threadId = "";
    let settled = false;
    const timer = setTimeout(
      () => fail(new Error("Codex app-server thread/start timed out")),
      options.timeoutMs ?? 15_000,
    );

    const finish = (threadId: string) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      child.stdin.end();
      const killTimer = setTimeout(() => child.kill(), 1_000);
      child.once("close", () => clearTimeout(killTimer));
      resolve(threadId);
    };
    function fail(error: Error): void {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      child.kill();
      reject(error);
    }
    const send = (message: object) => child.stdin.write(`${JSON.stringify(message)}\n`);
    const responseErrorMessage = (value: unknown): string => {
      if (isRecord(value) && typeof value.message === "string") return value.message;
      return typeof value === "string" ? value : JSON.stringify(value);
    };

    child.once("error", (error) => fail(error));
    child.stdin.once("error", (error) => fail(error));
    child.once("close", (code) => {
      if (!settled) {
        fail(new Error(`Codex app-server exited before creating a task (${code ?? "unknown"})${stderr ? `: ${stderr}` : ""}`));
      }
    });
    child.stderr.setEncoding("utf8");
    child.stderr.on("data", (chunk: string) => {
      stderr = `${stderr}${chunk}`.slice(-64 * 1024).trim();
    });
    child.stdout.setEncoding("utf8");
    child.stdout.on("data", (chunk: string) => {
      buffer += chunk;
      if (buffer.length > MAX_IPC_FRAME_BYTES) {
        fail(new Error("Codex app-server response exceeds the supported size"));
        return;
      }
      for (;;) {
        const newline = buffer.indexOf("\n");
        if (newline < 0) break;
        const line = buffer.slice(0, newline).trim();
        buffer = buffer.slice(newline + 1);
        if (!line) continue;
        let message: unknown;
        try {
          message = JSON.parse(line);
        } catch {
          fail(new Error("Codex app-server returned invalid JSON"));
          return;
        }
        if (!isRecord(message)) continue;
        if (message.id === 1) {
          if (message.error !== undefined) {
            fail(new Error(`Codex app-server initialize failed: ${responseErrorMessage(message.error)}`));
            return;
          }
          send({ method: "initialized", params: {} });
          send({
            id: 2,
            method: "thread/start",
            params: { cwd, ephemeral: false, threadSource: "user" },
          });
        } else if (message.id === 2) {
          if (message.error !== undefined) {
            fail(new Error(`Codex app-server thread/start failed: ${responseErrorMessage(message.error)}`));
            return;
          }
          const result = isRecord(message.result) ? message.result : undefined;
          const thread = isRecord(result?.thread) ? result.thread : undefined;
          if (typeof thread?.id !== "string" || !THREAD_ID.test(thread.id)) {
            fail(new Error("Codex app-server thread/start returned an incompatible response"));
            return;
          }
          threadId = thread.id.toLowerCase();
          send({
            id: 3,
            method: "thread/name/set",
            params: { threadId, name: title },
          });
        } else if (message.id === 3) {
          if (message.error !== undefined) {
            fail(new Error(`Codex app-server thread/name/set failed: ${responseErrorMessage(message.error)}`));
            return;
          }
          finish(threadId);
        }
      }
    });

    send({
      id: 1,
      method: "initialize",
      params: { clientInfo: { name: "pijoo", title: "Pijoo", version: "1" } },
    });
  });
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
  channelName?: string;
  messageTemplate?: string;
  expectedWorkspace?: string;
  expectedPermission?: Exclude<CodexPermission, "unknown">;
}): HostDelivery {
  const threadId = parseCodexThreadId(options.threadId);
  const sourceThreadId = options.sourceThreadId
    ? parseCodexThreadId(options.sourceThreadId)
    : undefined;
  requireCodexSocket(options.socketPath);

  return serializeHostDelivery(async (message) => {
    if (options.expectedWorkspace || options.expectedPermission) {
      const state = await getCodexConversationState({ threadId, socketPath: options.socketPath });
      if (!state.connected) throw new Error("Pijoo managed task is not connected");
      if (options.expectedWorkspace) {
        const workspace = state.workspace && realpathSync(state.workspace);
        if (workspace !== realpathSync(options.expectedWorkspace)) {
          throw new Error("Pijoo managed task workspace changed; restore it in the local app");
        }
      }
      if (options.expectedPermission && state.permission !== options.expectedPermission) {
        throw new Error("Pijoo managed task permission changed; restore it in the local app");
      }
    }
    const text = formatChannelMessage({
      channel: options.channelName || message.channelId,
      id: message.messageId,
      from: message.from,
      sourceLabel: message.source?.label,
      text: message.text,
      mention: message.mention,
    }, options.messageTemplate);
    const turnId = await startCodexTurn({
      threadId,
      socketPath: options.socketPath,
      text: sourceThreadId ? formatCodexDelegationMessage(sourceThreadId, text) : text,
      clientUserMessageId: `pijoo:${message.channelId}:${message.messageId}`,
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

type PendingSnapshot = {
  timer: NodeJS.Timeout;
  resolve: (state: CodexConversationState) => void;
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

function writeFrame(socket: Socket, message: object, flushed?: () => void): void {
  const payload = Buffer.from(JSON.stringify(message), "utf8");
  if (payload.length === 0 || payload.length > MAX_IPC_FRAME_BYTES) {
    throw new Error("Codex Desktop IPC frame exceeds the supported size");
  }
  const frame = Buffer.allocUnsafe(4 + payload.length);
  frame.writeUInt32LE(payload.length, 0);
  payload.copy(frame, 4);
  socket.write(frame, flushed);
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

type DesktopStateOptions = DesktopSessionBaseOptions & {
  mode: "state";
};

type DesktopPermissionOptions = DesktopSessionBaseOptions & {
  mode: "permission";
  permission: Exclude<CodexPermission, "unknown">;
};

function permissionSettings(permission: DesktopPermissionOptions["permission"]): Record<string, unknown> {
  switch (permission) {
    case "request-approval":
      return { permissions: ":workspace", approvalPolicy: "on-request", approvalsReviewer: "user" };
    case "approve-for-me":
      return { permissions: ":workspace", approvalPolicy: "on-request", approvalsReviewer: "guardian_subagent" };
    case "full-access":
      return { permissions: ":danger-full-access", approvalPolicy: "never", approvalsReviewer: "user" };
  }
}

function snapshotState(message: Record<string, unknown>, threadId: string): CodexConversationState | undefined {
  if (message.type !== "broadcast" || message.method !== "thread-stream-state-changed") return undefined;
  const params = isRecord(message.params) ? message.params : undefined;
  const change = isRecord(params?.change) ? params.change : undefined;
  const conversation = isRecord(change?.conversationState) ? change.conversationState : undefined;
  if (params?.hostId !== "local" || params?.conversationId !== threadId || change?.type !== "snapshot" || !conversation) {
    return undefined;
  }
  const settings = isRecord(conversation.latestThreadSettings) ? conversation.latestThreadSettings : undefined;
  const workspace = typeof settings?.cwd === "string" && isAbsolute(settings.cwd)
    ? settings.cwd
    : typeof conversation.cwd === "string" && isAbsolute(conversation.cwd)
      ? conversation.cwd
      : undefined;
  return {
    connected: true,
    workspace,
    permission: permissionState(
      settings?.approvalPolicy,
      settings?.approvalsReviewer,
      settings?.sandboxPolicy,
      settings?.activePermissionProfile,
    ),
  };
}

async function runDesktopSession(socket: Socket, options: DesktopPreflightOptions): Promise<void>;
async function runDesktopSession(socket: Socket, options: DesktopTurnOptions): Promise<string>;
async function runDesktopSession(socket: Socket, options: DesktopStateOptions | DesktopPermissionOptions): Promise<CodexConversationState>;
async function runDesktopSession(
  socket: Socket,
  options: DesktopPreflightOptions | DesktopTurnOptions | DesktopStateOptions | DesktopPermissionOptions,
): Promise<string | void | CodexConversationState> {
  let clientId = INITIALIZING_CLIENT_ID;
  let buffer: Buffer = Buffer.alloc(0);
  let pending: PendingRequest | undefined;
  let pendingSnapshot: PendingSnapshot | undefined;
  let terminalError: Error | undefined;

  const fail = (error: Error) => {
    if (terminalError) return;
    terminalError = error;
    if (pending) {
      clearTimeout(pending.timer);
      pending.reject(error);
      pending = undefined;
    }
    if (pendingSnapshot) {
      clearTimeout(pendingSnapshot.timer);
      pendingSnapshot.reject(error);
      pendingSnapshot = undefined;
    }
    socket.destroy();
  };

  const onMessage = (message: unknown) => {
    if (!isRecord(message)) return;
    if (pendingSnapshot) {
      const state = snapshotState(message, options.threadId);
      if (state) {
        clearTimeout(pendingSnapshot.timer);
        const resolve = pendingSnapshot.resolve;
        pendingSnapshot = undefined;
        resolve(state);
        return;
      }
    }
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

  const readState = async (ownerClientId: string): Promise<CodexConversationState> => {
    if (pendingSnapshot) throw new Error("Codex Desktop IPC snapshot request already pending");
    const state = new Promise<CodexConversationState>((resolve, reject) => {
      const timer = setTimeout(
        () => fail(new Error("Codex Desktop IPC thread settings snapshot timed out")),
        options.discoveryTimeoutMs,
      );
      pendingSnapshot = { timer, resolve, reject };
    });
    writeFrame(socket, {
      type: "broadcast",
      method: "thread-stream-following-changed",
      sourceClientId: clientId,
      targetClientIds: [ownerClientId],
      version: 1,
      params: { hostId: "local", conversationId: options.threadId, following: true },
    });
    try {
      return await state;
    } finally {
      if (!socket.destroyed) {
        await new Promise<void>((resolve) => writeFrame(
          socket,
          {
            type: "broadcast",
            method: "thread-stream-following-changed",
            sourceClientId: clientId,
            targetClientIds: [ownerClientId],
            version: 1,
            params: { hostId: "local", conversationId: options.threadId, following: false },
          },
          resolve,
        ));
      }
    }
  };

  try {
    const initialized = await request(
      "initialize",
      { clientType: "pijoo-cli" },
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

    let owner: IpcResponse;
    try {
      owner = await request(
        "thread-owner-discovery",
        { hostId: "local", conversationId: options.threadId },
        1,
        undefined,
        options.discoveryTimeoutMs,
      );
    } catch (error) {
      if ((error as Error).message === "Codex Desktop IPC thread-owner-discovery timed out") {
        throw threadNeedsRebindError(options.threadId);
      }
      throw error;
    }
    if (owner.resultType !== "success") throw responseError("thread-owner-discovery", owner, options.threadId);
    if (typeof owner.handledByClientId !== "string") {
      throw threadNeedsRebindError(options.threadId);
    }
    if (options.mode === "preflight") return;
    if (options.mode === "state") return await readState(owner.handledByClientId);
    if (options.mode === "permission") {
      const updated = await request(
        "thread-follower-update-thread-settings",
        {
          conversationId: options.threadId,
          threadSettings: permissionSettings(options.permission),
        },
        1,
        owner.handledByClientId,
        options.discoveryTimeoutMs,
      );
      assertMutatingOutcomeKnown("update-thread-settings", updated);
      const receipt = isRecord(updated.result) ? updated.result : undefined;
      if (updated.resultType !== "success" || receipt?.ok !== true) {
        throw responseError("thread-follower-update-thread-settings", updated, options.threadId);
      }
      return await readState(owner.handledByClientId);
    }

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
    if (pendingSnapshot) {
      clearTimeout(pendingSnapshot.timer);
      pendingSnapshot = undefined;
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
  codexHome?: string;
  requireOwner?: boolean;
}): Promise<void> {
  const threadId = parseCodexThreadId(options.threadId);
  const indexed = await listCodexConversations({ query: threadId, limit: 1, codexHome: options.codexHome });
  if (!indexed.some((conversation) => conversation.id === threadId)) {
    throw new Error(`Codex task ${threadId} was not found`);
  }
  if (!options.requireOwner) return;
  const timeoutMs = options.timeoutMs ?? 5_000;
  const socket = await connectCodexSocket(options.socketPath, timeoutMs);
  await runDesktopSession(socket, {
    mode: "preflight",
    threadId,
    discoveryTimeoutMs: timeoutMs,
  });
}

export async function getCodexConversationState(options: {
  threadId: string;
  socketPath?: string;
  timeoutMs?: number;
}): Promise<CodexConversationState> {
  const threadId = parseCodexThreadId(options.threadId);
  const timeoutMs = options.timeoutMs ?? 1_000;
  try {
    const socket = await connectCodexSocket(options.socketPath, timeoutMs);
    return await runDesktopSession(socket, {
      mode: "state",
      threadId,
      discoveryTimeoutMs: timeoutMs,
    });
  } catch {
    return { connected: false, permission: "unknown" };
  }
}

export async function setCodexConversationPermission(options: {
  threadId: string;
  permission: Exclude<CodexPermission, "unknown">;
  socketPath?: string;
  timeoutMs?: number;
}): Promise<CodexConversationState> {
  const threadId = parseCodexThreadId(options.threadId);
  const timeoutMs = options.timeoutMs ?? 5_000;
  const socket = await connectCodexSocket(options.socketPath, timeoutMs);
  return runDesktopSession(socket, {
    mode: "permission",
    threadId,
    discoveryTimeoutMs: timeoutMs,
    permission: options.permission,
  });
}
