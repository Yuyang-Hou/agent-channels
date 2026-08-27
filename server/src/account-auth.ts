import { createHash, randomBytes } from "node:crypto";
import type { Context, Hono } from "hono";
import type { AccountSession, AccountStore } from "./account-store.js";

const LOGIN_TTL_MS = 10 * 60 * 1000;
const SESSION_TTL_MS = 90 * 24 * 60 * 60 * 1000;
const CALLBACK_URI = "pijoo://oauth/callback";
const START_LIMIT = 20;
const START_WINDOW_MS = 60 * 60 * 1000;

export type GitHubIdentity = { id: string; displayName: string };

export interface GitHubIdentityProvider {
  authorizationUrl(input: { state: string; codeChallenge: string }): string;
  identify(input: { code: string; codeVerifier: string }): Promise<GitHubIdentity>;
}

export type AccountAuth = {
  store: AccountStore;
  github: GitHubIdentityProvider;
};

type StartBucket = { count: number; resetAt: number };

class AccountAuthError extends Error {
  constructor(readonly code: string, readonly status: 400 | 401 | 404 | 409 | 429 | 503 = 400) {
    super(code);
  }
}

export class GitHubOAuthClient implements GitHubIdentityProvider {
  private readonly callbackUrl: string;

  constructor(
    private readonly clientId: string,
    private readonly clientSecret: string,
    publicOrigin: string,
    private readonly fetchImpl: typeof fetch = fetch,
  ) {
    this.callbackUrl = new URL("/v1/auth/github/callback", publicOrigin).toString();
  }

  authorizationUrl(input: { state: string; codeChallenge: string }): string {
    const url = new URL("https://github.com/login/oauth/authorize");
    url.searchParams.set("client_id", this.clientId);
    url.searchParams.set("redirect_uri", this.callbackUrl);
    url.searchParams.set("state", input.state);
    url.searchParams.set("code_challenge", input.codeChallenge);
    url.searchParams.set("code_challenge_method", "S256");
    url.searchParams.set("prompt", "select_account");
    return url.toString();
  }

  async identify(input: { code: string; codeVerifier: string }): Promise<GitHubIdentity> {
    const tokenResponse = await this.fetchImpl("https://github.com/login/oauth/access_token", {
      method: "POST",
      headers: { accept: "application/json", "content-type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({
        client_id: this.clientId,
        client_secret: this.clientSecret,
        code: input.code,
        redirect_uri: this.callbackUrl,
        code_verifier: input.codeVerifier,
      }),
      signal: AbortSignal.timeout(10_000),
    });
    const token = (await tokenResponse.json()) as { access_token?: unknown; scope?: unknown };
    if (
      !tokenResponse.ok ||
      typeof token.access_token !== "string" ||
      !token.access_token ||
      typeof token.scope !== "string" ||
      token.scope.trim() !== ""
    ) {
      throw new AccountAuthError("github-authentication-failed", 401);
    }
    const userResponse = await this.fetchImpl("https://api.github.com/user", {
      headers: {
        accept: "application/vnd.github+json",
        authorization: `Bearer ${token.access_token}`,
        "user-agent": "Pijoo",
        "x-github-api-version": "2022-11-28",
      },
      signal: AbortSignal.timeout(10_000),
    });
    const user = (await userResponse.json()) as { id?: unknown; login?: unknown; name?: unknown };
    if (!userResponse.ok || (typeof user.id !== "number" && typeof user.id !== "string")) {
      throw new AccountAuthError("github-authentication-failed", 401);
    }
    const name = typeof user.name === "string" ? user.name.trim() : "";
    const login = typeof user.login === "string" ? user.login.trim() : "";
    return { id: String(user.id), displayName: String(name || login || "Pijoo 用户").slice(0, 120) };
  }
}

export function registerAccountRoutes(app: Hono, auth: AccountAuth): void {
  const starts = new Map<string, StartBucket>();

  app.get("/ready", async (c) => {
    try {
      await auth.store.ready();
      return c.text("ok");
    } catch {
      return c.text("database unavailable", 503);
    }
  });

  app.get("/v1/auth/github/start", async (c) => {
    try {
      enforceStartLimit(starts, requestAddress(c.req.header("x-forwarded-for")));
      const codeChallenge = pkceChallenge(c.req.query("code_challenge"));
      const clientState = boundedBase64Url(c.req.query("client_state"), "client_state", 43, 200);
      const deviceName = deviceNameValue(c.req.query("device_name"));
      const githubState = randomValue();
      const githubVerifier = randomValue();
      await auth.store.createLoginAttempt({
        githubStateHash: digest(githubState),
        githubPkceVerifier: githubVerifier,
        appCodeChallenge: codeChallenge,
        clientState,
        deviceName,
        expiresAt: new Date(Date.now() + LOGIN_TTL_MS).toISOString(),
      });
      c.header("cache-control", "no-store");
      return c.redirect(
        auth.github.authorizationUrl({ state: githubState, codeChallenge: challenge(githubVerifier) }),
        303,
      );
    } catch (error) {
      return authError(c, error);
    }
  });

  app.get("/v1/auth/github/callback", async (c) => {
    const state = c.req.query("state") ?? "";
    try {
      if (!state) throw new AccountAuthError("login-state-invalid", 400);
      if (c.req.query("error")) {
        const clientState = await auth.store.cancelLoginAttempt(digest(state));
        return c.redirect(callbackUrl({ error: "login_cancelled", state: clientState }), 303);
      }
      const code = c.req.query("code") ?? "";
      if (!code || code.length > 512) throw new AccountAuthError("github-callback-invalid", 400);
      const attempt = await auth.store.getLoginAttemptForCallback(digest(state));
      const identity = await auth.github.identify({ code, codeVerifier: attempt.githubPkceVerifier });
      const exchangeCode = randomValue();
      const clientState = await auth.store.authenticateLoginAttempt({
        attemptId: attempt.id,
        githubUserId: identity.id,
        githubDisplayName: identity.displayName,
        exchangeCodeHash: digest(exchangeCode),
      });
      return c.redirect(callbackUrl({ code: exchangeCode, state: clientState }), 303);
    } catch (error) {
      return authError(c, error);
    }
  });

  app.post("/v1/auth/device/exchange", async (c) => {
    try {
      const body = await jsonObject(c);
      const exchangeCode = boundedBase64Url(body.exchange_code, "exchange_code", 43, 128);
      const codeVerifier = pkceVerifier(body.code_verifier);
      const sessionCredential = randomValue();
      const session = await auth.store.redeemLoginAttempt({
        exchangeCodeHash: digest(exchangeCode),
        appCodeChallenge: challenge(codeVerifier),
        sessionCredentialHash: digest(sessionCredential),
        sessionExpiresAt: new Date(Date.now() + SESSION_TTL_MS).toISOString(),
      });
      c.header("cache-control", "no-store");
      return c.json(sessionResponse(session, sessionCredential));
    } catch (error) {
      return authError(c, error);
    }
  });

  app.get("/v1/session", async (c) => {
    try {
      const credential = bearer(c.req.header("authorization"));
      c.header("cache-control", "no-store");
      return c.json(sessionResponse(await auth.store.getSession(digest(credential))));
    } catch (error) {
      return authError(c, error, 401);
    }
  });

  app.post("/v1/session/logout", async (c) => {
    try {
      const credential = bearer(c.req.header("authorization"));
      if (!(await auth.store.revokeSession(digest(credential)))) {
        throw new AccountAuthError("account-session-unavailable", 401);
      }
      c.header("cache-control", "no-store");
      return c.json({ ok: true });
    } catch (error) {
      return authError(c, error, 401);
    }
  });
}

function sessionResponse(session: AccountSession, credential?: string) {
  return {
    account_id: session.accountId,
    device_id: session.deviceId,
    display_name: session.displayName,
    expires_at: session.expiresAt,
    ...(credential ? { session_credential: credential } : {}),
  };
}

function callbackUrl(parameters: Record<string, string>): string {
  const url = new URL(CALLBACK_URI);
  for (const [name, value] of Object.entries(parameters)) url.searchParams.set(name, value);
  return url.toString();
}

function requestAddress(forwarded: string | undefined): string {
  return String(forwarded?.split(",")[0]?.trim() || "unknown").slice(0, 128);
}

function enforceStartLimit(buckets: Map<string, StartBucket>, key: string): void {
  const now = Date.now();
  const current = buckets.get(key);
  if (!current || current.resetAt <= now) {
    buckets.set(key, { count: 1, resetAt: now + START_WINDOW_MS });
    return;
  }
  if (current.count >= START_LIMIT) throw new AccountAuthError("authentication-rate-limited", 429);
  current.count += 1;
}

function digest(value: string): string {
  return createHash("sha256").update(value).digest("hex");
}

function challenge(verifier: string): string {
  return createHash("sha256").update(verifier).digest("base64url");
}

function randomValue(): string {
  return randomBytes(32).toString("base64url");
}

function boundedBase64Url(value: unknown, name: string, min: number, max: number): string {
  if (typeof value !== "string" || value.length < min || value.length > max || !/^[A-Za-z0-9_-]+$/.test(value)) {
    throw new AccountAuthError(`${name}-invalid`, 400);
  }
  return value;
}

function pkceChallenge(value: unknown): string {
  return boundedBase64Url(value, "code_challenge", 43, 128);
}

function pkceVerifier(value: unknown): string {
  if (typeof value !== "string" || value.length < 43 || value.length > 128 || !/^[A-Za-z0-9._~-]+$/.test(value)) {
    throw new AccountAuthError("code_verifier-invalid", 400);
  }
  return value;
}

function deviceNameValue(value: unknown): string {
  if (typeof value !== "string") throw new AccountAuthError("device_name-invalid", 400);
  const name = value.trim();
  if (!name || name.length > 120 || /[\u0000-\u001f\u007f]/.test(name)) {
    throw new AccountAuthError("device_name-invalid", 400);
  }
  return name;
}

function bearer(value: string | undefined): string {
  const match = /^Bearer ([A-Za-z0-9_-]{43})$/.exec(value ?? "");
  if (!match) throw new AccountAuthError("account-session-unavailable", 401);
  return match[1];
}

async function jsonObject(c: Context): Promise<Record<string, unknown>> {
  try {
    const body = await c.req.json();
    if (!body || typeof body !== "object" || Array.isArray(body)) throw new Error();
    return body as Record<string, unknown>;
  } catch {
    throw new AccountAuthError("request-body-invalid", 400);
  }
}

function authError(
  c: Context,
  error: unknown,
  fallbackStatus: 400 | 401 = 400,
) {
  const known = error instanceof AccountAuthError ? error : undefined;
  const code = known?.code ?? (error instanceof Error && /^login-|^account-/.test(error.message) ? error.message : "authentication-failed");
  const status = known?.status ?? (code === "account-session-unavailable" ? 401 : fallbackStatus);
  c.header("cache-control", "no-store");
  return c.json({ error: code, code }, status);
}
