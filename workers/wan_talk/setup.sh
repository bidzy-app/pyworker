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
    libxext6

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

# Install/upgrade PyTorch with CUDA support in the current venv
echo "[wan_talk] Installing PyTorch and torchvision..."
pip install --upgrade pip
pip install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu128

# Verify PyTorch installation
python3 -c "import torch; print(f'PyTorch {torch.__version__} installed')"
python3 -c "import torch; print(f'CUDA available: {torch.cuda.is_available()}')"
python3 -c "import torchvision; print(f'torchvision {torchvision.__version__} installed')"

# Install ComfyUI if not present
if [[ ! -d "$COMFY_ROOT" ]]; then
    echo "[wan_talk] Installing ComfyUI..."
    cd "$WORKSPACE_DIR"
    
    # Clone ComfyUI
    git clone https://github.com/comfyanonymous/ComfyUI.git "$COMFY_ROOT"
    
    cd "$COMFY_ROOT"
    
    # Install ComfyUI requirements
    echo "[wan_talk] Installing ComfyUI requirements..."
    pip install -r requirements.txt
    
    # Install additional dependencies
    pip install torchsde einops transformers safetensors aiohttp kornia spandrel soundfile
    
    echo "[wan_talk] ComfyUI installed to $COMFY_ROOT"
else
    echo "[wan_talk] ComfyUI already installed at $COMFY_ROOT"
    
    # Make sure dependencies are installed
    cd "$COMFY_ROOT"
    pip install -r requirements.txt
    pip install torchsde einops transformers safetensors aiohttp kornia spandrel soundfile
fi

# Verify ComfyUI can import
echo "[wan_talk] Verifying ComfyUI installation..."
cd "$COMFY_ROOT"
python3 -c "import torch; import torchvision; print('✓ PyTorch modules OK')"
python3 -c "import folder_paths; print('✓ ComfyUI modules OK')" || {
    echo "Warning: ComfyUI modules test failed, but continuing..."
}

# Install ComfyUI API Wrapper
if [[ ! -d "$API_WRAPPER_DIR" ]]; then
    echo "[wan_talk] Installing ComfyUI API Wrapper..."
    cd "$WORKSPACE_DIR"
    git clone https://github.com/ai-dock/comfyui-api-wrapper.git "$API_WRAPPER_DIR"
    cd "$API_WRAPPER_DIR"
    
    # Install API Wrapper requirements
    echo "[wan_talk] Installing API Wrapper requirements..."
    pip install -r requirements.txt
    
    echo "[wan_talk] API Wrapper installed"
else
    echo "[wan_talk] API Wrapper already installed at $API_WRAPPER_DIR"
    
    # Make sure dependencies are installed
    cd "$API_WRAPPER_DIR"
    pip install -r requirements.txt
fi

# Install custom nodes
CUSTOM_NODE_DIR="$COMFY_ROOT/custom_nodes"
mkdir -p "$CUSTOM_NODE_DIR"

clone_and_install_node() {
    local repo_url="$1"
    local node_name="$(basename "$repo_url" .git)"
    local clone_dir="$CUSTOM_NODE_DIR/$node_name"
    
    if [[ -d "$clone_dir" ]]; then
        echo "[wan_talk] Custom node already exists: $node_name"
        # Still try to install/update dependencies
        if [[ -f "$clone_dir/requirements.txt" ]]; then
            echo "[wan_talk] Updating dependencies for $node_name..."
            pip install -r "$clone_dir/requirements.txt" || echo "Warning: Some dependencies failed for $node_name"
        fi
        return
    fi
    
    echo "[wan_talk] Cloning $node_name..."
    git clone --depth 1 "$repo_url" "$clone_dir"
    
    # Install node dependencies if requirements.txt exists
    if [[ -f "$clone_dir/requirements.txt" ]]; then
        echo "[wan_talk] Installing dependencies for $node_name..."
        pip install -r "$clone_dir/requirements.txt" || echo "Warning: Some dependencies failed for $node_name"
    fi
    
    # Install install.py if exists
    if [[ -f "$clone_dir/install.py" ]]; then
        echo "[wan_talk] Running install.py for $node_name..."
        cd "$clone_dir"
        python3 install.py || echo "Warning: install.py failed for $node_name"
    fi
}

# Required custom nodes for Wan Talk
echo "[wan_talk] Installing custom nodes..."
REQUIRED_NODES=(
    "https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite"
    "https://github.com/christian-byrne/audio-separation-nodes-comfyui"
    "https://github.com/kijai/ComfyUI-WanVideoWrapper"
    "https://github.com/kijai/ComfyUI-KJNodes.git"
)

for repo in "${REQUIRED_NODES[@]}"; do
    clone_and_install_node "$repo"
done

# Create input directories for assets
echo "[wan_talk] Creating input directories..."
mkdir -p "$COMFY_ROOT/input/wan_talk/audio"
mkdir -p "$COMFY_ROOT/input/wan_talk/images"
mkdir -p "$COMFY_ROOT/output"

# Create models directories
echo "[wan_talk] Creating model directories..."
mkdir -p "$COMFY_ROOT/models/checkpoints"
mkdir -p "$COMFY_ROOT/models/vae"
mkdir -p "$COMFY_ROOT/models/clip_vision"
mkdir -p "$COMFY_ROOT/models/loras"
mkdir -p "$COMFY_ROOT/models/unet"
mkdir -p "$COMFY_ROOT/models/text_encoders"
mkdir -p "$COMFY_ROOT/models/wan"

# Set proper permissions
chmod -R 755 "$COMFY_ROOT"

# Verify installation
echo "[wan_talk] Verifying installation..."
echo "✓ ComfyUI: $COMFY_ROOT"
echo "✓ API Wrapper: $API_WRAPPER_DIR"
echo "✓ Custom nodes:"
ls -1 "$CUSTOM_NODE_DIR" | sed 's/^/  - /'

echo "[wan_talk] Verifying Python packages..."
python3 << 'PYTHON'
import sys
packages = ['torch', 'torchvision', 'torchaudio', 'PIL', 'numpy', 'aiohttp']
missing = []
for pkg in packages:
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