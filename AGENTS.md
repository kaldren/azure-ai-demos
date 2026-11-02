# Agent instructions

## Microsoft Foundry: where to look things up

The **Microsoft Learn MCP server** is the main knowledge base for anything about Microsoft
Foundry (Azure AI Foundry): agents, models, deployments, projects, SDKs, APIs, tools,
evaluation, and related Azure services.

For any question or code about Foundry, follow this order:

1. **Check Microsoft Learn MCP first.**
   - `microsoft_docs_search`: find the relevant docs.
   - `microsoft_docs_fetch`: read a full page when the search snippets aren't enough.
   - `microsoft_code_sample_search`: find official code samples (set `language` to `python` or `csharp`).
2. **If the answer isn't there, search the web.** Prefer official Microsoft sources
   (learn.microsoft.com, the Azure SDK repos on GitHub, Microsoft Foundry blog posts).
3. **Don't trust your training data for Foundry.** Product names, SDK packages, API versions
   and class names change often, so old knowledge is likely wrong. Check every package name,
   method signature and API version against a current source before you use it.

When you answer, say where the information came from (a doc URL). If sources disagree, point
that out and go with the newest one.

### Setup

- **Claude Code:** the server is defined in `.mcp.json`. Approve it when Claude Code asks.
- **Codex:** run this once:
  `codex mcp add "microsoft-learn" --url "https://learn.microsoft.com/api/mcp"`

If the Microsoft Learn MCP tools aren't available in your session, say so. Then fall back to
step 2, and don't answer from memory.
