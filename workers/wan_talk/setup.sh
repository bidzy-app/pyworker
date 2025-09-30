#!/usr/bin/env bash
set -euo pipefail

echo "[wan_talk] Starting setup..."

# Install system dependencies
echo "[wan_talk] Installing system dependencies..."
apt-get update
apt-get install -y --no-install-recommends \
    aria2 \
    libmagic1 \
    git \
    wget \
    ffmpeg \
    libsm6 \
    libxext6 \
    libgl1 \
    libglib2.0-0

# Set up directories
WORKSPACE_DIR="${WORKSPACE_DIR:-/workspace}"
COMFY_ROOT="$WORKSPACE_DIR/ComfyUI"
API_WRAPPER_DIR="$WORKSPACE_DIR/comfyui-api-wrapper"
ENV_PATH="$WORKSPACE_DIR/worker-env"

# ========================================
# КРИТИЧНО: Используем ЯВНЫЕ пути к venv
# ========================================
if [ ! -d "$ENV_PATH" ]; then
    echo "[wan_talk] ERROR: Virtual environment not found at $ENV_PATH"
    exit 1
fi

# Явные пути к исполняемым файлам venv
VENV_PYTHON="$ENV_PATH/bin/python3"
VENV_PIP="$ENV_PATH/bin/pip"

# Проверка существования
if [ ! -f "$VENV_PYTHON" ]; then
    echo "[wan_talk] ERROR: Python not found in venv: $VENV_PYTHON"
    exit 1
fi

if [ ! -f "$VENV_PIP" ]; then
    echo "[wan_talk] ERROR: Pip not found in venv: $VENV_PIP"
    exit 1
fi

# Диагностика
echo "=========================================="
echo "[wan_talk] Virtual environment info:"
echo "  ENV_PATH: $ENV_PATH"
echo "  VENV_PYTHON: $VENV_PYTHON"
echo "  VENV_PIP: $VENV_PIP"
echo "=========================================="

"$VENV_PYTHON" --version
"$VENV_PIP" --version

echo "[wan_talk] Python sys.path:"
"$VENV_PYTHON" -c "import sys; print('\n'.join(sys.path))"

# Install/upgrade PyTorch with CUDA support
echo "[wan_talk] Installing PyTorch and dependencies..."
"$VENV_PIP" install --upgrade pip wheel setuptools

# Install PyTorch first
echo "[wan_talk] Installing PyTorch with CUDA 12.8..."
"$VENV_PIP" install --no-cache-dir \
    torch torchvision torchaudio \
    --index-url https://download.pytorch.org/whl/cu128

# Install opencv and other critical dependencies
echo "[wan_talk] Installing OpenCV..."
"$VENV_PIP" install --no-cache-dir opencv-python opencv-python-headless

# Verify PyTorch
echo "[wan_talk] Verifying PyTorch installation..."
"$VENV_PYTHON" -c "import torch; print(f'✓ PyTorch {torch.__version__}')"
"$VENV_PYTHON" -c "import torch; print(f'✓ PyTorch location: {torch.__file__}')"
"$VENV_PYTHON" -c "import torch; print(f'✓ CUDA available: {torch.cuda.is_available()}')"
"$VENV_PYTHON" -c "import torchvision; print(f'✓ torchvision {torchvision.__version__}')"
"$VENV_PYTHON" -c "import cv2; print(f'✓ OpenCV {cv2.__version__}')"

# Install ComfyUI if not present
if [[ ! -d "$COMFY_ROOT" ]]; then
    echo "[wan_talk] Installing ComfyUI..."
    cd "$WORKSPACE_DIR"
    git clone https://github.com/comfyanonymous/ComfyUI.git "$COMFY_ROOT"
    cd "$COMFY_ROOT"
    "$VENV_PIP" install -r requirements.txt
    "$VENV_PIP" install torchsde einops transformers safetensors aiohttp kornia spandrel soundfile scipy
    echo "[wan_talk] ComfyUI installed"
else
    echo "[wan_talk] ComfyUI already installed"
    cd "$COMFY_ROOT"
    "$VENV_PIP" install -r requirements.txt || echo "Warning: Some requirements failed"
    "$VENV_PIP" install torchsde einops transformers safetensors aiohttp kornia spandrel soundfile scipy
fi

# Install ComfyUI API Wrapper
if [[ ! -d "$API_WRAPPER_DIR" ]]; then
    echo "[wan_talk] Installing ComfyUI API Wrapper..."
    cd "$WORKSPACE_DIR"
    git clone https://github.com/ai-dock/comfyui-api-wrapper.git "$API_WRAPPER_DIR"
    cd "$API_WRAPPER_DIR"
    "$VENV_PIP" install -r requirements.txt
    echo "[wan_talk] API Wrapper installed"
else
    echo "[wan_talk] API Wrapper already installed"
    cd "$API_WRAPPER_DIR"
    "$VENV_PIP" install -r requirements.txt || echo "Warning: Some requirements failed"
fi

# Install custom nodes with dependencies
CUSTOM_NODE_DIR="$COMFY_ROOT/custom_nodes"
mkdir -p "$CUSTOM_NODE_DIR"

install_custom_node() {
    local repo_url="$1"
    local node_name="$(basename "$repo_url" .git)"
    local clone_dir="$CUSTOM_NODE_DIR/$node_name"
    
    if [[ -d "$clone_dir" ]]; then
        echo "[wan_talk] Node exists: $node_name - updating dependencies"
    else
        echo "[wan_talk] Cloning $node_name..."
        git clone --depth 1 "$repo_url" "$clone_dir" || {
            echo "Warning: Failed to clone $node_name"
            return 1
        }
    fi
    
    # Install requirements
    if [[ -f "$clone_dir/requirements.txt" ]]; then
        echo "[wan_talk] Installing requirements for $node_name..."
        "$VENV_PIP" install -r "$clone_dir/requirements.txt" || echo "Warning: Some dependencies failed for $node_name"
    fi
    
    # Run install script if exists
    if [[ -f "$clone_dir/install.py" ]]; then
        echo "[wan_talk] Running install.py for $node_name..."
        cd "$clone_dir"
        "$VENV_PYTHON" install.py || echo "Warning: install.py failed for $node_name"
    fi
    
    # Special handling for specific nodes
    case "$node_name" in
        "ComfyUI-VideoHelperSuite")
            "$VENV_PIP" install imageio imageio-ffmpeg || echo "Warning: imageio install failed"
            ;;
        "ComfyUI-KJNodes")
            "$VENV_PIP" install numba || echo "Warning: numba install failed"
            ;;
        "ComfyUI-WanVideoWrapper")
            "$VENV_PIP" install huggingface_hub diffusers || echo "Warning: WanVideo deps failed"
            ;;
        "audio-separation-nodes-comfyui")
            "$VENV_PIP" install librosa soundfile || echo "Warning: audio deps failed"
            ;;
    esac
}

echo "[wan_talk] Installing custom nodes..."
REQUIRED_NODES=(
    "https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite"
    "https://github.com/kijai/ComfyUI-KJNodes.git"
    "https://github.com/kijai/ComfyUI-WanVideoWrapper"
    "https://github.com/christian-byrne/audio-separation-nodes-comfyui"
)

for repo in "${REQUIRED_NODES[@]}"; do
    install_custom_node "$repo"
done

# Create directories
echo "[wan_talk] Creating directories..."
mkdir -p "$COMFY_ROOT/input/wan_talk/audio"
mkdir -p "$COMFY_ROOT/input/wan_talk/images"
mkdir -p "$COMFY_ROOT/output"
mkdir -p "$COMFY_ROOT/models/checkpoints"
mkdir -p "$COMFY_ROOT/models/vae"
mkdir -p "$COMFY_ROOT/models/clip_vision"
mkdir -p "$COMFY_ROOT/models/loras"
mkdir -p "$COMFY_ROOT/models/unet"
mkdir -p "$COMFY_ROOT/models/text_encoders"

chmod -R 755 "$COMFY_ROOT"

# Verify installation
echo "[wan_talk] Verifying installation..."
"$VENV_PYTHON" << 'PYTHON'
import sys
import os

print(f"Python executable: {sys.executable}")
print(f"Python version: {sys.version}")
print(f"Site packages: {[p for p in sys.path if 'site-packages' in p]}")

required_packages = [
    'torch', 'torchvision', 'torchaudio', 
    'PIL', 'numpy', 'cv2', 'aiohttp',
    'transformers', 'safetensors', 'soundfile'
]
missing = []
for pkg in required_packages:
    try:
        mod = __import__(pkg)
        location = getattr(mod, '__file__', 'built-in')
        print(f"✓ {pkg:20s} ({location})")
    except ImportError as e:
        print(f"✗ {pkg:20s} - MISSING ({e})")
        missing.append(pkg)

if missing:
    print(f"\nERROR: Missing packages: {', '.join(missing)}")
    sys.exit(1)
else:
    print("\n✓ All required packages installed successfully!")
    print(f"✓ All packages are in venv: {sys.prefix}")
PYTHON

# Финальная проверка torch
echo "[wan_talk] Final torch verification..."
if ! "$VENV_PYTHON" -c "import torch; print(f'Torch OK: {torch.__version__}')" 2>&1; then
    echo "[wan_talk] ERROR: Final torch verification failed!"
    echo "[wan_talk] Installed packages:"
    "$VENV_PIP" list | grep -i torch
    exit 1
fi

echo "=========================================="
echo "[wan_talk] Setup complete!"
echo "  Python: $VENV_PYTHON"
echo "  Pip: $VENV_PIP"
echo "  ComfyUI: $COMFY_ROOT"
echo "  API Wrapper: $API_WRAPPER_DIR"
echo "=========================================="