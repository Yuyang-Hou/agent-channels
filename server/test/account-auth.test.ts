import { createHash } from "node:crypto";
import { describe, expect, it, vi } from "vitest";
import {
  GitHubOAuthClient,
  type GitHubIdentityProvider,
} from "../src/account-auth.js";
import type {
  AccountSession,
  AccountStore,
  LoginAttempt,
} from "../src/account-store.js";
import { createApp } from "../src/app.js";

const ORIGIN = "https://pijoo.test";

type Attempt = LoginAttempt & {
  githubStateHash: string;
  appCodeChallenge: string;
  deviceName: string;
  expiresAt: string;
  githubUserId?: string;
  githubDisplayName?: string;
  exchangeCodeHash?: string;
};

class MemoryAccountStore implements AccountStore {
  attempts = new Map<string, Attempt>();
  sessions = new Map<string, AccountSession>();

  async ready() {}

  async createLoginAttempt(input: {
    githubStateHash: string;
    githubPkceVerifier: string;
    appCodeChallenge: string;
    clientState: string;
    deviceName: string;
    expiresAt: string;
  }) {
    const id = `attempt-${this.attempts.size + 1}`;
    this.attempts.set(input.githubStateHash, { id, ...input });
  }

  async getLoginAttemptForCallback(githubStateHash: string) {
    const attempt = this.attempts.get(githubStateHash);
    if (!attempt || attempt.githubUserId || Date.parse(attempt.expiresAt) <= Date.now()) {
      throw new Error("login-attempt-unavailable");
    }
    return attempt;
  }

  async authenticateLoginAttempt(input: {
    attemptId: string;
    githubUserId: string;
    githubDisplayName: string;
    exchangeCodeHash: string;
  }) {
    const attempt = [...this.attempts.values()].find((candidate) => candidate.id === input.attemptId);
    if (!attempt || attempt.githubUserId) throw new Error("login-attempt-unavailable");
    attempt.githubUserId = input.githubUserId;
    attempt.githubDisplayName = input.githubDisplayName;
    attempt.exchangeCodeHash = input.exchangeCodeHash;
    return attempt.clientState;
  }

  async cancelLoginAttempt(githubStateHash: string) {
    const attempt = this.attempts.get(githubStateHash);
    if (!attempt) throw new Error("login-attempt-unavailable");
    this.attempts.delete(githubStateHash);
    return attempt.clientState;
  }

  async redeemLoginAttempt(input: {
    exchangeCodeHash: string;
    appCodeChallenge: string;
    sessionCredentialHash: string;
    sessionExpiresAt: string;
  }) {
    const entry = [...this.attempts.entries()].find(([, attempt]) =>
      attempt.exchangeCodeHash === input.exchangeCodeHash &&
      attempt.appCodeChallenge === input.appCodeChallenge
    );
    if (!entry) throw new Error("login-exchange-invalid");
    const [stateHash, attempt] = entry;
    this.attempts.delete(stateHash);
    const session = {
      accountId: `account-${attempt.githubUserId}`,
      deviceId: "device-1",
      displayName: attempt.githubDisplayName!,
      expiresAt: input.sessionExpiresAt,
    };
    this.sessions.set(input.sessionCredentialHash, session);
    return session;
  }

  async getSession(sessionCredentialHash: string) {
    const session = this.sessions.get(sessionCredentialHash);
    if (!session) throw new Error("account-session-unavailable");
    return session;
  }

  async revokeSession(sessionCredentialHash: string) {
    return this.sessions.delete(sessionCredentialHash);
  }
}

class FakeGitHub implements GitHubIdentityProvider {
  authorizationUrl(input: { state: string; codeChallenge: string }) {
    const url = new URL("https://github.test/authorize");
    url.searchParams.set("state", input.state);
    url.searchParams.set("code_challenge", input.codeChallenge);
    return url.toString();
  }

  async identify(input: { code: string; codeVerifier: string }) {
    expect(input.code).toBe("github-code");
    expect(input.codeVerifier).toHaveLength(43);
    return { id: "42", displayName: "Pijoo Tester" };
  }
}

function digest(value: string) {
  return createHash("sha256").update(value).digest("hex");
}

function challenge(value: string) {
  return createHash("sha256").update(value).digest("base64url");
}

describe("GitHub account login", () => {
  it("keeps account routes disabled unless configured", async () => {
    const app = createApp({ publicOrigin: ORIGIN, authRequired: true });
    const info = await app.request("/api/v1/info");
    expect(((await info.json()) as { features: string[] }).features).toEqual([]);
    expect((await app.request("/v1/auth/github/start")).status).toBe(404);
    expect((await app.request("/ready")).status).toBe(200);
  });

  it("exchanges one OAuth callback for one revocable Pijoo session", async () => {
    const store = new MemoryAccountStore();
    const app = createApp({
      publicOrigin: ORIGIN,
      authRequired: true,
      accountAuth: { store, github: new FakeGitHub() },
    });
    const verifier = "v".repeat(43);
    const clientState = "s".repeat(43);
    const start = await app.request(
      `/v1/auth/github/start?code_challenge=${challenge(verifier)}&client_state=${clientState}&device_name=Test%20Mac`,
    );
    expect(start.status).toBe(303);
    const authorize = new URL(start.headers.get("location")!);
    const providerState = authorize.searchParams.get("state")!;
    expect(authorize.searchParams.get("code_challenge")).toHaveLength(43);

    const callback = await app.request(
      `/v1/auth/github/callback?state=${providerState}&code=github-code`,
    );
    expect(callback.status).toBe(303);
    const callbackUrl = new URL(callback.headers.get("location")!);
    expect(callbackUrl.protocol).toBe("pijoo:");
    expect(callbackUrl.searchParams.get("state")).toBe(clientState);
    const exchangeCode = callbackUrl.searchParams.get("code")!;

    const exchange = await app.request("/v1/auth/device/exchange", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ exchange_code: exchangeCode, code_verifier: verifier }),
    });
    expect(exchange.status).toBe(200);
    const login = (await exchange.json()) as {
      account_id: string;
      display_name: string;
      session_credential: string;
    };
    expect(login).toMatchObject({ account_id: "account-42", display_name: "Pijoo Tester" });
    expect(login.session_credential).toHaveLength(43);

    const replay = await app.request("/v1/auth/device/exchange", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ exchange_code: exchangeCode, code_verifier: verifier }),
    });
    expect(replay.status).toBe(400);

    const session = await app.request("/v1/session", {
      headers: { authorization: `Bearer ${login.session_credential}` },
    });
    expect(session.status).toBe(200);
    expect(await session.json()).not.toHaveProperty("session_credential");

    expect((await app.request("/v1/session/logout", {
      method: "POST",
      headers: { authorization: `Bearer ${login.session_credential}` },
    })).status).toBe(200);
    expect((await app.request("/v1/session", {
      headers: { authorization: `Bearer ${login.session_credential}` },
    })).status).toBe(401);
  });

  it("returns cancellation to the requesting app state", async () => {
    const store = new MemoryAccountStore();
    const app = createApp({
      publicOrigin: ORIGIN,
      authRequired: true,
      accountAuth: { store, github: new FakeGitHub() },
    });
    const start = await app.request(
      `/v1/auth/github/start?code_challenge=${"c".repeat(43)}&client_state=${"s".repeat(43)}&device_name=Mac`,
    );
    const providerState = new URL(start.headers.get("location")!).searchParams.get("state")!;
    const callback = await app.request(
      `/v1/auth/github/callback?state=${providerState}&error=access_denied`,
    );
    const location = new URL(callback.headers.get("location")!);
    expect(location.searchParams.get("error")).toBe("login_cancelled");
    expect(location.searchParams.get("state")).toBe("s".repeat(43));
  });

  it("uses GitHub PKCE without requesting repository scopes", async () => {
    const fetchImpl = vi.fn<typeof fetch>()
      .mockResolvedValueOnce(new Response(JSON.stringify({ access_token: "provider-secret", scope: "" }), { status: 200 }))
      .mockResolvedValueOnce(new Response(JSON.stringify({ id: 7, login: "pijoo-user" }), { status: 200 }));
    const github = new GitHubOAuthClient("client", "secret", ORIGIN, fetchImpl);
    const authorization = new URL(github.authorizationUrl({ state: "state", codeChallenge: "c".repeat(43) }));
    expect(authorization.searchParams.has("scope")).toBe(false);
    const identity = await github.identify({ code: "code", codeVerifier: "v".repeat(43) });
    expect(identity).toEqual({ id: "7", displayName: "pijoo-user" });
    const tokenRequest = fetchImpl.mock.calls[0];
    expect(String(tokenRequest[1]?.body)).toContain(`code_verifier=${"v".repeat(43)}`);
  });

  it("rejects a GitHub token carrying repository or profile scopes", async () => {
    const fetchImpl = vi.fn<typeof fetch>()
      .mockResolvedValueOnce(new Response(JSON.stringify({ access_token: "provider-secret", scope: "repo" }), { status: 200 }));
    const github = new GitHubOAuthClient("client", "secret", ORIGIN, fetchImpl);
    await expect(github.identify({ code: "code", codeVerifier: "v".repeat(43) }))
      .rejects.toThrow("github-authentication-failed");
    expect(fetchImpl).toHaveBeenCalledTimes(1);
  });

  it("rejects malformed PKCE before creating an attempt", async () => {
    const store = new MemoryAccountStore();
    const app = createApp({
      publicOrigin: ORIGIN,
      authRequired: true,
      accountAuth: { store, github: new FakeGitHub() },
    });
    const response = await app.request(
      `/v1/auth/github/start?code_challenge=short&client_state=${"s".repeat(43)}&device_name=Mac`,
    );
    expect(response.status).toBe(400);
    expect(store.attempts.size).toBe(0);
  });
});
