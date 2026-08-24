import { createHash, randomUUID, timingSafeEqual } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { dirname } from "node:path";
import { generateToken } from "./ids.js";

export type MemberRole = "owner" | "member";
export type MemberStatus = "active" | "removed" | "banned";

type MemberRecord = {
  memberId: string;
  channelId: string;
  role: MemberRole;
  status: MemberStatus;
  name: string;
  callsigns: string[];
  credentialHash: string;
  createdAt: number;
  updatedAt: number;
};

type InviteRecord = {
  inviteId: string;
  channelId: string;
  tokenHash: string;
  createdAt: number;
  expiresAt: number;
};

type State = {
  version: 1;
  members: MemberRecord[];
  invites: InviteRecord[];
};

export type MemberView = {
  member_id: string;
  channel_id: string;
  role: MemberRole;
  status: MemberStatus;
  name: string;
  callsigns: string[];
  created_at: number;
  updated_at: number;
};

const DB_PATH =
  process.env.ROGERRAT_MEMBERS_DB ?? `${process.env.ROGERRAT_DB ?? "./data/channels.json"}.members`;
const INVITE_TTL_MS = 24 * 60 * 60 * 1000;
let state: State = { version: 1, members: [], invites: [] };
let loaded = false;

function digest(value: string): string {
  return createHash("sha256").update(value).digest("hex");
}

function stableOpaqueId(prefix: string, ...parts: string[]): string {
  const hash = createHash("sha256");
  for (const part of parts) {
    hash.update(String(Buffer.byteLength(part)));
    hash.update(":");
    hash.update(part);
  }
  return `${prefix}_${hash.digest("base64url")}`;
}

export function authenticatedEndpointId(channelId: string, memberId: string, callsign: string): string {
  return stableOpaqueId("ep", channelId, memberId, callsign.trim().toLowerCase());
}

/** Public bands have no authenticated membership; this ID is only a stable
 * source namespace for compatibility and must not be treated as an account. */
export function publicBandMemberId(channelId: string, callsign: string): string {
  return stableOpaqueId("public", channelId, callsign.trim().toLowerCase());
}

function sameDigest(left: string, right: string): boolean {
  const a = Buffer.from(left, "hex");
  const b = Buffer.from(right, "hex");
  return a.length === b.length && timingSafeEqual(a, b);
}

function isMemberRecord(value: unknown): value is MemberRecord {
  if (!value || typeof value !== "object") return false;
  const record = value as Partial<MemberRecord>;
  return (
    typeof record.memberId === "string" &&
    typeof record.channelId === "string" &&
    (record.role === "owner" || record.role === "member") &&
    (record.status === "active" || record.status === "removed" || record.status === "banned") &&
    typeof record.name === "string" &&
    Array.isArray(record.callsigns) &&
    record.callsigns.every((callsign) => typeof callsign === "string") &&
    typeof record.credentialHash === "string" &&
    /^[a-f0-9]{64}$/.test(record.credentialHash) &&
    typeof record.createdAt === "number" &&
    typeof record.updatedAt === "number"
  );
}

function isInviteRecord(value: unknown): value is InviteRecord {
  if (!value || typeof value !== "object") return false;
  const record = value as Partial<InviteRecord>;
  return (
    typeof record.inviteId === "string" &&
    typeof record.channelId === "string" &&
    typeof record.tokenHash === "string" &&
    /^[a-f0-9]{64}$/.test(record.tokenHash) &&
    typeof record.createdAt === "number" &&
    typeof record.expiresAt === "number"
  );
}

function ensureLoaded(): void {
  if (loaded) return;
  loaded = true;
  try {
    if (!existsSync(DB_PATH)) return;
    const parsed = JSON.parse(readFileSync(DB_PATH, "utf8")) as Partial<State>;
    if (
      parsed.version !== 1 ||
      !Array.isArray(parsed.members) ||
      !parsed.members.every(isMemberRecord) ||
      !Array.isArray(parsed.invites) ||
      !parsed.invites.every(isInviteRecord)
    ) return;
    state = {
      version: 1,
      members: parsed.members,
      invites: parsed.invites,
    };
  } catch (error) {
    console.error("[channel-management] failed to load:", error);
  }
}

function persist(): void {
  const dir = dirname(DB_PATH);
  if (!existsSync(dir)) mkdirSync(dir, { recursive: true });
  const temporary = `${DB_PATH}.${process.pid}.${randomUUID()}.tmp`;
  writeFileSync(temporary, JSON.stringify(state, null, 2));
  renameSync(temporary, DB_PATH);
}

function view(member: MemberRecord): MemberView {
  return {
    member_id: member.memberId,
    channel_id: member.channelId,
    role: member.role,
    status: member.status,
    name: member.name,
    callsigns: [...member.callsigns],
    created_at: member.createdAt,
    updated_at: member.updatedAt,
  };
}

export function registerOwner(channelId: string, credential: string, name = "Owner"): MemberView {
  ensureLoaded();
  const existing = state.members.find((member) => member.channelId === channelId && member.role === "owner");
  if (existing) return view(existing);
  const now = Date.now();
  const owner: MemberRecord = {
    memberId: randomUUID(),
    channelId,
    role: "owner",
    status: "active",
    name,
    callsigns: [],
    credentialHash: digest(credential),
    createdAt: now,
    updatedAt: now,
  };
  state.members.push(owner);
  persist();
  return view(owner);
}

export function updateMemberName(channelId: string, memberId: string, name: string): MemberView | undefined {
  ensureLoaded();
  const member = state.members.find(
    (candidate) => candidate.channelId === channelId && candidate.memberId === memberId && candidate.status === "active",
  );
  if (!member) return undefined;
  member.name = name;
  member.updatedAt = Date.now();
  persist();
  return view(member);
}

export function authenticateMember(channelId: string, credential: string): MemberView | undefined {
  ensureLoaded();
  if (!credential) return undefined;
  const credentialHash = digest(credential);
  const member = state.members.find(
    (candidate) =>
      candidate.channelId === channelId &&
      candidate.status === "active" &&
      sameDigest(candidate.credentialHash, credentialHash),
  );
  return member ? view(member) : undefined;
}

export function createMemberInvite(
  channelId: string,
): { invite_id: string; invite_token: string; expires_at: number; max_uses: 1 } {
  ensureLoaded();
  const inviteToken = generateToken();
  const now = Date.now();
  const invite: InviteRecord = {
    inviteId: randomUUID(),
    channelId,
    tokenHash: digest(inviteToken),
    createdAt: now,
    expiresAt: now + INVITE_TTL_MS,
  };
  state.invites = state.invites.filter((candidate) => candidate.expiresAt > now);
  state.invites.push(invite);
  persist();
  return { invite_id: invite.inviteId, invite_token: inviteToken, expires_at: invite.expiresAt, max_uses: 1 };
}

export function revokeMemberInvite(channelId: string, inviteId: string): boolean {
  ensureLoaded();
  const index = state.invites.findIndex(
    (candidate) => candidate.channelId === channelId && candidate.inviteId === inviteId,
  );
  if (index < 0) return false;
  state.invites.splice(index, 1);
  persist();
  return true;
}

export function redeemMemberInvite(
  channelId: string,
  inviteToken: string,
  name: string,
): { member: MemberView; member_credential: string } | undefined {
  ensureLoaded();
  const tokenHash = digest(inviteToken);
  const inviteIndex = state.invites.findIndex(
    (candidate) =>
      candidate.channelId === channelId &&
      candidate.expiresAt > Date.now() &&
      sameDigest(candidate.tokenHash, tokenHash),
  );
  if (inviteIndex < 0) return undefined;
  const now = Date.now();
  const credential = generateToken();
  const member: MemberRecord = {
    memberId: randomUUID(),
    channelId,
    role: "member",
    status: "active",
    name,
    callsigns: [],
    credentialHash: digest(credential),
    createdAt: now,
    updatedAt: now,
  };
  state.invites.splice(inviteIndex, 1);
  state.members.push(member);
  persist();
  return { member: view(member), member_credential: credential };
}

export function listChannelMembers(channelId: string): MemberView[] {
  ensureLoaded();
  return state.members
    .filter((member) => member.channelId === channelId)
    .map(view)
    .sort((a, b) => a.created_at - b.created_at);
}

export function setMemberStatus(
  channelId: string,
  memberId: string,
  status: Extract<MemberStatus, "removed" | "banned">,
): MemberView | undefined {
  ensureLoaded();
  const member = state.members.find(
    (candidate) => candidate.channelId === channelId && candidate.memberId === memberId,
  );
  if (!member || member.role === "owner") return undefined;
  member.status = status;
  member.updatedAt = Date.now();
  persist();
  return view(member);
}

export function unbanMember(channelId: string, memberId: string): MemberView | undefined {
  ensureLoaded();
  const member = state.members.find(
    (candidate) =>
      candidate.channelId === channelId && candidate.memberId === memberId && candidate.status === "banned",
  );
  if (!member) return undefined;
  member.status = "active";
  member.updatedAt = Date.now();
  persist();
  return view(member);
}

export function claimMemberCallsign(
  channelId: string,
  memberId: string,
  callsign: string,
): { ok: true } | { ok: false; member_id: string } {
  ensureLoaded();
  const conflict = state.members.find(
    (member) =>
      member.channelId === channelId &&
      member.memberId !== memberId &&
      member.callsigns.includes(callsign),
  );
  if (conflict) return { ok: false, member_id: conflict.memberId };
  const member = state.members.find(
    (candidate) => candidate.channelId === channelId && candidate.memberId === memberId,
  );
  if (member && !member.callsigns.includes(callsign)) {
    member.callsigns.push(callsign);
    member.updatedAt = Date.now();
    persist();
  }
  return { ok: true };
}
