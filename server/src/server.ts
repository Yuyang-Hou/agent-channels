import { serve } from "@hono/node-server";
import { GitHubOAuthClient, type AccountAuth } from "./account-auth.js";
import { createPostgresAccountStore, type PostgresAccountStore } from "./account-store.js";
import { createApp } from "./app.js";

const PORT = Number(process.env.PORT ?? 7424);
const HOST = process.env.HOST ?? "127.0.0.1";
const PUBLIC_ORIGIN = process.env.PUBLIC_ORIGIN ?? "https://rogerthat.chat";
const ADMIN_TOKEN = process.env.ROGERRAT_ADMIN_TOKEN || undefined;
const DATABASE_URL = process.env.DATABASE_URL?.trim();
const GITHUB_CLIENT_ID = process.env.PIJOO_GITHUB_CLIENT_ID?.trim();
const GITHUB_CLIENT_SECRET = process.env.PIJOO_GITHUB_CLIENT_SECRET?.trim();

const accountValues = [DATABASE_URL, GITHUB_CLIENT_ID, GITHUB_CLIENT_SECRET];
const accountConfigured = accountValues.some(Boolean);
if (accountConfigured && accountValues.some((value) => !value)) {
  throw new Error("Pijoo account configuration requires DATABASE_URL, PIJOO_GITHUB_CLIENT_ID and PIJOO_GITHUB_CLIENT_SECRET");
}

let accountStore: PostgresAccountStore | undefined;
let accountAuth: AccountAuth | undefined;
if (accountConfigured) {
  accountStore = createPostgresAccountStore(DATABASE_URL!);
  await accountStore.migrate();
  accountAuth = {
    store: accountStore,
    github: new GitHubOAuthClient(GITHUB_CLIENT_ID!, GITHUB_CLIENT_SECRET!, PUBLIC_ORIGIN),
  };
}

const app = createApp({
  publicOrigin: PUBLIC_ORIGIN,
  authRequired: true,
  adminToken: ADMIN_TOKEN,
  accountAuth,
});

console.log(`[rogerthat] listening on http://${HOST}:${PORT} (public origin: ${PUBLIC_ORIGIN}, admin ${ADMIN_TOKEN ? "enabled" : "disabled"}, account ${accountAuth ? "enabled" : "disabled"})`);
const server = serve({ fetch: app.fetch, hostname: HOST, port: PORT });

for (const signal of ["SIGINT", "SIGTERM"] as const) {
  process.once(signal, () => {
    server.close(() => {
      if (!accountStore) return process.exit(0);
      void accountStore.close().finally(() => process.exit(0));
    });
  });
}
