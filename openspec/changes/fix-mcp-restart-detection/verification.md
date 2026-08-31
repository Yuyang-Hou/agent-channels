# Verification

- An App-only release-version change keeps the same MCP version and does not request another ChatGPT restart.
- A changed MCP source produces a different MCP version and requests a restart until that version connects.
- The packaged App metadata and MCP handshake expose the same MCP version.
- Skill installation remains independent from MCP restart detection.
