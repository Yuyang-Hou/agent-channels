#!/usr/bin/env node
// IMPORTANT: server-side imports (`@hono/node-server`, `./app.js`) live inside
// the `runServer()` function so they're only loaded when the user actually
// starts the local hub. Subcommands like `listen-here` and `receive-recipe`
// must work on Node 16+ — they only use `fetch` / `URL` / fs, no Hono. Putting
// the server imports at top-of-file caused `npx rogerthat listen-here` to crash
// on older Node versions with `Class extends value undefined is not a
// constructor` from `@hono/node-server`'s `class extends GlobalRequest`.
import { existsSync, mkdirSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
// NOTE: `parseArgs` (node:util), `./listen-here.js` and `./receive-recipe.js`
// are imported DYNAMICALLY inside main(), AFTER requireModernNode(). They (and
// listen-here's own `node:util` import) hard-fail at module-load time on Node
// < 18.3 with a cryptic `SyntaxError: 'node:util' does not provide an export
// 'parseArgs'`. Loading them statically would crash before our friendly version
// check could run. Keep the top of this file dependent only on Node-16-safe
// builtins so the guard below is what the user actually sees.

const __dirname = dirname(fileURLToPath(import.meta.url));

/** Hard-require Node >= 18.3 (parseArgs landed there; see package.json engines).
 * Prints a clear message instead of the cryptic parseArgs SyntaxError. */
function requireModernNode(): void {
  const [maj = 0, min = 0] = process.versions.node.split(".").map((n) => Number(n));
  if (maj > 18 || (maj === 18 && min >= 3)) return;
  console.error(
    `rogerthat requires Node >= 18.3 — found v${process.versions.node}.\n` +
      `Upgrade Node (e.g. \`nvm install 20 && nvm use 20\`, or https://nodejs.org) and retry.`,
  );
  process.exit(1);
}

// Load .env (no dependency on dotenv). Tries repo-root .env relative to this file.
(function loadDotEnv() {
  // dist/cli.js -> repo root; src/cli.ts -> repo root (one up from src)
  const candidates = [join(__dirname, "..", ".env"), join(__dirname, "..", "..", ".env")];
  for (const path of candidates) {
    if (!existsSync(path)) continue;
    const content = readFileSync(path, "utf-8");
    for (const line of content.split("\n")) {
      const m = /^\s*([A-Z_][A-Z0-9_]*)\s*=\s*(.*?)\s*$/.exec(line);
      if (m && !process.env[m[1]]) {
        process.env[m[1]] = m[2].replace(/^["']|["']$/g, "");
      }
    }
    break;
  }
})();

let PKG_VERSION = process.env.AGENT_CHANNELS_EMBEDDED_VERSION?.trim() || "?";
try {
  PKG_VERSION = (JSON.parse(readFileSync(join(__dirname, "..", "package.json"), "utf8")) as { version: string }).version;
} catch {
  /* keep "?" if not found */
}

const HELP = `rogerthat ${PKG_VERSION} — walkie-talkie MCP hub for AI agents

usage:
  rogerthat [options]                  # run the local hub (default)
  rogerthat listen-here [options]      # open an SSE receiver for a channel (see --help)
  rogerthat receive-recipe [options]   # print copy-paste recipe: listener + Monitor cmd
  rogerthat host-preflight [options]   # verify a Host conversation without a turn
  rogerthat host-conversations [opts]  # search local Host conversations
  rogerthat channel-mcp [options]      # run the local one-tool channel MCP over stdio

options:
  --port <n>          port to listen on (default: 7424)
  --host <addr>       interface to bind (default: 127.0.0.1)
  --token <secret>    require Bearer token on /mcp/* requests
                      (required when --host is not 127.0.0.1 or localhost)
  --admin-token <s>   enable /admin dashboard with this token
                      (metadata only — never exposes message content)
  --data-dir <path>   single directory holding all rogerthat data
                      (default: ~/.rogerthat — channels.json, stats.json,
                      transcripts/ all live here)
  --data <path>       legacy: just the channels.json path (overrides data-dir)
  --origin <url>      public origin advertised in connect snippets
                      (default: http://<host>:<port>)
  --help, -h          show this help

examples:
  rogerthat                                  # local only, no auth, data in ~/.rogerthat
  rogerthat --port 9000                      # different port
  rogerthat --host 0.0.0.0 --token sekret    # LAN with auth (bearer required)
  rogerthat --data-dir /var/lib/rogerthat     # custom data directory
  rogerthat --origin https://my.example      # if behind a reverse proxy

after starting, install once in your AI client:
  claude mcp add --transport http rogerthat http://127.0.0.1:7424/mcp

then in any session: "create a rogerthat channel" — Claude calls the
create_channel tool and prints a snippet to share with the other agent.

docs: https://rogerthat.chat
`;

function isLocalHost(host: string): boolean {
  return host === "127.0.0.1" || host === "localhost" || host === "::1";
}

async function main(): Promise<void> {
  // Friendly Node-version gate BEFORE any module that imports node:util's
  // parseArgs is loaded (this file, listen-here, receive-recipe all do).
  requireModernNode();
  // Subcommand dispatch: anything before flags. Detect by argv[2] being a
  // non-flag word. Dynamic import so listen-here/receive-recipe (and their
  // parseArgs dependency) only load after the version gate above.
  const first = process.argv[2];
  if (first === "listen-here") {
    const { runListenHere } = await import("./listen-here.js");
    const code = await runListenHere(process.argv.slice(3));
    process.exit(code);
  }
  if (first === "receive-recipe") {
    const { runReceiveRecipe } = await import("./receive-recipe.js");
    const code = runReceiveRecipe(process.argv.slice(3));
    process.exit(code);
  }
  if (first === "host-preflight") {
    const { parseArgs } = await import("node:util");
    let parsed;
    try {
      parsed = parseArgs({
        args: process.argv.slice(3),
        options: {
          "host-provider": { type: "string" },
          "host-conversation": { type: "string" },
          "codex-socket": { type: "string" },
          help: { type: "boolean", short: "h" },
        },
        strict: true,
        allowPositionals: false,
      });
    } catch (error) {
      console.error(`error: ${(error as Error).message}`);
      process.exit(2);
    }
    if (parsed.values.help) {
      console.log("usage: rogerthat host-preflight --host-provider codex --host-conversation <id|codex://threads/id> [--codex-socket <path>]");
      process.exit(0);
    }
    const provider = parsed.values["host-provider"];
    const conversation = parsed.values["host-conversation"];
    if (!provider || !conversation) {
      console.error("error: --host-provider and --host-conversation are required");
      process.exit(2);
    }
    try {
      if (provider !== "codex") throw new Error(`Unsupported Host provider: ${provider}`);
      const { parseCodexThreadId, preflightCodexThread } = await import("./codex-turn.js");
      const threadId = parseCodexThreadId(conversation);
      await preflightCodexThread({
        threadId,
        socketPath: parsed.values["codex-socket"],
      });
      console.log(JSON.stringify({
        ok: true,
        provider,
        conversation_id: threadId,
      }));
      process.exit(0);
    } catch (error) {
      console.error(`error: ${(error as Error).message}`);
      process.exit(1);
    }
  }
  if (first === "host-conversations") {
    const { parseArgs } = await import("node:util");
    let parsed;
    try {
      parsed = parseArgs({
        args: process.argv.slice(3),
        options: {
          "host-provider": { type: "string" },
          query: { type: "string" },
          limit: { type: "string" },
          help: { type: "boolean", short: "h" },
        },
        strict: true,
        allowPositionals: false,
      });
    } catch (error) {
      console.error(`error: ${(error as Error).message}`);
      process.exit(2);
    }
    if (parsed.values.help) {
      console.log("usage: rogerthat host-conversations --host-provider codex [--query <title|id>] [--limit <1-100>]");
      process.exit(0);
    }
    const provider = parsed.values["host-provider"];
    if (!provider) {
      console.error("error: --host-provider is required");
      process.exit(2);
    }
    const limit = parsed.values.limit === undefined ? 30 : Number(parsed.values.limit);
    if (!Number.isInteger(limit) || limit < 1 || limit > 100) {
      console.error("error: --limit must be an integer from 1 to 100");
      process.exit(2);
    }
    try {
      if (provider !== "codex") throw new Error(`Unsupported Host provider: ${provider}`);
      const { listCodexConversations } = await import("./codex-turn.js");
      const conversations = await listCodexConversations({ query: parsed.values.query, limit });
      console.log(JSON.stringify({
        ok: true,
        conversations: conversations.map((item) => ({
          provider,
          conversation_id: item.id,
          title: item.title,
          updated_at: item.updatedAt,
        })),
      }));
      process.exit(0);
    } catch (error) {
      console.error(`error: ${(error as Error).message}`);
      process.exit(1);
    }
  }
  if (first === "channel-mcp" || first === "reply-mcp") {
    const { runChannelMcp } = await import("./reply-mcp.js");
    const code = await runChannelMcp(process.argv.slice(3));
    process.exit(code);
  }
  const { parseArgs } = await import("node:util");
  let parsed;
  try {
    parsed = parseArgs({
      options: {
        port: { type: "string" },
        host: { type: "string" },
        token: { type: "string" },
        "admin-token": { type: "string" },
        "data-dir": { type: "string" },
        data: { type: "string" },
        origin: { type: "string" },
        help: { type: "boolean", short: "h" },
      },
      strict: true,
      allowPositionals: false,
    });
  } catch (e) {
    console.error(`error: ${(e as Error).message}\n`);
    console.error(HELP);
    process.exit(2);
  }

  if (parsed.values.help) {
    console.log(HELP);
    process.exit(0);
  }

  const port = Number(parsed.values.port ?? 7424);
  const host = parsed.values.host ?? "127.0.0.1";
  const token = parsed.values.token;
  const adminToken = parsed.values["admin-token"];
  const dataDir = parsed.values["data-dir"] ?? join(homedir(), ".rogerthat");
  if (!existsSync(dataDir)) mkdirSync(dataDir, { recursive: true });
  const dataPath = parsed.values.data ?? join(dataDir, "channels.json");
  const origin = parsed.values.origin ?? `http://${host === "0.0.0.0" ? "127.0.0.1" : host}:${port}`;

  if (!isLocalHost(host) && !token) {
    console.error(
      `error: --token is required when binding to ${host} (non-localhost). use --token to set a shared secret, or --host 127.0.0.1 to restrict to local.`,
    );
    process.exit(2);
  }

  // Centralize all server-side state under one directory. The data-dir is the umbrella;
  // individual --xxx flags can still override specific files for power users.
  process.env.ROGERRAT_DB = dataPath;
  process.env.ROGERRAT_STATS = process.env.ROGERRAT_STATS ?? join(dataDir, "stats.json");
  process.env.ROGERRAT_TRANSCRIPTS = process.env.ROGERRAT_TRANSCRIPTS ?? join(dataDir, "transcripts");

  // Dynamic import keeps server-side modules (Hono, etc.) off the cold path for
  // `listen-here` and `receive-recipe`. Those need to work on Node 16+, where
  // `@hono/node-server`'s `class extends GlobalRequest` blows up at module-load
  // time even if we never instantiate it.
  const { createApp } = await import("./app.js");
  const { serve } = await import("@hono/node-server");
  const app = createApp({
    publicOrigin: origin,
    authRequired: !!token,
    staticToken: token,
    adminToken,
  });

  console.log(`rogerthat ${PKG_VERSION} — local walkie-talkie hub`);
  console.log(`  listening on   http://${host}:${port}`);
  console.log(`  public origin  ${origin}`);
  console.log(`  data dir       ${dataDir}`);
  console.log(`  auth           ${token ? "required (bearer token on /mcp/*)" : "disabled (local-only)"}`);
  console.log(`  admin UI       ${adminToken ? `enabled at ${origin}/admin` : "disabled (pass --admin-token to enable)"}`);
  console.log("");
  console.log(`install once in your AI client:`);
  console.log(`  claude mcp add --transport http rogerthat ${origin}/mcp${token ? ` --header "Authorization: Bearer ${token}"` : ""}`);
  console.log("");
  console.log(`landing  ${origin}/`);
  console.log(`policy   ${origin}/policy`);
  if (adminToken) console.log(`admin    ${origin}/admin  (token: <hidden>)`);
  console.log("");

  serve({ fetch: app.fetch, hostname: host, port });
}

main().catch((err) => {
  console.error(`fatal:`, err);
  process.exit(1);
});
