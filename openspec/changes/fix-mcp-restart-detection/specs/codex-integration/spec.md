# Codex Integration Delta

## ADDED Requirements

### Requirement: restart guidance follows the MCP component

Pijoo MUST identify the bundled MCP independently from the App release version. The App MUST request a complete
ChatGPT restart only when Codex integration is configured and the loaded MCP version differs from the bundled MCP
version. Skill changes MUST NOT by themselves request a ChatGPT restart.

#### Scenario: App changes without an MCP change

- **WHEN** the App release version changes but the bundled MCP source is unchanged
- **THEN** the bundled MCP version remains unchanged
- **AND** an already loaded matching MCP remains ready without restart guidance

#### Scenario: MCP changes

- **WHEN** the bundled MCP source changes
- **THEN** its version changes
- **AND** the App requests a complete ChatGPT restart until the new MCP reports that version
