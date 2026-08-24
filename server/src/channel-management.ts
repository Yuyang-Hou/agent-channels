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
  inviteId?: string;
};

type InviteRecord = {
  inviteId: string;
  channelId: string;
  tokenHash: string;
  label: string;
  maxUses: number;
  useCount: number;
  createdAt: number;
  expiresAt: number;
  revokedAt?: number;
};

type State = {
  version: 2;
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
  invite_id?: string;
};

export type InviteStatus = "active" | "exhausted" | "expired" | "revoked";

export type InviteView = {
  invite_id: string;
  channel_id: string;
  label: string;
  max_uses: number;
  use_count: number;
  created_at: number;
  expires_at: number;
  revoked_at?: number;
  status: InviteStatus;
};

const DB_PATH =
  process.env.ROGERRAT_MEMBERS_DB ?? `${process.env.ROGERRAT_DB ?? "./data/channels.json"}.members`;
const DEFAULT_INVITE_TTL_SECONDS = 24 * 60 * 60;
let state: State = { version: 2, members: [], invites: [] };
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
    typeof record.updatedAt === "number" &&
    (record.inviteId === undefined || typeof record.inviteId === "string")
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
    typeof record.label === "string" &&
    typeof record.maxUses === "number" &&
    Number.isInteger(record.maxUses) &&
    record.maxUses > 0 &&
    typeof record.useCount === "number" &&
    Number.isInteger(record.useCount) &&
    record.useCount >= 0 &&
    typeof record.createdAt === "number" &&
    typeof record.expiresAt === "number" &&
    (record.revokedAt === undefined || typeof record.revokedAt === "number")
  );
}

function ensureLoaded(): void {
  if (loaded) return;
  loaded = true;
  try {
    if (!existsSync(DB_PATH)) return;
    const parsed = JSON.parse(readFileSync(DB_PATH, "utf8")) as Partial<State>;
    if (
      parsed.version !== 2 ||
      !Array.isArray(parsed.members) ||
      !parsed.members.every(isMemberRecord) ||
      !Array.isArray(parsed.invites) ||
      !parsed.invites.every(isInviteRecord)
    ) return;
    state = {
      version: 2,
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
    ...(member.inviteId ? { invite_id: member.inviteId } : {}),
  };
}

function inviteStatus(invite: InviteRecord, now = Date.now()): InviteStatus {
  if (invite.revokedAt !== undefined) return "revoked";
  if (invite.expiresAt <= now) return "expired";
  if (invite.useCount >= invite.maxUses) return "exhausted";
  return "active";
}

function inviteView(invite: InviteRecord): InviteView {
  return {
    invite_id: invite.inviteId,
    channel_id: invite.channelId,
    label: invite.label,
    max_uses: invite.maxUses,
    use_count: invite.useCount,
    created_at: invite.createdAt,
    expires_at: invite.expiresAt,
    ...(invite.revokedAt !== undefined ? { revoked_at: invite.revokedAt } : {}),
    status: inviteStatus(invite),
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
  options: { label?: string; maxUses?: number; expiresInSeconds?: number } = {},
): InviteView & { invite_token: string } {
  ensureLoaded();
  const inviteToken = generateToken();
  const now = Date.now();
  const invite: InviteRecord = {
    inviteId: randomUUID(),
    channelId,
    tokenHash: digest(inviteToken),
    label: options.label ?? "",
    maxUses: options.maxUses ?? 1,
    useCount: 0,
    createdAt: now,
    expiresAt: now + (options.expiresInSeconds ?? DEFAULT_INVITE_TTL_SECONDS) * 1000,
  };
  state.invites.push(invite);
  persist();
  return { ...inviteView(invite), invite_token: inviteToken };
}

export function listMemberInvites(channelId: string): InviteView[] {
  ensureLoaded();
  return state.invites
    .filter((invite) => invite.channelId === channelId)
    .map(inviteView)
    .sort((a, b) => b.created_at - a.created_at);
}

export function revokeMemberInvite(channelId: string, inviteId: string): InviteView | undefined {
  ensureLoaded();
  const invite = state.invites.find(
    (candidate) => candidate.channelId === channelId && candidate.inviteId === inviteId,
  );
  if (!invite) return undefined;
  if (invite.revokedAt === undefined) {
    invite.revokedAt = Date.now();
    persist();
  }
  return inviteView(invite);
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
      inviteStatus(candidate) === "active" &&
      sameDigest(candidate.tokenHash, tokenHash),
  );
  if (inviteIndex < 0) return undefined;
  const invite = state.invites[inviteIndex];
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
    inviteId: invite.inviteId,
  };
  invite.useCount += 1;
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
