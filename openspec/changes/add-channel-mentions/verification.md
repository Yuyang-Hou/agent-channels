# Verification

Status: source implementation and automated checks complete; no package, deployment or live dual-user acceptance completed.

## Required Evidence

- Service send response, history and SSE preserve authenticated mention snapshots.
- Invalid or stale member targets fail before a message id is allocated.
- `mentions_only` still records LocalMessage, terminally filters the delivery and does not call Host.
- App and MCP can send the same three forms: no mention, all, and multiple members.
- Existing state and messages without the new optional fields continue to load and receive all messages.
