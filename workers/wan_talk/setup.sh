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

# Ensure we're using the PyWorker venv
if [ -z "${VIRTUAL_ENV:-}" ]; then
    echo "[wan_talk] Activating virtual environment..."
    source "$WORKSPACE_DIR/worker-env/bin/activate"
fi

echo "[wan_talk] Using Python: $(which python3)"
echo "[wan_talk] Using venv: $VIRTUAL_ENV"

# Install/upgrade PyTorch with CUDA support
echo "[wan_talk] Installing PyTorch and dependencies..."
pip install --upgrade pip wheel setuptools

# Install PyTorch first
pip install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu128

# Install opencv and other critical dependencies
pip install opencv-python opencv-python-headless

# Verify PyTorch
python3 -c "import torch; print(f'✓ PyTorch {torch.__version__}')"
python3 -c "import torch; print(f'✓ CUDA available: {torch.cuda.is_available()}')"
python3 -c "import torchvision; print(f'✓ torchvision {torchvision.__version__}')"
python3 -c "import cv2; print(f'✓ OpenCV {cv2.__version__}')"

# Install ComfyUI if not present
if [[ ! -d "$COMFY_ROOT" ]]; then
    echo "[wan_talk] Installing ComfyUI..."
    cd "$WORKSPACE_DIR"
    git clone https://github.com/comfyanonymous/ComfyUI.git "$COMFY_ROOT"
    cd "$COMFY_ROOT"
    pip install -r requirements.txt
    pip install torchsde einops transformers safetensors aiohttp kornia spandrel soundfile scipy
    echo "[wan_talk] ComfyUI installed"
else
    echo "[wan_talk] ComfyUI already installed"
    cd "$COMFY_ROOT"
    pip install -r requirements.txt || echo "Warning: Some requirements failed"
    pip install torchsde einops transformers safetensors aiohttp kornia spandrel soundfile scipy
fi

# Install ComfyUI API Wrapper
if [[ ! -d "$API_WRAPPER_DIR" ]]; then
    echo "[wan_talk] Installing ComfyUI API Wrapper..."
    cd "$WORKSPACE_DIR"
    git clone https://github.com/ai-dock/comfyui-api-wrapper.git "$API_WRAPPER_DIR"
    cd "$API_WRAPPER_DIR"
    pip install -r requirements.txt
    echo "[wan_talk] API Wrapper installed"
else
    echo "[wan_talk] API Wrapper already installed"
    cd "$API_WRAPPER_DIR"
    pip install -r requirements.txt || echo "Warning: Some requirements failed"
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
        pip install -r "$clone_dir/requirements.txt" || echo "Warning: Some dependencies failed for $node_name"
    fi
    
    # Run install script if exists
    if [[ -f "$clone_dir/install.py" ]]; then
        echo "[wan_talk] Running install.py for $node_name..."
        cd "$clone_dir"
        python3 install.py || echo "Warning: install.py failed for $node_name"
    fi
    
    # Special handling for specific nodes
    case "$node_name" in
        "ComfyUI-VideoHelperSuite")
            pip install imageio imageio-ffmpeg || echo "Warning: imageio install failed"
            ;;
        "ComfyUI-KJNodes")
            pip install numba || echo "Warning: numba install failed"
            ;;
        "ComfyUI-WanVideoWrapper")
            pip install huggingface_hub diffusers || echo "Warning: WanVideo deps failed"
            ;;
        "audio-separation-nodes-comfyui")
            pip install librosa soundfile || echo "Warning: audio deps failed"
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
python3 << 'PYTHON'
import sys
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
    print("\n✓ All required packages installed")
PYTHON

echo "[wan_talk] Setup complete!"