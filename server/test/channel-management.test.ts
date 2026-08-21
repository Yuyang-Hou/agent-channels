import { describe, expect, it } from "vitest";
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
): Promise<Joined> {
  const response = await instance.request(`/api/channels/${channelId}/join`, {
    method: "POST",
    headers: {
      authorization: `Bearer ${credential}`,
      "content-type": "application/json",
      ...(sessionId ? { "x-session-id": sessionId } : {}),
    },
    body: JSON.stringify({ callsign }),
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
): Promise<Response> {
  return instance.request(`/api/channels/${channelId}/send`, {
    method: "POST",
    headers: {
      authorization: `Bearer ${credential}`,
      "x-session-id": sessionId,
      "content-type": "application/json",
    },
    body: JSON.stringify({ to: "all", message }),
  });
}

describe("managed channel members", () => {
  it("returns only the owner credential and managed-channel fields for api_version 2 create", async () => {
    const instance = app();
    const response = await instance.request("/api/channels", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ api_version: 2, retention: "none", trust_mode: "untrusted" }),
    });
    expect(response.status).toBe(200);
    const body = (await response.json()) as Record<string, unknown>;
    expect(body).toMatchObject({
      api_version: 2,
      channel_id: expect.any(String),
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
  });

  it("issues one-time invitations and independent member credentials", async () => {
    const instance = app();
    const channel = await createChannel(instance);
    const invitationResponse = await instance.request(`/api/channels/${channel.id}/invites`, {
      method: "POST",
      headers: { authorization: `Bearer ${channel.ownerCredential}` },
    });
    const invitation = (await invitationResponse.json()) as {
      invite_id: string;
      invite_token: string;
      expires_at: number;
      max_uses: number;
    };
    expect(invitation.expires_at).toBeGreaterThan(Date.now());
    expect(invitation.max_uses).toBe(1);
    const redeem = () =>
      instance.request(`/api/channels/${channel.id}/invites/redeem`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ invite_token: invitation.invite_token, name: "Backend" }),
      });
    const first = await redeem();
    expect(first.status).toBe(200);
    const member = (await first.json()) as { member_id: string; member_credential: string; role: string };
    expect(member.role).toBe("member");
    expect(member.member_credential).not.toBe(channel.ownerCredential);
    expect((await redeem()).status).toBe(401);

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
          method: "POST",
          headers: { authorization: `Bearer ${member.member_credential}` },
        })
      ).status,
    ).toBe(403);

    const listed = await instance.request(`/api/channels/${channel.id}/members`, {
      headers: { authorization: `Bearer ${channel.ownerCredential}` },
    });
    const body = (await listed.json()) as { members: Array<{ member_id: string; callsigns: string[] }> };
    expect(body.members.map((entry) => entry.member_id)).toEqual([channel.ownerId, member.member_id]);
    expect(body.members[1].callsigns).toEqual(["backend"]);

    const revocableResponse = await instance.request(`/api/channels/${channel.id}/invites`, {
      method: "POST",
      headers: { authorization: `Bearer ${channel.ownerCredential}` },
    });
    const revocable = (await revocableResponse.json()) as { invite_id: string; invite_token: string };
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
    const backend = await joinDetails(instance, channel.id, member.credential, "backend");

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
          sender_member_id: backend.memberId,
          sender_endpoint_id: backend.endpointId,
          text: "identity check",
        },
      ],
    });
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
