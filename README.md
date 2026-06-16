# LR_INSTALLER

One-command installer for a self-contained **LightRAG** GraphRAG server backed by local **Ollama** models. It creates an isolated Python environment, pulls the required models, writes a ready-to-run `.env`, and (optionally) launches the server.

## What it does

`install.sh`:

1. **Checks prerequisites** — `curl`, `uv`, and `Ollama`. For each, it explains *why LightRAG needs it* and, with `--install-deps`, offers to install it (prompting before each, using `sudo` only where required).
2. **Pulls the Ollama models**:
   - `bge-m3:latest` — embeddings (vectorises text for retrieval).
   - `granite4.1:3b` — LLM (entity/relation extraction + answer generation).
3. **Installs LightRAG** (`lightrag-hku[api]`) into a local `./.venv` via `uv`.
4. **Generates `.env`** tuned for a local single-GPU Ollama deployment (timeouts, concurrency, file-based graph + vector storage).
5. **Prepares directories** — `./Data` (drop documents here) and `./rag_storage` (knowledge graph + vector store).
6. Optionally **starts the server** on port `9621`.

## Requirements

- Linux (Ubuntu tested). Uses `apt-get` to install `curl` when `--install-deps` is given.
- Internet access (to pull models and Python packages).
- A GPU is recommended but not required.

## Quick start

Clone, then run the easiest full install (installs any missing deps, pulls models, writes `.env`, and launches the server):

```bash
git clone https://github.com/jimccadm/LR_INSTALLER.git
cd LR_INSTALLER
chmod +x install.sh
./install.sh --install-deps --yes --start
