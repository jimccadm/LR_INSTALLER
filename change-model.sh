#!/usr/bin/env bash
# Change the Ollama model used by LightRAG, chosen from your locally installed
# models, and update .env accordingly. Defaults to the LLM; use --embedding to
# change the embedding model (guarded, since it invalidates an existing index).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

OLLAMA_HOST="${OLLAMA_HOST:-http://localhost:11434}"
ENV_FILE="${ENV_FILE:-.env}"
VENV_DIR="${VENV_DIR:-.venv}"
TARGET_KEY="LLM_MODEL"
MODEL_ARG=""
DO_RESTART=0

log()  { printf '\033[1;34m[model]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; }
die()  { err "$*"; exit 1; }
ask()  { printf '\033[1;36m[?]\033[0m %s' "$*"; }

usage() {
  cat <<'EOF'
Usage: ./change-model.sh [model] [options]

Pick an Ollama model (from the ones installed locally) and write it into .env.

Arguments:
  model            Model name to set (e.g. granite4.1:3b). If omitted, you get
                   an interactive menu of locally installed models.

Options:
  --embedding      Change EMBEDDING_MODEL instead of LLM_MODEL (asks to confirm;
                   changing it after indexing breaks retrieval — see warning).
  --restart        Restart the LightRAG server after updating .env.
  -h, --help       Show this help.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --embedding) TARGET_KEY="EMBEDDING_MODEL" ;;
    --restart) DO_RESTART=1 ;;
    -h|--help) usage; exit 0 ;;
    -*) die "Unknown option: $1 (use --help)" ;;
    *) [[ -z "$MODEL_ARG" ]] || die "Only one model may be given."; MODEL_ARG="$1" ;;
  esac
  shift
done

[[ -f "$ENV_FILE" ]] || die "$ENV_FILE not found. Run ./install.sh first."
command -v ollama >/dev/null 2>&1 || die "ollama CLI not found on PATH."
curl -fsS "${OLLAMA_HOST%/}/api/version" >/dev/null 2>&1 \
  || die "Ollama is not reachable at $OLLAMA_HOST. Start it with: ollama serve"

get_env() { grep -E "^$1=" "$ENV_FILE" 2>/dev/null | head -1 | cut -d= -f2-; }

set_env() {
  local key="$1" val="$2"
  if grep -qE "^${key}=" "$ENV_FILE"; then
    awk -v k="$key" -v v="$val" '$0 ~ "^"k"=" {print k"="v; next} {print}' \
      "$ENV_FILE" > "$ENV_FILE.tmp" && mv "$ENV_FILE.tmp" "$ENV_FILE"
  else
    printf '%s=%s\n' "$key" "$val" >> "$ENV_FILE"
  fi
}

model_installed() {
  local want="$1"; [[ "$want" == *:* ]] || want="${want}:latest"
  ollama list 2>/dev/null | awk 'NR>1{print $1}' | grep -qx "$want"
}

# Collect installed models (name + size) for the menu.
mapfile -t MODELS  < <(ollama list 2>/dev/null | awk 'NR>1 && NF{print $1}')
mapfile -t SIZES   < <(ollama list 2>/dev/null | awk 'NR>1 && NF{print $3" "$4}')
[[ "${#MODELS[@]}" -gt 0 ]] || die "No Ollama models installed. Pull one, e.g.: ollama pull granite4.1:3b"

CURRENT="$(get_env "$TARGET_KEY")"
log "Current $TARGET_KEY = ${CURRENT:-<unset>}"

# Resolve the chosen model: from argument, or via interactive menu.
choice=""
if [[ -n "$MODEL_ARG" ]]; then
  model_installed "$MODEL_ARG" || die "'$MODEL_ARG' is not installed. Run ./change-model.sh with no argument to pick from the list."
  choice="$MODEL_ARG"
else
  echo "Locally installed Ollama models:"
  for i in "${!MODELS[@]}"; do
    printf "  %2d) %-28s %s\n" "$((i+1))" "${MODELS[$i]}" "${SIZES[$i]:-}"
  done
  read -r -p "$(ask "Select model for $TARGET_KEY [1-${#MODELS[@]}]: ")" n
  [[ "$n" =~ ^[0-9]+$ ]] && (( n>=1 && n<=${#MODELS[@]} )) || die "Invalid selection: $n"
  choice="${MODELS[$((n-1))]}"
fi

if [[ "$choice" == "$CURRENT" ]]; then
  log "$TARGET_KEY is already set to '$choice'. Nothing to do."
  exit 0
fi

# Embedding changes invalidate any existing index — confirm before proceeding.
if [[ "$TARGET_KEY" == "EMBEDDING_MODEL" ]]; then
  warn "Changing the embedding model invalidates any documents already indexed."
  warn "After this you should wipe '$(get_env WORKING_DIR)' and re-ingest, and set"
  warn "EMBEDDING_DIM to match the new model's output dimension."
  read -r -p "$(ask "Proceed with embedding change? [y/N] ")" ans
  [[ "$ans" == [Yy] || "$ans" == [Yy][Ee][Ss] ]] || die "Aborted; .env unchanged."
fi

set_env "$TARGET_KEY" "$choice"
log "Updated $TARGET_KEY: '${CURRENT:-<unset>}' -> '$choice'"

if [[ "$DO_RESTART" -eq 1 ]]; then
  PORT="$(get_env PORT)"; PORT="${PORT:-9621}"
  [[ -x "$VENV_DIR/bin/lightrag-server" ]] || die "Cannot restart: $VENV_DIR/bin/lightrag-server not found."
  log "Restarting LightRAG server…"
  pkill -f lightrag-server 2>/dev/null || true; sleep 2
  setsid "$VENV_DIR/bin/lightrag-server" > server.log 2>&1 < /dev/null &
  for _ in $(seq 1 20); do
    curl -fsS "http://localhost:${PORT}/health" >/dev/null 2>&1 && { log "Server healthy on port ${PORT}."; break; }
    sleep 1
  done
else
  warn "Restart the LightRAG server for the change to take effect (or re-run with --restart)."
fi
