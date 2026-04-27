---
description: Connect this Codex session to PeKG (pekg.ai)
---

Run the PeKG connect script:

```bash
~/.pekg/bin/pekg-connect.sh
```

The script opens a browser for OTP-based authentication, saves the token to `~/.pekg/config.json`, and registers the MCP server in `~/.codex/config.toml`. After it completes, restart Codex so the MCP registration takes effect.

If you already have a token, the script verifies it and exits.
