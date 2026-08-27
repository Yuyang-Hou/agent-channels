import { randomUUID } from "node:crypto";
import { Pool, type PoolClient } from "pg";

export type LoginAttempt = {
  id: string;
  clientState: string;
  githubPkceVerifier: string;
};

export type AccountSession = {
  accountId: string;
  deviceId: string;
  displayName: string;
  expiresAt: string;
};

export type AccountMembership = {
  membershipId: string;
  accountId: string;
  channelId: string;
  role: "owner" | "member";
  status: "active" | "removed" | "banned";
  createdAt: string;
  updatedAt: string;
};

export interface AccountStore {
  ready(): Promise<void>;
  createLoginAttempt(input: {
    githubStateHash: string;
    githubPkceVerifier: string;
    appCodeChallenge: string;
    clientState: string;
    deviceName: string;
    expiresAt: string;
  }): Promise<void>;
  getLoginAttemptForCallback(githubStateHash: string): Promise<LoginAttempt>;
  authenticateLoginAttempt(input: {
    attemptId: string;
    githubUserId: string;
    githubDisplayName: string;
    exchangeCodeHash: string;
  }): Promise<string>;
  cancelLoginAttempt(githubStateHash: string): Promise<string>;
  redeemLoginAttempt(input: {
    exchangeCodeHash: string;
    appCodeChallenge: string;
    sessionCredentialHash: string;
    sessionExpiresAt: string;
  }): Promise<AccountSession>;
  getSession(sessionCredentialHash: string): Promise<AccountSession>;
  revokeSession(sessionCredentialHash: string): Promise<boolean>;
  createMembership(input: {
    membershipId: string;
    accountId: string;
    channelId: string;
    role: "owner" | "member";
  }): Promise<AccountMembership>;
  getMembership(accountId: string, channelId: string): Promise<AccountMembership | undefined>;
  listMemberships(accountId: string): Promise<AccountMembership[]>;
  setMembershipStatus(
    channelId: string,
    membershipId: string,
    status: "active" | "removed" | "banned",
  ): Promise<AccountMembership | undefined>;
}

const MIGRATION = [
  `CREATE TABLE IF NOT EXISTS pijoo_accounts (
    account_id text PRIMARY KEY,
    github_user_id text NOT NULL UNIQUE,
    display_name varchar(120) NOT NULL,
    status varchar(16) NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'deleted')),
    created_at timestamptz NOT NULL,
    updated_at timestamptz NOT NULL,
    deleted_at timestamptz
  )`,
  `CREATE TABLE IF NOT EXISTS pijoo_devices (
    device_id text PRIMARY KEY,
    account_id text NOT NULL REFERENCES pijoo_accounts(account_id),
    name varchar(120) NOT NULL,
    platform varchar(32) NOT NULL,
    created_at timestamptz NOT NULL,
    last_seen_at timestamptz NOT NULL,
    revoked_at timestamptz
  )`,
  `CREATE TABLE IF NOT EXISTS pijoo_sessions (
    session_id text PRIMARY KEY,
    account_id text NOT NULL REFERENCES pijoo_accounts(account_id),
    device_id text NOT NULL REFERENCES pijoo_devices(device_id),
    credential_hash char(64) NOT NULL UNIQUE,
    created_at timestamptz NOT NULL,
    expires_at timestamptz NOT NULL,
    last_seen_at timestamptz NOT NULL,
    revoked_at timestamptz
  )`,
  `CREATE TABLE IF NOT EXISTS pijoo_login_attempts (
    attempt_id text PRIMARY KEY,
    github_state_hash char(64) NOT NULL UNIQUE,
    github_pkce_verifier varchar(128) NOT NULL,
    app_code_challenge varchar(128) NOT NULL,
    client_state varchar(256) NOT NULL,
    device_name varchar(120) NOT NULL,
    github_user_id text,
    github_display_name varchar(120),
    exchange_code_hash char(64) UNIQUE,
    expires_at timestamptz NOT NULL,
    authenticated_at timestamptz,
    consumed_at timestamptz,
    created_at timestamptz NOT NULL
  )`,
  `CREATE TABLE IF NOT EXISTS pijoo_memberships (
    membership_id text PRIMARY KEY,
    account_id text NOT NULL REFERENCES pijoo_accounts(account_id),
    channel_id text NOT NULL,
    role varchar(16) NOT NULL CHECK (role IN ('owner', 'member')),
    status varchar(16) NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'removed', 'banned')),
    created_at timestamptz NOT NULL,
    updated_at timestamptz NOT NULL,
    UNIQUE (channel_id, account_id)
  )`,
  "CREATE INDEX IF NOT EXISTS pijoo_sessions_account_idx ON pijoo_sessions(account_id, revoked_at, expires_at)",
  "CREATE INDEX IF NOT EXISTS pijoo_login_attempts_expiry_idx ON pijoo_login_attempts(expires_at, consumed_at)",
  "CREATE INDEX IF NOT EXISTS pijoo_memberships_account_idx ON pijoo_memberships(account_id, status, updated_at)",
  "CREATE UNIQUE INDEX IF NOT EXISTS pijoo_memberships_active_owner_idx ON pijoo_memberships(channel_id) WHERE role = 'owner' AND status = 'active'",
] as const;

type LoginAttemptRow = {
  attempt_id: string;
  client_state: string;
  github_pkce_verifier: string;
};

type SessionRow = {
  account_id: string;
  device_id: string;
  display_name: string;
  expires_at: Date;
};

type MembershipRow = {
  membership_id: string;
  account_id: string;
  channel_id: string;
  role: "owner" | "member";
  status: "active" | "removed" | "banned";
  created_at: Date;
  updated_at: Date;
};

export class PostgresAccountStore implements AccountStore {
  constructor(private readonly pool: Pool) {}

  async migrate(): Promise<void> {
    const client = await this.pool.connect();
    try {
      await client.query("BEGIN");
      for (const statement of MIGRATION) await client.query(statement);
      await client.query("COMMIT");
    } catch (error) {
      await client.query("ROLLBACK");
      throw error;
    } finally {
      client.release();
    }
  }

  async ready(): Promise<void> {
    await this.pool.query("SELECT 1");
  }

  async close(): Promise<void> {
    await this.pool.end();
  }

  async createLoginAttempt(input: {
    githubStateHash: string;
    githubPkceVerifier: string;
    appCodeChallenge: string;
    clientState: string;
    deviceName: string;
    expiresAt: string;
  }): Promise<void> {
    await this.pool.query(
      `INSERT INTO pijoo_login_attempts (
        attempt_id, github_state_hash, github_pkce_verifier, app_code_challenge,
        client_state, device_name, expires_at, created_at
      ) VALUES ($1, $2, $3, $4, $5, $6, $7, now())`,
      [
        randomUUID(),
        input.githubStateHash,
        input.githubPkceVerifier,
        input.appCodeChallenge,
        input.clientState,
        input.deviceName,
        input.expiresAt,
      ],
    );
  }

  async getLoginAttemptForCallback(githubStateHash: string): Promise<LoginAttempt> {
    const result = await this.pool.query<LoginAttemptRow>(
      `SELECT attempt_id, client_state, github_pkce_verifier
       FROM pijoo_login_attempts
       WHERE github_state_hash = $1 AND expires_at > now()
         AND authenticated_at IS NULL AND consumed_at IS NULL`,
      [githubStateHash],
    );
    const row = result.rows[0];
    if (!row) throw new Error("login-attempt-unavailable");
    return { id: row.attempt_id, clientState: row.client_state, githubPkceVerifier: row.github_pkce_verifier };
  }

  async authenticateLoginAttempt(input: {
    attemptId: string;
    githubUserId: string;
    githubDisplayName: string;
    exchangeCodeHash: string;
  }): Promise<string> {
    const result = await this.pool.query<{ client_state: string }>(
      `UPDATE pijoo_login_attempts
       SET github_user_id = $2, github_display_name = $3, exchange_code_hash = $4,
           authenticated_at = now(), github_pkce_verifier = ''
       WHERE attempt_id = $1 AND expires_at > now()
         AND authenticated_at IS NULL AND consumed_at IS NULL
       RETURNING client_state`,
      [input.attemptId, input.githubUserId, input.githubDisplayName, input.exchangeCodeHash],
    );
    const row = result.rows[0];
    if (!row) throw new Error("login-attempt-unavailable");
    return row.client_state;
  }

  async cancelLoginAttempt(githubStateHash: string): Promise<string> {
    const result = await this.pool.query<{ client_state: string }>(
      `DELETE FROM pijoo_login_attempts
       WHERE github_state_hash = $1 AND authenticated_at IS NULL AND consumed_at IS NULL
       RETURNING client_state`,
      [githubStateHash],
    );
    const row = result.rows[0];
    if (!row) throw new Error("login-attempt-unavailable");
    return row.client_state;
  }

  async redeemLoginAttempt(input: {
    exchangeCodeHash: string;
    appCodeChallenge: string;
    sessionCredentialHash: string;
    sessionExpiresAt: string;
  }): Promise<AccountSession> {
    const client = await this.pool.connect();
    try {
      await client.query("BEGIN");
      const attempt = await client.query<{
        attempt_id: string;
        app_code_challenge: string;
        device_name: string;
        github_user_id: string;
        github_display_name: string;
      }>(
        `SELECT attempt_id, app_code_challenge, device_name, github_user_id, github_display_name
         FROM pijoo_login_attempts
         WHERE exchange_code_hash = $1 AND expires_at > now()
           AND authenticated_at IS NOT NULL AND consumed_at IS NULL
         FOR UPDATE`,
        [input.exchangeCodeHash],
      );
      const row = attempt.rows[0];
      if (!row || row.app_code_challenge !== input.appCodeChallenge) {
        throw new Error("login-exchange-invalid");
      }
      const now = new Date().toISOString();
      const accountId = await this.upsertAccount(client, row.github_user_id, row.github_display_name, now);
      const deviceId = randomUUID();
      await client.query(
        `INSERT INTO pijoo_devices (
          device_id, account_id, name, platform, created_at, last_seen_at
        ) VALUES ($1, $2, $3, 'macos', $4, $4)`,
        [deviceId, accountId, row.device_name, now],
      );
      await client.query(
        `INSERT INTO pijoo_sessions (
          session_id, account_id, device_id, credential_hash, created_at, expires_at, last_seen_at
        ) VALUES ($1, $2, $3, $4, $5, $6, $5)`,
        [randomUUID(), accountId, deviceId, input.sessionCredentialHash, now, input.sessionExpiresAt],
      );
      await client.query("DELETE FROM pijoo_login_attempts WHERE attempt_id = $1", [row.attempt_id]);
      await client.query("COMMIT");
      return {
        accountId,
        deviceId,
        displayName: row.github_display_name,
        expiresAt: new Date(input.sessionExpiresAt).toISOString(),
      };
    } catch (error) {
      await client.query("ROLLBACK");
      throw error;
    } finally {
      client.release();
    }
  }

  async getSession(sessionCredentialHash: string): Promise<AccountSession> {
    const result = await this.pool.query<SessionRow>(
      `UPDATE pijoo_sessions AS session
       SET last_seen_at = now()
       FROM pijoo_accounts AS account, pijoo_devices AS device
       WHERE session.credential_hash = $1
         AND session.account_id = account.account_id
         AND session.device_id = device.device_id
         AND session.revoked_at IS NULL AND session.expires_at > now()
         AND account.status = 'active' AND device.revoked_at IS NULL
       RETURNING session.account_id, session.device_id, account.display_name, session.expires_at`,
      [sessionCredentialHash],
    );
    const row = result.rows[0];
    if (!row) throw new Error("account-session-unavailable");
    return this.sessionView(row);
  }

  async revokeSession(sessionCredentialHash: string): Promise<boolean> {
    const result = await this.pool.query(
      `UPDATE pijoo_sessions SET revoked_at = now()
       WHERE credential_hash = $1 AND revoked_at IS NULL`,
      [sessionCredentialHash],
    );
    return (result.rowCount ?? 0) > 0;
  }

  async createMembership(input: {
    membershipId: string;
    accountId: string;
    channelId: string;
    role: "owner" | "member";
  }): Promise<AccountMembership> {
    const result = await this.pool.query<MembershipRow>(
      `INSERT INTO pijoo_memberships (
        membership_id, account_id, channel_id, role, status, created_at, updated_at
      ) VALUES ($1, $2, $3, $4, 'active', now(), now())
      ON CONFLICT (channel_id, account_id) DO UPDATE
        SET status = 'active', updated_at = now()
        WHERE pijoo_memberships.status = 'removed'
      RETURNING membership_id, account_id, channel_id, role, status, created_at, updated_at`,
      [input.membershipId, input.accountId, input.channelId, input.role],
    );
    const row = result.rows[0];
    if (!row) throw new Error("membership-unavailable");
    return this.membershipView(row);
  }

  async getMembership(accountId: string, channelId: string): Promise<AccountMembership | undefined> {
    const result = await this.pool.query<MembershipRow>(
      `SELECT membership_id, account_id, channel_id, role, status, created_at, updated_at
       FROM pijoo_memberships WHERE account_id = $1 AND channel_id = $2`,
      [accountId, channelId],
    );
    return result.rows[0] ? this.membershipView(result.rows[0]) : undefined;
  }

  async listMemberships(accountId: string): Promise<AccountMembership[]> {
    const result = await this.pool.query<MembershipRow>(
      `SELECT membership_id, account_id, channel_id, role, status, created_at, updated_at
       FROM pijoo_memberships
       WHERE account_id = $1 AND status = 'active'
       ORDER BY created_at`,
      [accountId],
    );
    return result.rows.map((row) => this.membershipView(row));
  }

  async setMembershipStatus(
    channelId: string,
    membershipId: string,
    status: "active" | "removed" | "banned",
  ): Promise<AccountMembership | undefined> {
    const result = await this.pool.query<MembershipRow>(
      `UPDATE pijoo_memberships SET status = $3, updated_at = now()
       WHERE channel_id = $1 AND membership_id = $2
       RETURNING membership_id, account_id, channel_id, role, status, created_at, updated_at`,
      [channelId, membershipId, status],
    );
    return result.rows[0] ? this.membershipView(result.rows[0]) : undefined;
  }

  private async upsertAccount(
    client: PoolClient,
    githubUserId: string,
    displayName: string,
    now: string,
  ): Promise<string> {
    const result = await client.query<{ account_id: string }>(
      `INSERT INTO pijoo_accounts (
        account_id, github_user_id, display_name, status, created_at, updated_at
      ) VALUES ($1, $2, $3, 'active', $4, $4)
      ON CONFLICT (github_user_id) DO UPDATE SET updated_at = EXCLUDED.updated_at
      WHERE pijoo_accounts.status = 'active'
      RETURNING account_id`,
      [randomUUID(), githubUserId, displayName, now],
    );
    const row = result.rows[0];
    if (!row) throw new Error("account-unavailable");
    return row.account_id;
  }

  private sessionView(row: SessionRow): AccountSession {
    return {
      accountId: row.account_id,
      deviceId: row.device_id,
      displayName: row.display_name,
      expiresAt: row.expires_at.toISOString(),
    };
  }

  private membershipView(row: MembershipRow): AccountMembership {
    return {
      membershipId: row.membership_id,
      accountId: row.account_id,
      channelId: row.channel_id,
      role: row.role,
      status: row.status,
      createdAt: row.created_at.toISOString(),
      updatedAt: row.updated_at.toISOString(),
    };
  }
}

export function createPostgresAccountStore(databaseUrl: string): PostgresAccountStore {
  return new PostgresAccountStore(new Pool({ connectionString: databaseUrl }));
}
