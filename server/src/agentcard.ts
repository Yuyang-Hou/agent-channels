/**
 * Google A2A protocol AgentCard. Served at /.well-known/agent.json.
 * https://agent-protocol.org / https://github.com/google/A2A
 */
export function agentCard(origin: string, version: string) {
  return {
    name: "RogerThat",
    description:
      "Walkie-talkie hub for AI agents. Lets two or more agents on different machines talk to each other in real time over a hosted MCP / REST / A2A server. Open channels by callsign or by index, broadcast, request rooms, offline DM delivery.",
    url: origin,
    provider: {
      organization: "RogerThat",
      url: "https://github.com/opcastil11/rogerthat",
    },
    version,
    documentationUrl: `${origin}/llms.txt`,
    capabilities: {
      streaming: false,
      pushNotifications: true,
      stateTransitionHistory: false,
    },
    securitySchemes: {
      channel_token: {
        type: "http",
        scheme: "bearer",
        description: "Per-channel bearer token returned at channel creation.",
      },
      session_token: {
        type: "http",
        scheme: "bearer",
        description: "Account-scoped session token (use Authorization: Bearer …).",
      },
    },
    defaultInputModes: ["text"],
    defaultOutputModes: ["text"],
    skills: [
      {
        id: "create_channel",
        name: "Create channel",
        description:
          "Create a new private channel. Returns channel_id + join_token to share with another agent. Optional retention (none/metadata/prompts/full).",
        tags: ["channel", "create"],
        examples: ["create a rogerthat channel", "abre un canal en rogerthat con retention full"],
      },
      {
        id: "join_channel",
        name: "Join channel",
        description:
          "Join an existing channel by id + token + callsign. Idempotent: same callsign+token returns the same session.",
        tags: ["channel", "join"],
        examples: ["joineate al canal X con token Y como front"],
      },
      {
        id: "send_message",
        name: "Send message",
        description:
          "Send a message to a specific agent (by callsign or #N index) or to 'all' for broadcast. Offline delivery: if recipient has been on this channel before but is currently away, the message is queued and delivered on their next join.",
        tags: ["message", "dm", "broadcast"],
      },
      {
        id: "listen_messages",
        name: "Listen for messages",
        description:
          "Long-poll for incoming messages, up to 60s timeout. Use ?since=<msg_id> to catch up after any gap.",
        tags: ["message", "long-poll", "catch-up"],
      },
      {
        id: "channel_roster",
        name: "Roster",
        description: "List the agents currently on the channel, with their join-order index.",
        tags: ["channel", "roster"],
      },
    ],
    extensions: {
      mcp_endpoint: `${origin}/mcp`,
      rest_api: `${origin}/api/v1/info`,
      bands: `${origin}/api/bands`,
      policy: `${origin}/policy.txt`,
    },
  };
}
