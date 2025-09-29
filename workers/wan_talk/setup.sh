#!/usr/bin/env bash
set -euo pipefail

echo "[wan_talk] Starting setup..."

# Install system dependencies
if ! command -v aria2c >/dev/null 2>&1; then
  echo "[wan_talk] Installing aria2..."
  apt-get update
  apt-get install -y --no-install-recommends aria2
fi

# Install libmagic for ComfyUI API Wrapper
if ! dpkg -l | grep -q libmagic1; then
  echo "[wan_talk] Installing libmagic1..."
  apt-get update
  apt-get install -y --no-install-recommends libmagic1
fi

# Set up directories
WORKSPACE_DIR="${WORKSPACE_DIR:-/workspace}"
COMFY_ROOT="$WORKSPACE_DIR/ComfyUI"
API_WRAPPER_DIR="$WORKSPACE_DIR/comfyui-api-wrapper"

# Install ComfyUI using comfy-cli
if [[ ! -d "$COMFY_ROOT" ]]; then
  echo "[wan_talk] Installing ComfyUI..."
  cd "$WORKSPACE_DIR"
  
  # Install comfy-cli if not present
  if ! command -v comfy >/dev/null 2>&1; then
    pip install comfy-cli
  fi
  
  # Install ComfyUI
  comfy --skip-prompt install --nvidia
  
  echo "[wan_talk] ComfyUI installed to $COMFY_ROOT"
else
  echo "[wan_talk] ComfyUI already installed at $COMFY_ROOT"
fi

# Install ComfyUI API Wrapper
if [[ ! -d "$API_WRAPPER_DIR" ]]; then
  echo "[wan_talk] Installing ComfyUI API Wrapper..."
  cd "$WORKSPACE_DIR"
  git clone https://github.com/ai-dock/comfyui-api-wrapper.git
  cd "$API_WRAPPER_DIR"
  pip install -r requirements.txt
  echo "[wan_talk] API Wrapper installed"
else
  echo "[wan_talk] API Wrapper already installed at $API_WRAPPER_DIR"
fi

# Install custom nodes
CUSTOM_NODE_DIR="$COMFY_ROOT/custom_nodes"
mkdir -p "$CUSTOM_NODE_DIR"

clone_node() {
  local repo_url="$1"
  local node_name="$(basename "$repo_url" .git)"
  local clone_dir="$CUSTOM_NODE_DIR/$node_name"
  
  if [[ -d "$clone_dir" ]]; then
    echo "[wan_talk] Custom node already exists: $node_name"
    return
  fi
  
  echo "[wan_talk] Cloning $node_name..."
  git clone --depth 1 "$repo_url" "$clone_dir"
  
  # Install node dependencies if requirements.txt exists
  if [[ -f "$clone_dir/requirements.txt" ]]; then
    echo "[wan_talk] Installing dependencies for $node_name..."
    pip install -r "$clone_dir/requirements.txt"
  fi
}

# Required custom nodes for Wan Talk
REQUIRED_NODES=(
  "https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite"
  "https://github.com/christian-byrne/audio-separation-nodes-comfyui"
  "https://github.com/kijai/ComfyUI-WanVideoWrapper"
  "https://github.com/kijai/ComfyUI-KJNodes.git"
)

for repo in "${REQUIRED_NODES[@]}"; do
  clone_node "$repo"
done

# Create input directories for assets
mkdir -p "$COMFY_ROOT/input/wan_talk/audio"
mkdir -p "$COMFY_ROOT/input/wan_talk/images"

echo "[wan_talk] Setup complete!"