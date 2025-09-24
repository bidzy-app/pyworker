#!/usr/bin/env bash
set -euo pipefail

if ! command -v aria2c >/dev/null 2>&1; then
  echo "[wan_talk] installing aria2"
  apt-get update
  apt-get install -y --no-install-recommends aria2
fi

COMFY_ROOT="${COMFY_ROOT:-/workspace/ComfyUI}"
CUSTOM_NODE_DIR="$COMFY_ROOT/custom_nodes"

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