#!/usr/bin/env bash
set -euo pipefail

: "${SERVER_DIR:?SERVER_DIR must be set}"
: "${COMFY_WORKSPACE:?COMFY_WORKSPACE must be set}"
: "${COMFY_LAUNCH_EXTRAS:?COMFY_LAUNCH_EXTRAS must be set}"

hash -r

# --- Проверяем Python и pip ---
if ! command -v python3 >/dev/null 2>&1; then
    echo "[wan_talk/setup] Installing python3"
    apt-get update
    apt-get install -y python3 python3-venv python3-pip
fi

if ! python3 -m pip >/dev/null 2>&1; then
    echo "[wan_talk/setup] Installing pip for python3"
    apt-get update
    apt-get install -y python3-pip
fi

# Обновляем pip/setuptools/wheel
python3 -m pip install --upgrade pip setuptools wheel

# --- Устанавливаем aria2 ---
if ! command -v aria2c >/dev/null 2>&1; then
  echo "[wan_talk/setup] installing apt packages: aria2"
  apt-get update
  apt-get install -y --no-install-recommends aria2
  apt-get clean
fi

COMFY_ROOT="${COMFY_ROOT:-${COMFY_WORKSPACE}/ComfyUI}"
CUSTOM_NODE_DIR="$COMFY_ROOT/custom_nodes"

echo "[wan_talk/setup] Preparing ComfyUI workspace at ${COMFY_WORKSPACE}"
mkdir -p "$(dirname "$COMFY_WORKSPACE")"

# --- Создаём виртуальное окружение ---
ENV_PATH="${WORKSPACE_DIR:-/workspace}/worker-env"
if [ ! -d "$ENV_PATH" ]; then
    echo "[wan_talk/setup] Creating virtual environment at $ENV_PATH"
    python3 -m venv "$ENV_PATH"
fi

source "$ENV_PATH/bin/activate"
python -m pip install --upgrade pip setuptools wheel

# --- Удаляем старый workspace ComfyUI, если он есть ---
if [ -d "$COMFY_WORKSPACE" ]; then
    echo "[wan_talk/setup] Removing existing ComfyUI workspace at $COMFY_WORKSPACE"
    rm -rf "$COMFY_WORKSPACE"
fi

echo "[wan_talk/setup] Installing ComfyUI into ${COMFY_WORKSPACE}"

# GPU выбор (по умолчанию nvidia)
GPU_CHOICE="${WAN_GPU_CHOICE:-nvidia}"

case "$GPU_CHOICE" in
    nvidia) GPU_FLAG="--nvidia" ;;
    amd)    GPU_FLAG="--amd" ;;
    cpu)    GPU_FLAG="--cpu" ;;
    *)
      echo "[wan_talk/setup] Unknown GPU choice: $GPU_CHOICE"
      exit 1
      ;;
esac

# Non-interactive установка ComfyUI
comfy --skip-prompt --no-enable-telemetry \
      --workspace="$COMFY_WORKSPACE" \
      install $GPU_FLAG

# --- Установка Python зависимостей ---
COMFY_REQUIREMENTS="$COMFY_ROOT/requirements.txt"
if [ -f "$COMFY_REQUIREMENTS" ]; then
  echo "[wan_talk/setup] Installing ComfyUI Python dependencies"
  python -m pip install --no-cache-dir -r "$COMFY_REQUIREMENTS"
fi

WAN_TALK_REQUIREMENTS="$SERVER_DIR/workers/wan_talk/requirements-comfy.txt"
if [ -f "$WAN_TALK_REQUIREMENTS" ]; then
  echo "[wan_talk/setup] Installing additional WanTalk dependencies"
  python -m pip install --no-cache-dir -r "$WAN_TALK_REQUIREMENTS"
fi

# --- Клонирование кастомных нод ---
clone_node() {
  local repo_url="$1"
  local repo_name
  repo_name="$(basename "$repo_url" .git)"
  local clone_dir="$CUSTOM_NODE_DIR/$repo_name"
  if [[ -d "$clone_dir" ]]; then
    echo "[wan_talk/setup] custom node already cloned: $clone_dir"
    return
  fi
  echo "[wan_talk/setup] cloning $repo_url"
  git clone --depth 1 "$repo_url" "$clone_dir"
}

CUSTOM_NODES_DEFAULT=(
  "https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite"
  "https://github.com/christian-byrne/audio-separation-nodes-comfyui"
  "https://github.com/kijai/ComfyUI-WanVideoWrapper"
  "https://github.com/kijai/ComfyUI-KJNodes.git"
)

if [[ -n "${WAN_CUSTOM_NODES:-}" ]]; then
  IFS=' ' read -r -a CUSTOM_NODE_LIST <<< "$WAN_CUSTOM_NODES"
else
  CUSTOM_NODE_LIST=("${CUSTOM_NODES_DEFAULT[@]}")
fi

mkdir -p "$CUSTOM_NODE_DIR"
for repo in "${CUSTOM_NODE_LIST[@]}"; do
  clone_node "$repo"
done

# --- Отключение трекинга и установка дефолтного workspace ---
echo "[wan_talk/setup] Disabling comfy CLI tracking"
comfy tracking disable || true

echo "[wan_talk/setup] Setting comfy-cli default workspace"
comfy set-default "$COMFY_WORKSPACE" --launch-extras="$COMFY_LAUNCH_EXTRAS"
