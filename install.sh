#!/usr/bin/env bash
# LightRAG local installer — sets up a self-contained LightRAG server backed by
# local Ollama models (LLM + embedding), generates a working .env, and prepares
# the Data/ folder for indexing. Safe to re-run.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# ---- Configuration (override via environment) -------------------------------
OLLAMA_HOST="${OLLAMA_HOST:-http://localhost:11434}"
LLM_MODEL="${LLM_MODEL:-granite4.1:3b}"
LLM_NUM_CTX="${LLM_NUM_CTX:-32768}"
EMBED_MODEL="${EMBED_MODEL:-bge-m3:latest}"
EMBED_DIM="${EMBED_DIM:-1024}"
EMBED_NUM_CTX="${EMBED_NUM_CTX:-8192}"
SERVER_PORT="${SERVER_PORT:-9621}"
INPUT_DIR="${INPUT_DIR:-./Data}"
WORKING_DIR="${WORKING_DIR:-./rag_storage}"
VENV_DIR="${VENV_DIR:-.venv}"

START_AFTER=0
SKIP_MODELS=0
SKIP_INSTALL=0
FORCE_ENV=0
INSTALL_DEPS=0
ASSUME_YES=0

# ---- Helpers ----------------------------------------------------------------
log()  { printf '\033[1;34m[install]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; }
die()  { err "$*"; exit 1; }
ask()  { printf '\033[1;36m[?]\033[0m %s' "$*"; }

# Prompt for yes/no. Honours --yes; refuses to guess in a non-interactive shell.
confirm() {
  [[ "$ASSUME_YES" -eq 1 ]] && return 0
  if [[ ! -t 0 ]]; then
    warn "Non-interactive shell; cannot prompt. Re-run with --yes to auto-confirm."
    return 1
  fi
  local ans; read -r -p "$(ask "$1 [y/N] ")" ans
  [[ "$ans" == [Yy] || "$ans" == [Yy][Ee][Ss] ]]
}

# Installers for the three host prerequisites (used only with --install-deps).
install_curl() {
  command -v apt-get >/dev/null 2>&1 \
    || die "No apt-get on this system. Install 'curl' with your package manager, then re-run."
  log "Installing curl via apt-get (sudo will prompt for your password)…"
  sudo apt-get update && sudo apt-get install -y curl
}
install_uv() {
  log "Installing uv (user-level, no sudo needed)…"
  curl -LsSf https://astral.sh/uv/install.sh | sh
  # uv lands in ~/.local/bin; make it usable for the rest of this run.
  [[ -f "$HOME/.local/bin/env" ]] && . "$HOME/.local/bin/env" || true
  export PATH="$HOME/.local/bin:$PATH"
}
install_ollama() {
  log "Installing Ollama via the official script (sudo will prompt for your password)…"
  curl -fsSL https://ollama.com/install.sh | sh
}

# require <cmd> <why-needed> <installer-fn> <manual-hint>
# Explains why the dependency matters; offers to install it under --install-deps.
require() {
  local cmd="$1" why="$2" installer="$3" hint="$4"
  command -v "$cmd" >/dev/null 2>&1 && return 0
  warn "Required dependency '$cmd' is not installed."
  printf '      Why LightRAG needs it: %s\n' "$why"
  if [[ "$INSTALL_DEPS" -eq 1 ]] && confirm "Install '$cmd' now?"; then
    "$installer"
    command -v "$cmd" >/dev/null 2>&1 \
      || die "'$cmd' still not found after the install attempt. $hint"
    log "'$cmd' is now installed."
  else
    die "Cannot continue without '$cmd'. $hint
   Tip: re-run with --install-deps to have this script install it for you."
  fi
}

usage() {
  cat <<'EOF'
Usage: ./install.sh [options]

Installs a local LightRAG server (lightrag-hku[api]) into ./.venv, pulls the
required Ollama models, and writes a ready-to-run .env for a local deployment.

Options:
  --install-deps   Offer to install any missing prerequisites (curl, uv,
                   Ollama). You confirm before each install; sudo is used only
                   where required (curl + Ollama). Add --yes for unattended.
  -y, --yes        Assume "yes" to all prompts (non-interactive installs).
  --start          Launch the LightRAG server when installation completes.
  --skip-models    Do not pull Ollama models (assume they already exist).
  --skip-install   Do not (re)install the Python package.
  --force-env      Overwrite an existing .env file.
  -h, --help       Show this help.

Configuration via environment variables (with defaults):
  LLM_MODEL=granite4.1:3b         EMBED_MODEL=bge-m3:latest   EMBED_DIM=1024
  OLLAMA_HOST=http://localhost:11434   SERVER_PORT=9621
  INPUT_DIR=./Data   WORKING_DIR=./rag_storage
EOF
}

# ---- Argument parsing -------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --install-deps) INSTALL_DEPS=1 ;;
    -y|--yes) ASSUME_YES=1 ;;
    --start) START_AFTER=1 ;;
    --skip-models) SKIP_MODELS=1 ;;
    --skip-install) SKIP_INSTALL=1 ;;
    --force-env) FORCE_ENV=1 ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1 (use --help)" ;;
  esac
  shift
done

# ---- Prerequisite checks ----------------------------------------------------
# Each dependency is explained; with --install-deps the script offers to install
# it (you confirm first). Order matters: curl bootstraps the uv/Ollama installers.
require curl \
  "the installer uses curl to probe the Ollama API and to download the uv and Ollama installers" \
  install_curl \
  "Install it: sudo apt-get update && sudo apt-get install -y curl"

require uv \
  "uv builds the isolated Python environment and installs lightrag-hku[api]; without it LightRAG cannot be installed or launched" \
  install_uv \
  "Install it: curl -LsSf https://astral.sh/uv/install.sh | sh (then re-open your shell)"

# Determine whether Ollama is expected on this machine (vs a remote OLLAMA_HOST).
OLLAMA_IS_LOCAL=0
case "$OLLAMA_HOST" in *localhost*|*127.0.0.1*|*0.0.0.0*) OLLAMA_IS_LOCAL=1 ;; esac

if [[ "$OLLAMA_IS_LOCAL" -eq 1 ]]; then
  require ollama \
    "Ollama serves the local LLM (${LLM_MODEL}) and embedding model (${EMBED_MODEL}); LightRAG routes every extraction, embedding and query call to it, so without Ollama ingestion and all queries fail" \
    install_ollama \
    "Install it: curl -fsSL https://ollama.com/install.sh | sh"
fi

# Make sure the Ollama API is actually answering; offer to start it if local.
if ! curl -fsS "${OLLAMA_HOST%/}/api/version" >/dev/null 2>&1; then
  if [[ "$OLLAMA_IS_LOCAL" -eq 1 ]] && command -v ollama >/dev/null 2>&1 \
     && { [[ "$INSTALL_DEPS" -eq 1 ]] || confirm "Ollama isn't responding. Start 'ollama serve' now?"; }; then
    log "Starting 'ollama serve' in the background…"
    nohup ollama serve >/tmp/ollama-serve.log 2>&1 &
    for _ in $(seq 1 20); do
      curl -fsS "${OLLAMA_HOST%/}/api/version" >/dev/null 2>&1 && break
      sleep 1
    done
  fi
fi
if ! curl -fsS "${OLLAMA_HOST%/}/api/version" >/dev/null 2>&1; then
  die "Ollama is not reachable at $OLLAMA_HOST.
   Why LightRAG needs it: every extraction, embedding and query request goes to
   Ollama — without it, ingestion and all queries fail.
   - Start it with: ollama serve   (or check its systemd service)"
fi
log "Ollama reachable at $OLLAMA_HOST"

# ---- Pull required models ---------------------------------------------------
have_model() {
  local want="$1"; [[ "$want" == *:* ]] || want="${want}:latest"
  ollama list 2>/dev/null | awk 'NR>1{print $1}' | grep -qx "$want"
}

pull_model() {
  local m="$1"
  if have_model "$m"; then
    log "Model already present: $m"
  else
    log "Pulling model: $m"
    ollama pull "$m"
  fi
}

if [[ "$SKIP_MODELS" -eq 0 ]]; then
  command -v ollama >/dev/null 2>&1 \
    || die "ollama CLI not found; cannot pull models. Re-run with --install-deps, or use --skip-models if they already exist on a remote OLLAMA_HOST."
  log "Pulling models — '${EMBED_MODEL}' vectorises text for retrieval; '${LLM_MODEL}' does entity extraction + answer generation. LightRAG needs both."
  pull_model "$EMBED_MODEL"
  pull_model "$LLM_MODEL"
else
  log "Skipping model pulls (--skip-models)"
fi

# ---- Install LightRAG -------------------------------------------------------
if [[ "$SKIP_INSTALL" -eq 0 ]]; then
  log "Creating virtual environment in $VENV_DIR"
  uv venv "$VENV_DIR"
  log "Installing lightrag-hku[api] + ollama client (this may take a few minutes)"
  uv pip install --python "$VENV_DIR/bin/python" "lightrag-hku[api]" ollama
else
  log "Skipping Python package install (--skip-install)"
fi

# ---- Prepare directories ----------------------------------------------------
mkdir -p "$INPUT_DIR" "$WORKING_DIR"

# ---- Generate .env ----------------------------------------------------------
if [[ -f .env && "$FORCE_ENV" -eq 0 ]]; then
  warn ".env already exists; leaving it untouched (use --force-env to overwrite)"
else
  log "Writing .env for local Ollama deployment"
  cat > .env <<EOF
### LightRAG configuration — generated by install.sh (local Ollama deployment)

### Server
# HOST=0.0.0.0 listens on all interfaces. On a shared/public network, set a key
# below (LIGHTRAG_API_KEY) or bind to 127.0.0.1 to avoid exposing the API.
HOST=0.0.0.0
PORT=${SERVER_PORT}
WEBUI_TITLE='DiffGem KB'
WEBUI_DESCRIPTION='Local graph-based RAG over your Data folder'

### Directories
INPUT_DIR=${INPUT_DIR}
WORKING_DIR=${WORKING_DIR}

### Query / extraction behaviour
ENABLE_LLM_CACHE=false
ENTITY_EXTRACTION_USE_JSON=true
SUMMARY_LANGUAGE=English
MAX_TOTAL_TOKENS=30000

### LLM (Ollama)
LLM_BINDING=ollama
LLM_BINDING_HOST=${OLLAMA_HOST}
LLM_MODEL=${LLM_MODEL}
OLLAMA_LLM_NUM_CTX=${LLM_NUM_CTX}
# Local single-GPU tuning: keep LLM concurrency low so parallel extraction calls
# don't starve each other, with a generous per-call timeout for long extractions.
MAX_ASYNC_LLM=2
MAX_PARALLEL_INSERT=1
LLM_TIMEOUT=600
TIMEOUT=1200

### Embedding (Ollama) — MUST NOT change after the first document is indexed
EMBEDDING_BINDING=ollama
EMBEDDING_BINDING_HOST=${OLLAMA_HOST}
EMBEDDING_MODEL=${EMBED_MODEL}
EMBEDDING_DIM=${EMBED_DIM}
OLLAMA_EMBEDDING_NUM_CTX=${EMBED_NUM_CTX}
EMBEDDING_BATCH_NUM=32

### Storage (file-persisted local defaults — good for single-machine use)
LIGHTRAG_KV_STORAGE=JsonKVStorage
LIGHTRAG_DOC_STATUS_STORAGE=JsonDocStatusStorage
LIGHTRAG_GRAPH_STORAGE=NetworkXStorage
LIGHTRAG_VECTOR_STORAGE=NanoVectorDBStorage

### Reranking (none by default; set RERANK_BINDING to enable)
RERANK_BINDING=null
EOF
fi

# ---- Done -------------------------------------------------------------------
log "Installation complete."
cat <<EOF

Next steps:
  Start the server:   ${VENV_DIR}/bin/lightrag-server
  Then open:          http://localhost:${SERVER_PORT}

Documents in '${INPUT_DIR}' (e.g. Data/ps.txt) are indexed into a knowledge
graph + vector store under '${WORKING_DIR}'.
EOF

if [[ "$START_AFTER" -eq 1 ]]; then
  log "Launching LightRAG server (Ctrl-C to stop)"
  exec "$VENV_DIR/bin/lightrag-server"
fi
