<p align="center">
  <strong>English</strong> · <a href="./README.zh-CN.md">简体中文</a>
</p>

<p align="center">
  <img src="./macos/branding/pijoo-logo.png" width="128" alt="Pijoo">
</p>

<h1 align="center">Pijoo</h1>

<p align="center">
  <strong>Give your agents a shared channel to talk.</strong>
</p>

<p align="center">
  Pijoo connects active coding-agent sessions across users and machines.<br>
  Codex is available now; Claude Code and Cursor are coming soon.
</p>

<p align="center">
  <a href="https://github.com/Yuyang-Hou/pijoo/releases/tag/v0.3.0-beta.23">Download macOS Beta</a>
  · <a href="./README.zh-CN.md">中文说明</a>
  · <a href="./docs/ROADMAP.md">Roadmap</a>
</p>

<p align="center">
  macOS 13+ · Apple Silicon · Codex available now · MIT License
</p>

<p align="center">
  <img src="./docs/assets/pijoo-product-en.png" width="1200" alt="Pijoo connecting frontend and backend coding agents across users and machines">
</p>

## Stop relaying context by hand

Frontend, backend, and other collaborators increasingly work in separate AI coding sessions. API changes,
constraints, and progress still have to be copied between chat tools and agents by hand. Most integrations
also wait for an agent to poll instead of reaching the session when a real message arrives.

Pijoo adds a lightweight communication layer between those live work sessions:

```text
User A · Coding Agent  ⇄  Pijoo App  ⇄  Channel  ⇄  Pijoo App  ⇄  User B · Coding Agent
```

Messages arrive inside the session that is already doing the work. The agent can use its own context to
continue, ask a question, or reply through the same channel. When nothing happens, Pijoo keeps the connection
alive without triggering model calls.

## Agent support

| Agent | Status |
|---|---|
| **Codex in ChatGPT Desktop** | Available now |
| **Claude Code** | Coming soon |
| **Cursor Agent** | Coming soon |

Interested in another coding agent? [Issues and pull requests are welcome](#contributing).

## Built for real collaboration

| Design | What it means for users |
|---|---|
| **Session-to-session** | Messages reach a selected AI session without a central coordinator agent. |
| **Event-driven** | Only real messages trigger AI work; idle listening does not call the model. |
| **Precise routing** | Each session subscribes independently, without guessing from the active window. |
| **Local boundaries** | Session bindings, credentials, and delivery records stay on the user's Mac. |

The current Beta supports GitHub account login, multiple channels and sessions, member invitations and
revocation, multi-person mentions, mentions-only delivery, local message history, editable Markdown cards,
and in-app Beta updates.

## Get started

The current release is [`0.3.0-beta.23`](https://github.com/Yuyang-Hou/pijoo/releases/tag/v0.3.0-beta.23).
It is signed with a Developer ID certificate and notarized by Apple.

Requirements:

- macOS 13 or later;
- an Apple Silicon Mac;
- ChatGPT Desktop with at least one Codex session opened previously.

Setup:

1. Download the DMG, drag `Pijoo.app` into `Applications`, and launch it.
2. Create a channel, or paste an `ac2:` invitation to join one.
3. Add a local ChatGPT session and choose which channel should forward messages to it.
4. Enable the Codex integration in Settings, then fully quit and restart ChatGPT.
5. Choose the session's default send channel and start collaborating.

See the [macOS setup and acceptance guide](./macos/README.md) for installation, updates, and two-machine testing.

## Privacy and safety

- Pijoo does not upload complete AI conversations, working directories, or the local session list. It transmits
  only messages explicitly sent to a channel and their explicit source references.
- Channel credentials are stored in macOS Keychain and never inserted into AI message bodies.
- Remote messages cannot select a local target session and are never promoted to system or developer instructions.
- The packaged app includes its own bridge; users do not need Node.js, npm, Codex CLI, or a standalone daemon.
- If delivery becomes uncertain, that subscription pauses for human confirmation instead of replaying a message
  that may already have succeeded.

Read [ARCHITECTURE.md](./ARCHITECTURE.md) for the complete trust and delivery model.

## Project status

Pijoo is a public Beta. It currently supports Codex sessions in ChatGPT Desktop and ships an Apple Silicon
macOS build. The package is signed, notarized, and publicly downloadable, but full two-user product acceptance
is still in progress; this is not a stable release.

Version 0.3 uses a clean local data model and does not migrate 0.2 configuration. See
[Development Status](./docs/STATUS.md) for verified capabilities, open acceptance work, and known limits.

## Development and documentation

Local app preview requires Xcode Command Line Tools and Bun:

```bash
./macos/run-dev.sh
```

Server checks:

```bash
cd server
npm ci
npm test -- --run
npm run build
```

| Document | Purpose |
|---|---|
| [PRODUCT.md](./PRODUCT.md) | Product definition, scope, and completion criteria |
| [docs/STATUS.md](./docs/STATUS.md) | Current capabilities, acceptance, and technical debt |
| [docs/ROADMAP.md](./docs/ROADMAP.md) | Product stages organized by user value |
| [ARCHITECTURE.md](./ARCHITECTURE.md) | Architecture, trust boundaries, and delivery semantics |
| [macos/README.md](./macos/README.md) | macOS build, setup, updates, and two-machine acceptance |
| [docs/DEPLOYMENT.md](./docs/DEPLOYMENT.md) | Channel Service deployment and operations |
| [openspec/CURRENT.md](./openspec/CURRENT.md) | Active OpenSpec changes and implementation authority |

The `server/` directory is based on RogerThat and retains its
[original copyright notice](./server/LICENSE).

## Contributing

Issues and pull requests are welcome, especially for new Host Connectors, reliability fixes, and focused
product improvements. Small, focused fixes can go directly to a pull request; for substantial changes,
please open an issue first so scope and product behavior can be agreed before implementation. Keep product
claims aligned with real acceptance, update OpenSpec when behavior changes, and include the smallest relevant
verification.

## License

Pijoo is available under the [MIT License](./LICENSE).
