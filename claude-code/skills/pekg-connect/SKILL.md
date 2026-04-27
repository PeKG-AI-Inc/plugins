---
name: pekg-connect
description: Connect this Claude Code session to PeKG (pekg.ai). Opens a browser to authenticate, saves the token to ~/.pekg/config.json, and registers the MCP server.
---

# /pekg-connect — link this session to your PeKG account

When the user invokes this skill, run the connect script. It implements the OTP browser auth flow from the OpenCode plugin (A47).

## Steps

1. Run the connect script:

```bash
~/.pekg/bin/pekg-connect.sh
```

2. The script will:
   - POST to `https://api.pekg.ai/api/v1/auth/otp` to obtain an OTP + connect URL
   - Open the URL in the user's browser (`open` on macOS, `xdg-open` on Linux, `start` on Windows)
   - Poll `/api/v1/auth/otp-status?otp=...` every 3s for up to 5min until the user pairs in the browser
   - On success, write the token to `~/.pekg/config.json` with mode `0600`
   - Register the MCP server via `~/.claude/mcp_servers.json` or project `.mcp.json`
   - Verify the token by fetching `/api/v1/dashboard/stats`

3. Print the result to the user. On success, instruct them to restart Claude Code so the MCP server registration takes effect.

## On failure

- If the user already has a token, print "Already connected" and verify it still works.
- If the OTP poll times out, print the URL and ask them to retry.
- If the dashboard verification fails, print the API error message and suggest checking pekg.ai status.

## After connect

The PeKG MCP tools (`mcp__pekg__status`, `mcp__pekg__search`, `mcp__pekg__context`, etc.) become available on the next session. The user should run `mcp__pekg__status` once per session per the project's CLAUDE.md.
