# Proposal: Fix MCP Restart Detection

## Why

Pijoo currently uses the App release version as the MCP version. An App-only update therefore asks users to restart
ChatGPT even when the MCP and Skill are unchanged.

## What Changes

- identify the bundled MCP by a stable hash of its source instead of the App release version;
- compare the loaded MCP hash with the bundled MCP hash before showing restart guidance;
- keep Skill updates silent as today.

## Non-Goals

- no MCP hot reload;
- no Skill version UI or restart requirement.
