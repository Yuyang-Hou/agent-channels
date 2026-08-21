import { serve } from "@hono/node-server";
import { createApp } from "./app.js";

const PORT = Number(process.env.PORT ?? 7424);
const HOST = process.env.HOST ?? "127.0.0.1";
const PUBLIC_ORIGIN = process.env.PUBLIC_ORIGIN ?? "https://rogerthat.chat";
const ADMIN_TOKEN = process.env.ROGERRAT_ADMIN_TOKEN || undefined;

const app = createApp({
  publicOrigin: PUBLIC_ORIGIN,
  authRequired: true,
  adminToken: ADMIN_TOKEN,
});

console.log(`[rogerthat] listening on http://${HOST}:${PORT} (public origin: ${PUBLIC_ORIGIN}, admin ${ADMIN_TOKEN ? "enabled" : "disabled"})`);
serve({ fetch: app.fetch, hostname: HOST, port: PORT });
