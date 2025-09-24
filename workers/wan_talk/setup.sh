#!/usr/bin/env bash
set -euo pipefail

if ! command -v aria2c >/dev/null 2>&1; then
  echo "[wan_talk] installing aria2"
  apt-get update
  apt-get install -y --no-install-recommends aria2
fi

COMFY_ROOT="${COMFY_ROOT:-/workspace/ComfyUI}"
CUSTOM_NODE_DIR="$COMFY_ROOT/custom_nodes"

DIFFUSION_DIR="$COMFY_ROOT/models/diffusion_models"
CHECKPOINT_DIR="$COMFY_ROOT/models/checkpoints"
VAE_DIR="$COMFY_ROOT/models/vae"
TEXT_ENCODER_DIR="$COMFY_ROOT/models/text_encoders"
CLIP_VISION_DIR="$COMFY_ROOT/models/clip_vision"
LORA_DIR="$COMFY_ROOT/models/loras"

download() {
  local url="$1"
  local target="$2"
  if [[ -f "$target" ]]; then
    echo "[wan_talk] already present: $target"
    return
  fi
  mkdir -p "$(dirname "$target")"
  echo "[wan_talk] downloading $(basename "$target")"
  aria2c --disable-ipv6=true --allow-overwrite=true -x 8 -s 8 -k 1M \
    -d "$(dirname "$target")" -o "$(basename "$target")" "$url"
}

clone_node() {
  local repo_url="$1"
  local clone_dir="$CUSTOM_NODE_DIR/$(basename "$repo_url" .git)"
  if [[ -d "$clone_dir" ]]; then
    echo "[wan_talk] custom node already cloned: $clone_dir"
    return
  fi
  echo "[wan_talk] cloning $repo_url"
  git clone --depth 1 "$repo_url" "$clone_dir"
}

install_python_packages() {
  # если PIP явно не задан, берём тот, что находится в PATH (для worker-env)
  local PIP_BIN="${PIP:-$(command -v pip)}"
  echo "[wan_talk] installing python dependencies with ${PIP_BIN}"

  "$PIP_BIN" install --upgrade --no-cache-dir \
    pillow \
    scipy \
    packaging librosa "numpy==1.26.4" moviepy \
    color-matcher matplotlib huggingface_hub mss opencv-python ftfy \
    "accelerate>=1.2.1" einops "diffusers>=0.33.0" "peft>=0.17.0" \
    "sentencepiece>=0.2.0" protobuf pyloudnorm "gguf>=0.14.0" imageio-ffmpeg \
    av comfy-cli sageattention
}

DIFFUSION_MODEL_1="${WAN_DIFFUSION_URL_1:-https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/InfiniteTalk/Wan2_1-InfiniTetalk-Single_fp16.safetensors?download=true}"
DIFFUSION_MODEL_2="${WAN_DIFFUSION_URL_2:-https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/Wan2_1-I2V-14B-480P_fp8_e4m3fn.safetensors}"
VAE_MODEL_URL="${WAN_VAE_URL_1:-https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/Wan2_1_VAE_bf16.safetensors}"
TEXT_ENCODER_URL="${WAN_TEXT_ENCODER_URL_1:-https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/umt5-xxl-enc-fp8_e4m3fn.safetensors}"
CLIP_VISION_URL="${WAN_CLIP_VISION_URL_1:-https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/clip_vision/clip_vision_h.safetensors}"
LORA_URL="${WAN_LORA_URL_1:-https://huggingface.co/lightx2v/Wan2.1-I2V-14B-480P-StepDistill-CfgDistill-Lightx2v/resolve/main/loras/Wan21_I2V_14B_lightx2v_cfg_step_distill_lora_rank64.safetensors}"

CUSTOM_NODES_DEFAULT=(
  "https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite"
  "https://github.com/christian-byrne/audio-separation-nodes-comfyui"
  "https://github.com/kijai/ComfyUI-WanVideoWrapper"
  "https://github.com/kijai/ComfyUI-KJNodes.git"
)

download "$DIFFUSION_MODEL_1" "$DIFFUSION_DIR/$(basename "${DIFFUSION_MODEL_1%%\?*}")"
download "$DIFFUSION_MODEL_2" "$DIFFUSION_DIR/$(basename "${DIFFUSION_MODEL_2%%\?*}")"
download "$DIFFUSION_MODEL_1" "$CHECKPOINT_DIR/$(basename "${DIFFUSION_MODEL_1%%\?*}")"
download "$DIFFUSION_MODEL_2" "$CHECKPOINT_DIR/$(basename "${DIFFUSION_MODEL_2%%\?*}")"
download "$VAE_MODEL_URL" "$VAE_DIR/$(basename "${VAE_MODEL_URL%%\?*}")"
download "$TEXT_ENCODER_URL" "$TEXT_ENCODER_DIR/$(basename "${TEXT_ENCODER_URL%%\?*}")"
download "$CLIP_VISION_URL" "$CLIP_VISION_DIR/$(basename "${CLIP_VISION_URL%%\?*}")"
download "$LORA_URL" "$LORA_DIR/$(basename "${LORA_URL%%\?*}")"

if [[ -n "${WAN_CUSTOM_NODES:-}" ]]; then
  IFS=' ' read -r -a CUSTOM_NODE_LIST <<< "$WAN_CUSTOM_NODES"
else
  CUSTOM_NODE_LIST=("${CUSTOM_NODES_DEFAULT[@]}")
fi

mkdir -p "$CUSTOM_NODE_DIR"
for repo in "${CUSTOM_NODE_LIST[@]}"; do
  clone_node "$repo"
done

install_python_packages