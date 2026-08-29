import { join } from "node:path";
import { afterEach, describe, expect, it, vi } from "vitest";
import { serializeHostDelivery, type InboundEnvelope } from "../src/host-connector.js";
import { runListenHere } from "../src/listen-here.js";

const THREAD_ID = "01900000-0000-7000-8000-000000000001";

function message(messageId: number): InboundEnvelope {
  return {
    channelId: "test-channel",
    messageId,
    from: "backend",
    senderMemberId: "member-backend",
    text: `message-${messageId}`,
    receivedAt: Date.now(),
    untrusted: true,
  };
}

afterEach(() => vi.restoreAllMocks());

describe("Host delivery boundary", () => {
  it("serializes concurrent deliveries for one binding", async () => {
    const events: string[] = [];
    let releaseFirst!: () => void;
    const firstGate = new Promise<void>((resolve) => (releaseFirst = resolve));
    const deliver = serializeHostDelivery(async (envelope) => {
      events.push(`start:${envelope.messageId}`);
      if (envelope.messageId === 1) await firstGate;
      events.push(`end:${envelope.messageId}`);
      return { provider: "test", providerDeliveryId: String(envelope.messageId) };
    });

    const first = deliver(message(1));
    const second = deliver(message(2));
    await Promise.resolve();
    expect(events).toEqual(["start:1"]);

    releaseFirst();
    await Promise.all([first, second]);
    expect(events).toEqual(["start:1", "end:1", "start:2", "end:2"]);
  });

  it("continues the queue after one Host delivery fails", async () => {
    const delivered: number[] = [];
    const deliver = serializeHostDelivery(async (envelope) => {
      if (envelope.messageId === 1) throw new Error("Host unavailable");
      delivered.push(envelope.messageId);
      return { provider: "test" };
    });

    await expect(deliver(message(1))).rejects.toThrow("Host unavailable");
    await expect(deliver(message(2))).resolves.toEqual({ provider: "test" });
    expect(delivered).toEqual([2]);
  });

  it("fails closed for unsupported Host CLI options", async () => {
    const error = vi.spyOn(console, "error").mockImplementation(() => undefined);
    expect(await runListenHere([
      "--channel", "test-channel",
      "--token", "test-token",
      "--session", "test-session",
      "--host-provider", "claude",
      "--host-conversation", "test-conversation",
    ])).toBe(2);
    expect(error.mock.calls.flat().join("\n")).toContain("Unsupported Host provider: claude");
  });

  it("reports an unavailable Codex Host before opening the channel", async () => {
    const error = vi.spyOn(console, "error").mockImplementation(() => undefined);
    const code = await runListenHere([
      "--channel", "test-channel",
      "--token", "test-token",
      "--session", "test-session",
      "--host-provider", "codex",
      "--host-conversation", THREAD_ID,
      "--codex-socket", join("/tmp", "pijoo-missing.sock"),
    ]);
    expect(code).toBe(1);
    expect(error.mock.calls.flat().join("\n")).toContain("Codex Desktop IPC socket not found");
  });

  it("accepts approve-for-me for a managed listener", async () => {
    const error = vi.spyOn(console, "error").mockImplementation(() => undefined);
    expect(await runListenHere([
      "--channel", "test-channel",
      "--token", "test-token",
      "--session", "test-session",
      "--host-provider", "codex",
      "--host-conversation", THREAD_ID,
      "--expected-workspace", "/tmp/pijoo-managed",
      "--expected-permission", "approve-for-me",
      "--codex-socket", "/tmp/missing-codex-ipc.sock",
    ])).toBe(1);
    expect(error.mock.calls.flat().join("\n")).toContain("Codex Desktop IPC socket not found or unsafe");
  });
});
