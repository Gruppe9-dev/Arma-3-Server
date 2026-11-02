# Graphify quickstart (Windows)

Graphify is already installed on this workstation. Open a new PowerShell window
if `graphify` is not found. Run the following commands from the project root.

## Initialize a project

```powershell
Set-Location -LiteralPath 'F:\Path\To\Project'
graphify extract . --code-only
graphify cluster-only . --no-label
Invoke-Item -LiteralPath '.\graphify-out\graph.html'
```

This creates `graph.json`, `GRAPH_REPORT.md`, and `graph.html` in `graphify-out/`.
No API key is needed. Documents are skipped; AI community naming is disabled.

Add unwanted folders to a project-local `.graphifyignore`, for example:

```text
node_modules/
.venv/
dist/
build/
logs/
graphify-out/
```

Add `graphify-out/` to `.gitignore` to keep generated files local.

## Update after code changes

```powershell
graphify update .
```

Updates supported code, the report, and the HTML view. Reload the browser view.

## Watch for code changes automatically

Install watcher support once:

```powershell
python -m uv tool install --force "graphifyy[watch]==0.9.97"
```

Start it in the project root:

```powershell
graphify watch .
```

Keep the terminal open. Press **Ctrl+C** to stop.

## Make Codex use the graph

Append this to the project's existing `AGENTS.md`:

```text
For architecture and dependency questions, query graphify-out/graph.json
before broad source searches. Check graph freshness and verify relevant
source lines before editing.
```

## Arma and semantic analysis

`--code-only`, `update`, and `watch` do not perform semantic analysis of documents
or unsupported languages. Graphify 0.9.97 has no native SQF parser.

Our Arma index includes supplemental SQF, configuration, and script-dispatch
mappings. Standard CLI updates do not fully refresh these mappings.
`.build_index.py` only assembles existing extraction snapshots; it is not an
updater. See [the local index notes](../graphify-out/INDEX_NOTES.md) for the
supplemental refresh workflow.
