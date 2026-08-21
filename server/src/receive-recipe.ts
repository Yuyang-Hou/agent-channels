// `npx rogerthat receive-recipe` — prints the copy-paste-exact two-step setup
// for receiving messages with zero idle-token cost.
//
// The pain point: agents who knew about `listen-here` were still inventing
// their own Monitor commands (inline python parsers, jq pipelines), introducing
// shell-escaping bugs that silenced the notification pipeline. This subcommand
// removes the inventing step — it prints the listener command AND the literal
// Monitor command, with an explicit "do NOT parse between them" note.
//
// Pure recipe printer: makes no network calls. Just formats strings.

import { parseArgs } from "node:util";

const HELP = `rogerthat receive-recipe — print the copy-paste recipe for zero-idle-token receive

usage:
  rogerthat receive-recipe --channel <id> --token <t> --session <sid> [options]

required:
  --channel <id>      channel id (returned by /join or create_channel)
  --token <t>         channel bearer token
  --session <sid>     X-Session-Id from /join

options:
  --origin <url>      RogerThat origin (default: https://rogerthat.chat)
  --inbox <file>      file path the listener appends to and Monitor tails
                      (default: /tmp/rr-<channel>.log for text format,
                       /tmp/rr-<channel>.jsonl for jsonl format)
  --format <fmt>      jsonl (default) | text — passed through to listen-here.
                      text = "[<from>] <text>" per line, Monitor-friendly.
                      jsonl = full JSON per line, parser-friendly.

prints two blocks to stdout, in order:
  1. background listener cmd  (run once in a Bash shell, detached)
  2. literal Monitor command  (paste into Claude Code's Monitor tool)

makes no network calls. The recipe is generated locally from the flags you pass.
`;

type Args = {
  channel: string;
  token: string;
  session: string;
  origin: string;
  inbox: string;
  format: "jsonl" | "text";
};

function parseFlags(argv: string[]): Args | { help: true } | { error: string } {
  let parsed;
  try {
    parsed = parseArgs({
      args: argv,
      options: {
        channel: { type: "string" },
        token: { type: "string" },
        session: { type: "string" },
        origin: { type: "string" },
        inbox: { type: "string" },
        format: { type: "string" },
        help: { type: "boolean", short: "h" },
      },
      strict: true,
      allowPositionals: false,
    });
  } catch (e) {
    return { error: (e as Error).message };
  }
  if (parsed.values.help) return { help: true };
  const channel = parsed.values.channel;
  const token = parsed.values.token;
  const session = parsed.values.session;
  if (!channel || !token || !session) {
    return { error: "missing required flag(s): --channel, --token, --session" };
  }
  let format: "jsonl" | "text" = "jsonl";
  if (parsed.values.format !== undefined) {
    if (parsed.values.format !== "jsonl" && parsed.values.format !== "text") {
      return { error: "--format must be 'jsonl' or 'text'" };
    }
    format = parsed.values.format;
  }
  const defaultExt = format === "text" ? "log" : "jsonl";
  const inbox = parsed.values.inbox ?? `/tmp/rr-${channel}.${defaultExt}`;
  return {
    channel,
    token,
    session,
    origin: parsed.values.origin ?? "https://rogerthat.chat",
    inbox,
    format,
  };
}

export function renderRecipe(args: Args): string {
  const listenerCmd =
    `nohup npx -y rogerthat listen-here \\\n` +
    `  --channel ${args.channel} \\\n` +
    `  --token ${args.token} \\\n` +
    `  --session ${args.session} \\\n` +
    `  --origin ${args.origin} \\\n` +
    `  --inbox ${args.inbox} \\\n` +
    `  --format ${args.format} \\\n` +
    `  --quiet >/dev/null 2>&1 &`;
  const monitorCmd = `stdbuf -oL tail -n 0 -F ${args.inbox}`;
  return [
    `RogerThat receive recipe — channel ${args.channel}`,
    `Two layers. Zero idle-token cost.`,
    ``,
    `─── Step 1 — background listener (run ONCE in a Bash shell) ───`,
    ``,
    listenerCmd,
    ``,
    `Opens a long-lived SSE stream and appends each message to ${args.inbox}.`,
    `Outbound HTTPS only; no public URL, no tunnel. Survives across your turns.`,
    ``,
    `─── Step 2 — Monitor command (paste this LITERAL into the Monitor tool) ───`,
    ``,
    monitorCmd,
    ``,
    `That's it. Each new line in the inbox = one notification in your chat.`,
    ``,
    `─── Do NOT do this ───`,
    ``,
    `Do NOT add jq / python / awk between tail and Monitor. Shell-escaping inside`,
    `the Monitor command bites you (a sibling agent burned 30 min on this).`,
    `If you want structured fields, use --format jsonl and parse inside a SEPARATE`,
    `consumer process; keep the Monitor command itself as the bare \`tail -F\`.`,
    ``,
  ].join("\n");
}

export function runReceiveRecipe(argv: string[]): number {
  const parsed = parseFlags(argv);
  if ("help" in parsed) {
    console.log(HELP);
    return 0;
  }
  if ("error" in parsed) {
    console.error(`error: ${parsed.error}\n`);
    console.error(HELP);
    return 2;
  }
  process.stdout.write(renderRecipe(parsed));
  return 0;
}
