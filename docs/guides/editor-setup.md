# Editor Setup

All integrations use the same endpoint:

- MCP URL: `http://localhost:9847/mcp`

## Claude Code

Create `.mcp.json` in your project root:

```json
{
  "mcpServers": {
    "apus": {
      "type": "http",
      "url": "http://localhost:9847/mcp"
    }
  }
}
```

## Cursor

In Cursor Settings -> MCP Servers, add:

```json
{
  "apus": {
    "url": "http://localhost:9847/mcp"
  }
}
```

## VS Code (GitHub Copilot)

In `.vscode/mcp.json`:

```json
{
  "servers": {
    "apus": {
      "type": "http",
      "url": "http://localhost:9847/mcp"
    }
  }
}
```

## Claude Desktop

In `claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "apus": {
      "type": "http",
      "url": "http://localhost:9847/mcp"
    }
  }
}
```

## Connectivity Checklist

1. The app is running in Debug and calls `Apus.shared.start(...)`.
2. `http://localhost:9847/` shows `Status: Running`.
3. The editor MCP URL matches the app port if you changed it.
