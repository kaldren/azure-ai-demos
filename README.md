# Azure AI Demos

Small, self-contained demos for trying out Azure services in .NET and Python.

## Layout

```
<language>/<use-case>/<demo-name>/
```

| Folder     | Contents                                    |
|------------|---------------------------------------------|
| `dotnet/`  | .NET demos (shared settings in `Directory.Build.props`) |
| `python/`  | Python demos (each one is its own `uv` project) |
| `*/_template/` | Copy this folder to start a new demo         |

Use cases (add more as needed): `agents`, `ai-search`, `openai`, `document-intelligence`, `speech`, ...

## Conventions

- **Folder names** are kebab-case and match across languages, e.g.
  `python/agents/basic-agent` and `dotnet/agents/basic-agent`.
- **Every demo runs on its own.** No shared code between demos, so you can copy or delete one without breaking another.
- **Auth:** use `DefaultAzureCredential` and run `az login` once. Config should then only need endpoints, not keys.
- **Config:** Python uses `.env` (copy `.env.example`). .NET uses `dotnet user-secrets` or `appsettings.Development.json`. Both are gitignored.
- **Each demo has a README** covering what it shows, the Azure resources it needs, how to run it, and what you learned.

## Starting a new demo

```bash
# Python
cp -r python/_template python/agents/my-demo
cd python/agents/my-demo && uv sync && uv run main.py

# .NET
cp -r dotnet/_template dotnet/agents/my-demo
cd dotnet/agents/my-demo && mv Template.csproj MyDemo.csproj && dotnet run
```
