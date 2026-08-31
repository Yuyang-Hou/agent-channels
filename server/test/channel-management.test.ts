import { describe, expect, it, vi } from "vitest";
import { createApp } from "../src/app.js";

const ORIGIN = "http://test.local";

type Channel = {
  id: string;
  ownerId: string;
  ownerCredential: string;
};

type Member = { id: string; credential: string };
type Joined = {
  sessionId: string;
  memberId: string;
  endpointId: string;
};

function app() {
  return createApp({ publicOrigin: ORIGIN, authRequired: true });
}

async function createChannel(instance: ReturnType<typeof app>): Promise<Channel> {
  const response = await instance.request("/api/channels", { method: "POST" });
  expect(response.status).toBe(200);
  const body = (await response.json()) as {
    channel_id: string;
    member_id: string;
    member_credential: string;
    join_token: string;
  };
  expect(body.member_credential).toBe(body.join_token);
  return { id: body.channel_id, ownerId: body.member_id, ownerCredential: body.member_credential };
}

async function inviteMember(
  instance: ReturnType<typeof app>,
  channel: Channel,
  name = "Peer",
): Promise<Member> {
  const invited = await instance.request(`/api/channels/${channel.id}/invites`, {
    method: "POST",
    headers: { authorization: `Bearer ${channel.ownerCredential}` },
  });
  expect(invited.status).toBe(200);
  const invitation = (await invited.json()) as { invite_token: string };
  const redeemed = await instance.request(`/api/channels/${channel.id}/invites/redeem`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ invite_token: invitation.invite_token, name }),
  });
  expect(redeemed.status).toBe(200);
  const member = (await redeemed.json()) as { member_id: string; member_credential: string };
  return { id: member.member_id, credential: member.member_credential };
}

async function joinDetails(
  instance: ReturnType<typeof app>,
  channelId: string,
  credential: string,
  callsign: string,
  sessionId?: string,
  name?: string,
  authorKind: "human" | "channel_ai" = "human",
): Promise<Joined> {
  const response = await instance.request(`/api/channels/${channelId}/join`, {
    method: "POST",
    headers: {
      authorization: `Bearer ${credential}`,
      "content-type": "application/json",
      ...(sessionId ? { "x-session-id": sessionId } : {}),
    },
    body: JSON.stringify({ callsign, author_kind: authorKind, ...(name ? { name } : {}) }),
  });
  expect(response.status).toBe(200);
  const body = (await response.json()) as {
    session_id: string;
    member_id: string;
    endpoint_id: string;
  };
  return {
    sessionId: body.session_id,
    memberId: body.member_id,
    endpointId: body.endpoint_id,
  };
}

async function join(
  instance: ReturnType<typeof app>,
  channelId: string,
  credential: string,
  callsign: string,
): Promise<string> {
  return (await joinDetails(instance, channelId, credential, callsign)).sessionId;
}

async function send(
  instance: ReturnType<typeof app>,
  channelId: string,
  credential: string,
  sessionId: string,
  message: string,
  mentions?: string[],
): Promise<Response> {
  return instance.request(`/api/channels/${channelId}/send`, {
    method: "POST",
    headers: {
      authorization: `Bearer ${credential}`,
      "x-session-id": sessionId,
      "content-type": "application/json",
    },
    body: JSON.stringify({ to: "all", message, ...(mentions ? { mentions } : {}) }),
  });
}

describe("managed channel members", () => {
  it("attributes AI messages to any authenticated channel member", async () => {
    const instance = app();
    const channel = await createChannel(instance);
    const member = await inviteMember(instance, channel, "小王");
    const ai = await joinDetails(instance, channel.id, member.credential, "peer_ai", undefined, undefined, "channel_ai");
    const sent = await send(instance, channel.id, member.credential, ai.sessionId, "AI reply");
    expect(sent.status).toBe(200);
    expect(await sent.json()).toMatchObject({
      author_kind: "channel_ai",
      sender_name: "小王",
      sender_member_id: member.id,
      sender_endpoint_id: ai.endpointId,
    });

    const history = await instance.request(`/api/channels/${channel.id}/history?limit=1`, {
      headers: { authorization: `Bearer ${channel.ownerCredential}` },
    });
    expect(await history.json()).toMatchObject({
      history: [{ text: "AI reply", author_kind: "channel_ai", sender_name: "小王" }],
    });

    const publicAI = await instance.request("/api/channels/general/join", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ callsign: "public_ai", author_kind: "channel_ai" }),
    });
    expect(publicAI.status).toBe(403);
  });

  it("returns only the owner credential and managed-channel fields for api_version 2 create", async () => {
    const instance = app();
    const response = await instance.request("/api/channels", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        api_version: 2,
        retention: "none",
        trust_mode: "untrusted",
        channel_name: "产品协作",
        name: "小明",
      }),
    });
    expect(response.status).toBe(200);
    const body = (await response.json()) as Record<string, unknown>;
    expect(body).toMatchObject({
      api_version: 2,
      channel_id: expect.any(String),
      channel_name: "产品协作",
      member_id: expect.any(String),
      member_credential: expect.any(String),
      role: "owner",
      retention: "none",
      trust_mode: "untrusted",
      session_ttl_seconds: expect.any(Number),
      has_owner_password: false,
    });
    for (const legacyField of [
      "join_token",
      "connect",
      "agent_prompt",
      "mcp_url",
      "bootstrap_mcp_url",
      "owner_password",
    ]) {
      expect(body).not.toHaveProperty(legacyField);
    }

    const joined = await joinDetails(
      instance,
      body.channel_id as string,
      body.member_credential as string,
      "owner",
    );
    expect(joined.memberId).toBe(body.member_id);

    const renamed = await instance.request(`/api/channels/${body.channel_id as string}/members/me`, {
      method: "PATCH",
      headers: {
        authorization: `Bearer ${body.member_credential as string}`,
        "content-type": "application/json",
      },
      body: JSON.stringify({ name: "小红" }),
    });
    expect(renamed.status).toBe(200);
    expect(await renamed.json()).toMatchObject({ member: { name: "小红" } });
    const renamedSession = await joinDetails(
      instance,
      body.channel_id as string,
      body.member_credential as string,
      "owner-renamed",
      undefined,
      "小红",
    );
    const sent = await send(
      instance,
      body.channel_id as string,
      body.member_credential as string,
      renamedSession.sessionId,
      "new nickname",
    );
    expect(await sent.json()).toMatchObject({ sender_name: "小红" });

    const invitation = await instance.request(`/api/channels/${body.channel_id as string}/invites`, {
      method: "POST",
      headers: { authorization: `Bearer ${body.member_credential as string}` },
    });
    const invite = (await invitation.json()) as { invite_token: string };
    const redeemed = await instance.request(`/api/channels/${body.channel_id as string}/invites/redeem`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ invite_token: invite.invite_token, name: "小李" }),
    });
    expect(await redeemed.json()).toMatchObject({ channel_name: "产品协作", name: "小李" });
  });

  it("configures, lists, exhausts and revokes invitations", async () => {
    const instance = app();
    const channel = await createChannel(instance);
    const invitationResponse = await instance.request(`/api/channels/${channel.id}/invites`, {
      method: "POST",
      headers: {
        authorization: `Bearer ${channel.ownerCredential}`,
        "content-type": "application/json",
      },
      body: JSON.stringify({ label: "Backend team", max_uses: 2, expires_in_seconds: 3600 }),
    });
    const invitation = (await invitationResponse.json()) as {
      invite_id: string;
      invite_token: string;
      expires_at: number;
      max_uses: number;
      use_count: number;
      status: string;
    };
    expect(invitation.expires_at).toBeGreaterThan(Date.now());
    expect(invitation).toMatchObject({ label: "Backend team", max_uses: 2, use_count: 0, status: "active" });
    const redeem = () =>
      instance.request(`/api/channels/${channel.id}/invites/redeem`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ invite_token: invitation.invite_token, name: "Backend" }),
      });
    const redemptions = await Promise.all([redeem(), redeem(), redeem()]);
    expect(redemptions.map((response) => response.status).sort()).toEqual([200, 200, 401]);
    const first = redemptions.find((response) => response.status === 200)!;
    const member = (await first.json()) as { member_id: string; member_credential: string; role: string };
    expect(member.role).toBe("member");
    expect(member.member_credential).not.toBe(channel.ownerCredential);

    const invitations = await instance.request(`/api/channels/${channel.id}/invites`, {
      headers: { authorization: `Bearer ${channel.ownerCredential}` },
    });
    const invitationsBody = (await invitations.json()) as { invitations: Array<Record<string, unknown>> };
    expect(invitationsBody.invitations[0]).toMatchObject({
      invite_id: invitation.invite_id,
      label: "Backend team",
      max_uses: 2,
      use_count: 2,
      status: "exhausted",
    });
    expect(invitationsBody.invitations[0]).not.toHaveProperty("invite_token");

    const memberSession = await join(instance, channel.id, member.member_credential, "backend");
    expect((await send(instance, channel.id, member.member_credential, memberSession, "ready")).status).toBe(200);
    expect(
      (
        await instance.request(`/api/channels/${channel.id}/members`, {
          headers: { authorization: `Bearer ${member.member_credential}` },
        })
      ).status,
    ).toBe(200);
    expect(
      (
        await instance.request(`/api/channels/${channel.id}/invites`, {
          headers: { authorization: `Bearer ${member.member_credential}` },
        })
      ).status,
    ).toBe(403);

    const listed = await instance.request(`/api/channels/${channel.id}/members`, {
      headers: { authorization: `Bearer ${channel.ownerCredential}` },
    });
    const body = (await listed.json()) as { members: Array<{ member_id: string; callsigns: string[] }> };
    expect(body.members).toHaveLength(3);
    expect(body.members[0].member_id).toBe(channel.ownerId);
    expect(body.members.find((entry) => entry.member_id === member.member_id)?.callsigns).toEqual(["backend"]);

    const revocableResponse = await instance.request(`/api/channels/${channel.id}/invites`, {
      method: "POST",
      headers: { authorization: `Bearer ${channel.ownerCredential}`, "content-type": "application/json" },
      body: JSON.stringify({ max_uses: 2 }),
    });
    const revocable = (await revocableResponse.json()) as { invite_id: string; invite_token: string };
    const retainedResponse = await instance.request(`/api/channels/${channel.id}/invites/redeem`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ invite_token: revocable.invite_token, name: "Retained" }),
    });
    expect(retainedResponse.status).toBe(200);
    const retained = (await retainedResponse.json()) as { member_credential: string };
    expect(
      (
        await instance.request(`/api/channels/${channel.id}/invites/${revocable.invite_id}`, {
          method: "DELETE",
          headers: { authorization: `Bearer ${channel.ownerCredential}` },
        })
      ).status,
    ).toBe(200);
    expect((await join(instance, channel.id, retained.member_credential, "retained")).length).toBeGreaterThan(0);
    expect(
      (
        await instance.request(`/api/channels/${channel.id}/invites/${revocable.invite_id}`, {
          method: "DELETE",
          headers: { authorization: `Bearer ${channel.ownerCredential}` },
        })
      ).status,
    ).toBe(200);
    expect(
      (
        await instance.request(`/api/channels/${channel.id}/invites/redeem`, {
          method: "POST",
          headers: { "content-type": "application/json" },
          body: JSON.stringify({ invite_token: revocable.invite_token }),
        })
      ).status,
    ).toBe(401);
    const afterRevoke = await instance.request(`/api/channels/${channel.id}/invites`, {
      headers: { authorization: `Bearer ${channel.ownerCredential}` },
    });
    expect(
      ((await afterRevoke.json()) as { invitations: Array<{ invite_id: string; status: string }> }).invitations
        .find((entry) => entry.invite_id === revocable.invite_id)?.status,
    ).toBe("revoked");
  });

  it("validates and expires invitation configuration", async () => {
    const instance = app();
    const channel = await createChannel(instance);
    const invalid = await instance.request(`/api/channels/${channel.id}/invites`, {
      method: "POST",
      headers: { authorization: `Bearer ${channel.ownerCredential}`, "content-type": "application/json" },
      body: JSON.stringify({ max_uses: 101, expires_in_seconds: 59 }),
    });
    expect(invalid.status).toBe(400);

    vi.useFakeTimers();
    try {
      vi.setSystemTime(new Date("2026-08-24T00:00:00Z"));
      const created = await instance.request(`/api/channels/${channel.id}/invites`, {
        method: "POST",
        headers: { authorization: `Bearer ${channel.ownerCredential}`, "content-type": "application/json" },
        body: JSON.stringify({ expires_in_seconds: 60 }),
      });
      const invitation = (await created.json()) as { invite_token: string };
      vi.advanceTimersByTime(60_001);
      const expired = await instance.request(`/api/channels/${channel.id}/invites/redeem`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ invite_token: invitation.invite_token }),
      });
      expect(expired.status).toBe(401);
    } finally {
      vi.useRealTimers();
    }
  });

  it("removes a member and invalidates its credential and existing session", async () => {
    const instance = app();
    const channel = await createChannel(instance);
    const member = await inviteMember(instance, channel);
    const session = await join(instance, channel.id, member.credential, "peer");
    expect((await send(instance, channel.id, member.credential, session, "before removal")).status).toBe(200);

    const removed = await instance.request(`/api/channels/${channel.id}/members/${member.id}`, {
      method: "DELETE",
      headers: { authorization: `Bearer ${channel.ownerCredential}` },
    });
    expect(removed.status).toBe(200);
    expect((await send(instance, channel.id, member.credential, session, "after removal")).status).toBe(401);
    expect(
      (
        await instance.request(`/api/channels/${channel.id}/keepalive`, {
          method: "POST",
          headers: { authorization: `Bearer ${member.credential}`, "x-session-id": session },
        })
      ).status,
    ).toBe(401);
  });

  it("bans a member and closes an already-open SSE stream", async () => {
    const instance = app();
    const channel = await createChannel(instance);
    const member = await inviteMember(instance, channel);
    const session = await join(instance, channel.id, member.credential, "streamer");
    const stream = await instance.request(`/api/channels/${channel.id}/stream`, {
      headers: { authorization: `Bearer ${member.credential}`, "x-session-id": session },
    });
    expect(stream.status).toBe(200);
    const reader = stream.body!.getReader();
    const first = await reader.read();
    expect(new TextDecoder().decode(first.value)).toContain("event: hello");

    const banned = await instance.request(`/api/channels/${channel.id}/members/${member.id}/ban`, {
      method: "POST",
      headers: { authorization: `Bearer ${channel.ownerCredential}` },
    });
    expect(banned.status).toBe(200);
    const closed = await Promise.race([
      reader.read(),
      new Promise<never>((_, reject) => setTimeout(() => reject(new Error("stream did not close")), 1_000)),
    ]);
    expect(new TextDecoder().decode(closed.value)).toContain("member_revoked");
    await reader.cancel();

    const members = await instance.request(`/api/channels/${channel.id}/members`, {
      headers: { authorization: `Bearer ${channel.ownerCredential}` },
    });
    const body = (await members.json()) as { members: Array<{ member_id: string; status: string }> };
    expect(body.members.find((entry) => entry.member_id === member.id)?.status).toBe("banned");

    const unbanned = await instance.request(`/api/channels/${channel.id}/members/${member.id}/unban`, {
      method: "POST",
      headers: { authorization: `Bearer ${channel.ownerCredential}` },
    });
    expect(unbanned.status).toBe(200);
    const restoredSession = await join(instance, channel.id, member.credential, "streamer");
    expect((await send(instance, channel.id, member.credential, restoredSession, "restored")).status).toBe(200);
  });

  it("stops draining queued SSE messages as soon as the member is revoked", async () => {
    const instance = app();
    const channel = await createChannel(instance);
    const member = await inviteMember(instance, channel);
    const ownerSession = await join(instance, channel.id, channel.ownerCredential, "owner");
    const memberSession = await join(instance, channel.id, member.credential, "streamer");
    for (let index = 0; index < 5; index += 1) {
      expect(
        (await send(instance, channel.id, channel.ownerCredential, ownerSession, `queued-${index}`)).status,
      ).toBe(200);
    }

    const stream = await instance.request(`/api/channels/${channel.id}/stream`, {
      headers: { authorization: `Bearer ${member.credential}`, "x-session-id": memberSession },
    });
    expect(stream.status).toBe(200);
    const reader = stream.body!.getReader();
    const decoder = new TextDecoder();
    const hello = await reader.read();
    expect(decoder.decode(hello.value)).toContain("event: hello");

    const banned = await instance.request(`/api/channels/${channel.id}/members/${member.id}/ban`, {
      method: "POST",
      headers: { authorization: `Bearer ${channel.ownerCredential}` },
    });
    expect(banned.status).toBe(200);

    let remaining = "";
    while (true) {
      const chunk = await Promise.race([
        reader.read(),
        new Promise<never>((_, reject) =>
          setTimeout(() => reject(new Error("revoked stream did not close")), 1_000),
        ),
      ]);
      if (chunk.done) break;
      remaining += decoder.decode(chunk.value, { stream: true });
    }
    const deliveredAfterRevocation = remaining.match(/event: message/g) ?? [];
    // One write may already be in flight when the owner revokes access. The
    // remaining queued messages must be discarded rather than drained.
    expect(deliveredAfterRevocation.length).toBeLessThanOrEqual(1);
    expect(remaining).toContain("member_revoked");
  });

  it("keeps bounded message history isolated by channel", async () => {
    const instance = app();
    const first = await createChannel(instance);
    const second = await createChannel(instance);
    const session = await join(instance, first.id, first.ownerCredential, "owner");
    await send(instance, first.id, first.ownerCredential, session, "one");
    await send(instance, first.id, first.ownerCredential, session, "two");
    await send(instance, first.id, first.ownerCredential, session, "three");

    const latest = await instance.request(`/api/channels/${first.id}/history?limit=1`, {
      headers: { authorization: `Bearer ${first.ownerCredential}` },
    });
    const latestBody = (await latest.json()) as { history: Array<{ text: string }> };
    expect(latestBody.history).toEqual([expect.objectContaining({ text: "three" })]);
    const isolated = await instance.request(`/api/channels/${second.id}/history?limit=100`, {
      headers: { authorization: `Bearer ${second.ownerCredential}` },
    });
    expect(((await isolated.json()) as { history: unknown[] }).history).toEqual([]);
    expect(
      (
        await instance.request(`/api/channels/${first.id}/history`, {
          headers: { authorization: `Bearer ${second.ownerCredential}` },
        })
      ).status,
    ).toBe(401);
  });

  it("server-binds immutable member and endpoint identity to messages", async () => {
    const instance = app();
    const channel = await createChannel(instance);
    const member = await inviteMember(instance, channel, "Backend");
    const backend = await joinDetails(instance, channel.id, member.credential, "backend", undefined, "Peer");

    expect(backend.memberId).toBe(member.id);
    expect(backend.endpointId).toMatch(/^ep_[A-Za-z0-9_-]+$/);

    const sameEndpoint = await joinDetails(instance, channel.id, member.credential, "backend");
    expect(sameEndpoint.sessionId).toBe(backend.sessionId);
    expect(sameEndpoint.memberId).toBe(backend.memberId);
    expect(sameEndpoint.endpointId).toBe(backend.endpointId);

    const secondEndpoint = await joinDetails(instance, channel.id, member.credential, "backend_cli");
    expect(secondEndpoint.memberId).toBe(backend.memberId);
    expect(secondEndpoint.endpointId).not.toBe(backend.endpointId);

    const sent = await instance.request(`/api/channels/${channel.id}/send`, {
      method: "POST",
      headers: {
        authorization: `Bearer ${member.credential}`,
        "x-session-id": backend.sessionId,
        "content-type": "application/json",
      },
      body: JSON.stringify({
        to: "all",
        message: "identity check",
        sender_member_id: "forged-member",
        sender_endpoint_id: "forged-endpoint",
      }),
    });
    expect(sent.status).toBe(200);
    expect(await sent.json()).toMatchObject({
      from: "backend",
      sender_name: "Peer",
      sender_member_id: backend.memberId,
      sender_endpoint_id: backend.endpointId,
    });

    const history = await instance.request(`/api/channels/${channel.id}/history?limit=1`, {
      headers: { authorization: `Bearer ${member.credential}` },
    });
    expect(history.status).toBe(200);
    expect(await history.json()).toMatchObject({
      history: [
        {
          from: "backend",
          sender_name: "Peer",
          sender_member_id: backend.memberId,
          sender_endpoint_id: backend.endpointId,
          text: "identity check",
        },
      ],
    });
  });

  it("stores validated multi-member mention snapshots without changing broadcast routing", async () => {
    const instance = app();
    const channel = await createChannel(instance);
    const first = await inviteMember(instance, channel, "张三");
    const second = await inviteMember(instance, channel, "李四");
    const owner = await joinDetails(instance, channel.id, channel.ownerCredential, "owner_mentions");

    const sent = await send(
      instance,
      channel.id,
      channel.ownerCredential,
      owner.sessionId,
      "请一起看",
      [first.id, second.id],
    );
    expect(sent.status).toBe(200);
    expect(await sent.json()).toMatchObject({
      to: "all",
      mention: {
        kind: "members",
        members: [
          { member_id: first.id, member_name: "张三" },
          { member_id: second.id, member_name: "李四" },
        ],
      },
    });

    const history = await instance.request(`/api/channels/${channel.id}/history?limit=1`, {
      headers: { authorization: `Bearer ${channel.ownerCredential}` },
    });
    expect(await history.json()).toMatchObject({
      history: [{ mention: { kind: "members", members: [{ member_id: first.id }, { member_id: second.id }] } }],
    });

    for (const mentions of [[], [first.id, first.id], ["all", first.id], Array(101).fill(first.id)]) {
      const rejected = await send(
        instance,
        channel.id,
        channel.ownerCredential,
        owner.sessionId,
        "invalid",
        mentions,
      );
      expect(rejected.status).toBe(400);
    }

    const removed = await instance.request(`/api/channels/${channel.id}/members/${first.id}`, {
      method: "DELETE",
      headers: { authorization: `Bearer ${channel.ownerCredential}` },
    });
    expect(removed.status).toBe(200);
    expect((await send(
      instance,
      channel.id,
      channel.ownerCredential,
      owner.sessionId,
      "stale",
      [first.id],
    )).status).toBe(400);

    const all = await send(
      instance,
      channel.id,
      channel.ownerCredential,
      owner.sessionId,
      "everyone",
      ["all"],
    );
    expect(await all.json()).toMatchObject({ mention: { kind: "all" } });
  });

  it("keeps callsign and source binding atomic when a session id is reused", async () => {
    const instance = app();
    const channel = await createChannel(instance);
    const peer = await inviteMember(instance, channel, "Peer");
    const victimSession = "owner-session-atomic";
    const owner = await joinDetails(
      instance,
      channel.id,
      channel.ownerCredential,
      "owner_ep",
      victimSession,
    );

    const rejected = await instance.request(`/api/channels/${channel.id}/join`, {
      method: "POST",
      headers: {
        authorization: `Bearer ${peer.credential}`,
        "content-type": "application/json",
        "x-session-id": victimSession,
      },
      body: JSON.stringify({ callsign: "attacker_ep" }),
    });
    expect(rejected.status).toBe(401);

    const afterRejectedReuse = await send(
      instance,
      channel.id,
      channel.ownerCredential,
      victimSession,
      "identity intact",
    );
    expect(afterRejectedReuse.status).toBe(200);
    expect(await afterRejectedReuse.json()).toMatchObject({
      from: "owner_ep",
      sender_member_id: channel.ownerId,
      sender_endpoint_id: owner.endpointId,
    });

    const renamed = await joinDetails(
      instance,
      channel.id,
      channel.ownerCredential,
      "owner_renamed",
      victimSession,
    );
    expect(renamed.sessionId).toBe(victimSession);
    expect(renamed.memberId).toBe(channel.ownerId);
    expect(renamed.endpointId).not.toBe(owner.endpointId);

    const afterRename = await send(
      instance,
      channel.id,
      channel.ownerCredential,
      victimSession,
      "identity renamed atomically",
    );
    expect(afterRename.status).toBe(200);
    expect(await afterRename.json()).toMatchObject({
      from: "owner_renamed",
      sender_member_id: channel.ownerId,
      sender_endpoint_id: renamed.endpointId,
    });
  });
});
