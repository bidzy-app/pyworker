#!/usr/bin/env bash
set -Eeuo pipefail

# --- базовые пути/логи ---
WORKSPACE_DIR="${WORKSPACE_DIR:-${WORKSPACE:-/workspace}}"
SERVER_DIR="${SERVER_DIR:-$WORKSPACE_DIR/vast-pyworker}"
ENV_PATH="${ENV_PATH:-$WORKSPACE_DIR/worker-env}"
DEBUG_LOG="${DEBUG_LOG:-$WORKSPACE_DIR/debug.log}"
PYWORKER_LOG="${PYWORKER_LOG:-$WORKSPACE_DIR/pyworker.log}"

# --- конфигурация воркера ---
REPORT_ADDR="${REPORT_ADDR:-https://cloud.vast.ai/api/v0,https://run.vast.ai}"
USE_SSL="${USE_SSL:-false}"
WORKER_PORT="${WORKER_PORT:-3000}"

# --- обязательные/необязательные переменные окружения ---
: "${BACKEND:?BACKEND must be set (e.g. comfyui-json)}"
PY_BACKEND="${BACKEND//-/_}"   # comfyui-json -> comfyui_json

MODEL_LOG="${MODEL_LOG:-/var/log/logtail.log}"
HF_TOKEN="${HF_TOKEN:-}"       # для comfyui/comfyui-json не обязателен
if [[ "$BACKEND" != comfyui* && -z "$HF_TOKEN" ]]; then
  echo "HF_TOKEN must be set for BACKEND=$BACKEND"; exit 1
fi
if [[ "$BACKEND" == "comfyui" && -z "${COMFY_MODEL:-}" ]]; then
  echo "COMFY_MODEL must be set when BACKEND=comfyui"; exit 1
fi

mkdir -p "$WORKSPACE_DIR" "$(dirname "$MODEL_LOG")"
cd "$WORKSPACE_DIR"

# Логируем всё в debug.log и на stdout
exec &> >(tee -a "$DEBUG_LOG")

# Печать ключевых переменных (для диагностики)
for v in BACKEND PY_BACKEND REPORT_ADDR USE_SSL WORKER_PORT WORKSPACE_DIR SERVER_DIR ENV_PATH DEBUG_LOG PYWORKER_LOG MODEL_LOG MODEL_SERVER_URL COMFY_MODEL HF_TOKEN; do
  printf '%s: %q\n' "$v" "${!v-}"
done

# Сохраняем env в /etc/environment (в кавычках)
if ! grep -q '^BACKEND=' /etc/environment 2>/dev/null; then
  env -0 | awk -v RS='\0' '
    $0 !~ /^(HOME=|SHLVL=|TERM=|PWD=|_=?)/ {
      split($0,a,"="); key=a[1]; sub(/^[^=]*=/,"",$0); gsub(/"/,"\\\"", $0);
      print key "=\"" $0 "\""
    }' > /etc/environment
fi

# --- установка uv/venv и pyworker ---
if [[ ! -d "$ENV_PATH" ]]; then
  echo "Setting up venv at $ENV_PATH"
  if ! command -v uv >/dev/null 2>&1; then
    echo "Installing uv..."
    curl -LsSf https://astral.sh/uv/install.sh | sh
    [[ -f "$HOME/.local/bin/env" ]] && source "$HOME/.local/bin/env" || export PATH="$HOME/.local/bin:$PATH"
  fi

  [[ ! -d "$SERVER_DIR" ]] && git clone "${PYWORKER_REPO:-https://github.com/vast-ai/pyworker}" "$SERVER_DIR"
  if [[ -n "${PYWORKER_REF:-}" ]]; then
    git -C "$SERVER_DIR" checkout "$PYWORKER_REF"
  fi

  if uv venv --python-preference only-managed "$ENV_PATH" -p 3.10; then
    source "$ENV_PATH/bin/activate"
    uv pip install -r "$SERVER_DIR/requirements.txt"
  else
    echo "uv venv failed; falling back to python -m venv"
    python3 -m venv "$ENV_PATH"
    source "$ENV_PATH/bin/activate"
    pip install --upgrade pip
    pip install -r "$SERVER_DIR/requirements.txt"
  fi

  touch "$HOME/.no_auto_tmux"
else
  [[ -f "$HOME/.local/bin/env" ]] && source "$HOME/.local/bin/env" || true
  source "$ENV_PATH/bin/activate"
  echo "Environment activated: $VIRTUAL_ENV"
fi

# --- проверка бэкенда ---
if [[ ! -d "$SERVER_DIR/workers/$PY_BACKEND" ]]; then
  echo "Backend $BACKEND not supported (expected dir: $SERVER_DIR/workers/$PY_BACKEND)"
  exit 1
fi

# --- SSL (опционально) ---
if [[ "$USE_SSL" == "true" ]]; then
  cat > /etc/openssl-san.cnf <<'EOF'
[req]
default_bits       = 2048
distinguished_name = req_distinguished_name
req_extensions     = v3_req
prompt             = no
[req_distinguished_name]
C  = US
ST = CA
O  = Vast.ai Inc.
CN = vast.ai
[v3_req]
basicConstraints = CA:FALSE
keyUsage         = nonRepudiation, digitalSignature, keyEncipherment
subjectAltName   = @alt_names
[alt_names]
IP.1   = 0.0.0.0
EOF

  openssl req -newkey rsa:2048 -nodes -sha256 \
    -keyout /etc/instance.key \
    -out /etc/instance.csr \
    -config /etc/openssl-san.cnf

  if [[ -n "${CONTAINER_ID:-}" ]]; then
    curl -fsS --header 'Content-Type: application/octet-stream' \
      --data-binary @/etc/instance.csr \
      -X POST "https://console.vast.ai/api/v0/sign_cert/?instance_id=$CONTAINER_ID" \
      -o /etc/instance.crt || echo "Warn: failed to fetch signed cert"
  else
    echo "Warn: CONTAINER_ID not set; skipping cert signing"
  fi
fi

export REPORT_ADDR WORKER_PORT USE_SSL

#############################################
# WAN 2.1: автоустановка моделей/нод/пакетов
#############################################

COMFY_ROOT="${COMFY_ROOT:-/opt/ComfyUI}"
MODELS_BASE="${COMFYUI_MODELS_DIR:-/workspace/ComfyUI/models}"
CUSTOM_NODES_DIR="${COMFYUI_CUSTOM_NODES_DIR:-/workspace/ComfyUI/custom_nodes}"
mkdir -p "$MODELS_BASE"/{checkpoints,vae,text_encoders,clip_vision,loras} "$CUSTOM_NODES_DIR"

# Аккуратно подвязываем каталоги данных к ComfyUI (мигрируем содержимое если нужно)
ensure_link_dir() {
  # ensure_link_dir real_dir link_path
  local src="$1" dst="$2"
  mkdir -p "$src"
  if [[ -L "$dst" ]]; then
    ln -sfn "$src" "$dst"
  elif [[ -d "$dst" ]]; then
    # мигрируем содержимое и заменяем на ссылку
    echo "Migrating existing directory $dst -> $src"
    shopt -s dotglob || true
    cp -a "$dst"/* "$src"/ 2>/dev/null || true
    rm -rf "$dst"
    ln -s "$src" "$dst"
  else
    ln -s "$src" "$dst"
  fi
}
ensure_link_dir "$MODELS_BASE"      "$COMFY_ROOT/models"
ensure_link_dir "$CUSTOM_NODES_DIR" "$COMFY_ROOT/custom_nodes"

# Списки по умолчанию
DIFFUSION_MODELS_DEFAULT=(
  "https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/InfiniteTalk/Wan2_1-InfiniTetalk-Single_fp16.safetensors?download=true"
  "https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/Wan2_1-I2V-14B-480P_fp8_e4m3fn.safetensors"
)
VAE_MODELS_DEFAULT=(
  "https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/Wan2_1_VAE_bf16.safetensors"
)
TEXT_ENCODERS_DEFAULT=(
  "https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/umt5-xxl-enc-fp8_e4m3fn.safetensors"
)
CLIP_VISION_MODELS_DEFAULT=(
  "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/clip_vision/clip_vision_h.safetensors"
)
LORA_MODELS_DEFAULT=(
  "https://huggingface.co/lightx2v/Wan2.1-I2V-14B-480P-StepDistill-CfgDistill-Lightx2v/resolve/main/loras/Wan21_I2V_14B_lightx2v_cfg_step_distill_lora_rank64.safetensors"
)

CUSTOM_NODES_DEFAULT=(
  "https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite"
  "https://github.com/christian-byrne/audio-separation-nodes-comfyui"
  "https://github.com/kijai/ComfyUI-WanVideoWrapper"
  "https://github.com/kijai/ComfyUI-KJNodes.git"
)

# Переопределения через переменные окружения PREFIX_URL_N
collect_urls() {
  local prefix="$1"; shift
  local -n out_arr="$1"
  local found=0
  while IFS='=' read -r name value; do
    out_arr+=("$value"); found=1
  done < <(env | awk -F= -v pfx="${prefix}_URL_" '$1 ~ "^"pfx {print $0}' | sort -t_ -k3,3n)
  return $found
}

DIFFUSION_MODELS=(); collect_urls "DIFFUSION" DIFFUSION_MODELS || DIFFUSION_MODELS=("${DIFFUSION_MODELS_DEFAULT[@]}")
VAE_MODELS=();       collect_urls "VAE"       VAE_MODELS       || VAE_MODELS=("${VAE_MODELS_DEFAULT[@]}")
TEXT_ENCODERS=();    collect_urls "TEXT_ENCODERS" TEXT_ENCODERS || TEXT_ENCODERS=("${TEXT_ENCODERS_DEFAULT[@]}")
CLIP_VISION_MODELS=(); collect_urls "CLIP_VISION" CLIP_VISION_MODELS || CLIP_VISION_MODELS=("${CLIP_VISION_MODELS_DEFAULT[@]}")
LORA_MODELS=();      collect_urls "LORA"      LORA_MODELS      || LORA_MODELS=("${LORA_MODELS_DEFAULT[@]}")
CUSTOM_NODES=();     collect_urls "CUSTOM_NODE" CUSTOM_NODES    || CUSTOM_NODES=("${CUSTOM_NODES_DEFAULT[@]}")

# Скачивание с поддержкой HF токена и докачки
fetch() {
  local url="$1" dest="$2"
  local hdr=()
  [[ -n "${HF_TOKEN:-}" ]] && hdr=(-H "Authorization: Bearer ${HF_TOKEN}")
  echo "Downloading: $url -> $dest"
  if command -v aria2c >/dev/null 2>&1; then
    aria2c -x8 -s8 -k1M -d "$(dirname "$dest")" -o "$(basename "$dest")" "${hdr[@]/#/-H }" "$url" || return 1
  else
    curl -fL --retry 5 --retry-delay 2 --continue-at - "${hdr[@]}" -o "$dest" "$url" || return 1
  fi
}

install_models_list() {
  local subdir="$1"; shift
  local -a urls=("$@")
  local target="$MODELS_BASE/$subdir"
  mkdir -p "$target"
  for u in "${urls[@]}"; do
    local fname="$(basename "${u%%\?*}")"
    [[ -z "$fname" ]] && fname="$(date +%s).bin"
    [[ -e "$target/$fname" ]] && { echo "Skip (exists): $target/$fname"; continue; }
    fetch "$u" "$target/$fname" || echo "Warn: failed to download $u"
  done
}

echo "Installing WAN models into $MODELS_BASE ..."
install_models_list checkpoints   "${DIFFUSION_MODELS[@]}"
install_models_list vae           "${VAE_MODELS[@]}"
install_models_list text_encoders "${TEXT_ENCODERS[@]}"
install_models_list clip_vision   "${CLIP_VISION_MODELS[@]}"
install_models_list loras         "${LORA_MODELS[@]}"

# Кастом-ноды (git clone/pull)
echo "Installing custom nodes into $CUSTOM_NODES_DIR ..."
for repo in "${CUSTOM_NODES[@]}"; do
  name="$(basename "${repo%.git}")"
  dst="$CUSTOM_NODES_DIR/$name"
  if [[ -d "$dst/.git" ]]; then
    echo "Updating $name ..."
    git -C "$dst" pull --ff-only || true
  else
    echo "Cloning $name ..."
    git clone --depth 1 "$repo" "$dst" || true
  fi
done

# Установка requirements.txt для кастом-нод в окружение ComfyUI
COMFY_PIP="/opt/micromamba/envs/comfyui/bin/pip"
if [[ -x "$COMFY_PIP" ]]; then
  for d in "$CUSTOM_NODES_DIR"/*; do
    [[ -d "$d" && -f "$d/requirements.txt" ]] && { echo "pip install -r $d/requirements.txt"; "$COMFY_PIP" install --no-cache-dir -r "$d/requirements.txt" || true; }
  done
else
  echo "Warn: ComfyUI pip not found at $COMFY_PIP"
fi

# Дополнительные пакеты в окружение ComfyUI
install_python_packages() {
  local PIP="$COMFY_PIP"
  echo "Installing extra Python packages to ComfyUI env ..."
  "$PIP" install --upgrade --no-cache-dir \
    packaging librosa "numpy==1.26.4" moviepy "pillow>=10.3.0" scipy \
    color-matcher matplotlib huggingface_hub mss opencv-python ftfy \
    "accelerate>=1.2.1" einops "diffusers>=0.33.0" "peft>=0.17.0" \
    "sentencepiece>=0.2.0" protobuf pyloudnorm "gguf>=0.14.0" imageio-ffmpeg \
    av comfy-cli sageattention
}
[[ -x "$COMFY_PIP" ]] && install_python_packages || echo "Skip extras: pip unavailable"

echo "WAN autoinstall step finished."
#############################################

# --- очистка/инициализация лога модели ---
if [[ -e "$MODEL_LOG" ]]; then
  cat "$MODEL_LOG" >> "${MODEL_LOG}.old" || true
  : > "$MODEL_LOG"
else
  : > "$MODEL_LOG"
fi

echo "Launching PyWorker server for $BACKEND (module workers.${PY_BACKEND}.server) ..."

# Запуск сервера; если в модуле есть main(), вызываем её, иначе run_module
python3 - <<PY 2>&1 | tee -a "$PYWORKER_LOG" &
import importlib, sys, runpy
mod = importlib.import_module("workers.${PY_BACKEND}.server")
if hasattr(mod, "main"):
    sys.exit(mod.main())
runpy.run_module("workers.${PY_BACKEND}.server", run_name="__main__")
PY

echo "PyWorker started in background. Checking port ${WORKER_PORT} ..."
sleep 1
ss -ltpn 2>/dev/null | grep -E ":${WORKER_PORT}\b" || echo "Note: nothing is listening on port ${WORKER_PORT} yet (ok if server binds later)."

# Держим процесс на переднем плане для On-start
wait