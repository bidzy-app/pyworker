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
ENV_PATH="${ENV_PATH:-$WORKSPACE_DIR/worker-env}"

if [ ! -d "$ENV_PATH" ]; then
    echo "[wan_talk] ERROR: Virtual environment not found at $ENV_PATH"
    exit 1
fi

VENV_PYTHON="$ENV_PATH/bin/python3"

if [ ! -f "$VENV_PYTHON" ]; then
    echo "[wan_talk] ERROR: Python not found in venv: $VENV_PYTHON"
    exit 1
fi

# Function to use pip via python -m pip
venv_pip() {
    "$VENV_PYTHON" -m pip "$@"
}

echo "=========================================="
echo "[wan_talk] Virtual environment info:"
echo "  ENV_PATH: $ENV_PATH"
echo "  VENV_PYTHON: $VENV_PYTHON"
echo "=========================================="

"$VENV_PYTHON" --version
venv_pip --version

# Install/upgrade PyTorch with CUDA support
echo "[wan_talk] Installing PyTorch and dependencies..."
venv_pip install --upgrade pip wheel setuptools

echo "[wan_talk] Installing PyTorch with CUDA 12.8..."
venv_pip install --no-cache-dir \
    torch torchvision torchaudio \
    --index-url https://download.pytorch.org/whl/cu128

venv_pip install --no-cache-dir opencv-python opencv-python-headless

# Verify PyTorch
"$VENV_PYTHON" -c "import torch; print(f'✓ PyTorch {torch.__version__}')"
"$VENV_PYTHON" -c "import torch; print(f'✓ CUDA available: {torch.cuda.is_available()}')"

# Install ComfyUI if not present
if [[ ! -d "$COMFY_ROOT" ]]; then
    echo "[wan_talk] Installing ComfyUI..."
    cd "$WORKSPACE_DIR"
    git clone https://github.com/comfyanonymous/ComfyUI.git "$COMFY_ROOT"
    cd "$COMFY_ROOT"
    venv_pip install -r requirements.txt
    venv_pip install torchsde einops transformers safetensors aiohttp kornia spandrel soundfile scipy
    echo "[wan_talk] ComfyUI installed"
else
    echo "[wan_talk] ComfyUI already installed"
    cd "$COMFY_ROOT"
    venv_pip install -r requirements.txt || echo "Warning: Some requirements failed"
fi

# ✅ Install ComfyUI-Manager (instead of manual nodes)
CUSTOM_NODE_DIR="$COMFY_ROOT/custom_nodes"
mkdir -p "$CUSTOM_NODE_DIR"
if [[ ! -d "$CUSTOM_NODE_DIR/ComfyUI-Manager" ]]; then
    echo "[wan_talk] Installing ComfyUI-Manager..."
    cd "$CUSTOM_NODE_DIR"
    git clone https://github.com/ltdrdata/ComfyUI-Manager
else
    echo "[wan_talk] ComfyUI-Manager already installed"
    cd "$CUSTOM_NODE_DIR/ComfyUI-Manager"
    git pull || echo "Warning: failed to update ComfyUI-Manager"
fi

cat > "$COMFY_ROOT/custom_nodes/install.json" << 'JSON'
{
  "repos": [
    "https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite",
    "https://github.com/kijai/ComfyUI-KJNodes.git",
    "https://github.com/kijai/ComfyUI-WanVideoWrapper",
    "https://github.com/christian-byrne/audio-separation-nodes-comfyui"
  ]
}
JSON

echo "[wan_talk] install.json создан для ComfyUI-Manager"

# Install ComfyUI API Wrapper
if [[ ! -d "$API_WRAPPER_DIR" ]]; then
    echo "[wan_talk] Installing ComfyUI API Wrapper..."
    cd "$WORKSPACE_DIR"
    git clone https://github.com/ai-dock/comfyui-api-wrapper.git "$API_WRAPPER_DIR"
    cd "$API_WRAPPER_DIR"
    venv_pip install -r requirements.txt
    echo "[wan_talk] API Wrapper installed"
else
    echo "[wan_talk] API Wrapper already installed"
    cd "$API_WRAPPER_DIR"
    venv_pip install -r requirements.txt || echo "Warning: Some requirements failed"
fi

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
print(f"Python executable: {sys.executable}")
print(f"Python version: {sys.version}")
required_packages = [
    'torch', 'torchvision', 'torchaudio',
    'PIL', 'numpy', 'cv2', 'aiohttp',
    'transformers', 'safetensors', 'soundfile'
]
missing = []
for pkg in required_packages:
    try:
        __import__(pkg)
        print(f"✓ {pkg}")
    except ImportError:
        print(f"✗ {pkg} - MISSING")
        missing.append(pkg)
if missing:
    print(f"\nERROR: Missing packages: {', '.join(missing)}")
    sys.exit(1)
else:
    print("\n✓ All required packages installed successfully!")
PYTHON

echo "=========================================="
echo "[wan_talk] Setup complete!"
echo "  Python: $VENV_PYTHON"
echo "  ComfyUI: $COMFY_ROOT"
echo "  ComfyUI-Manager: $CUSTOM_NODE_DIR/ComfyUI-Manager"
echo "  API Wrapper: $API_WRAPPER_DIR"
echo "=========================================="
