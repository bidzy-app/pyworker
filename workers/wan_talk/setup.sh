#!/bin/bash
set -e -o pipefail

echo "[wan_talk] Starting setup..."

WORKSPACE_DIR="${WORKSPACE_DIR:-/workspace}"
COMFY_ROOT="$WORKSPACE_DIR/ComfyUI"
API_WRAPPER_DIR="$WORKSPACE_DIR/comfyui-api-wrapper"

# Function to log with timestamp
log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] [wan_talk] $*"
}

# Function to check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Activate the correct environment
if [ -d "/opt/micromamba/envs/comfyui" ]; then
    source /opt/micromamba/envs/comfyui/bin/activate
    log "Using micromamba comfyui environment"
elif [ -d "$WORKSPACE_DIR/worker-env" ]; then
    source "$WORKSPACE_DIR/worker-env/bin/activate"
    log "Using worker-env environment"
else
    log "ERROR: No Python environment found!"
    exit 1
fi

# Create necessary directories
log "Creating directories..."
mkdir -p "$COMFY_ROOT/custom_nodes"
mkdir -p "$COMFY_ROOT/models/checkpoints"
mkdir -p "$COMFY_ROOT/models/vae"
mkdir -p "$COMFY_ROOT/models/clip"
mkdir -p "$COMFY_ROOT/models/unet"
mkdir -p "$COMFY_ROOT/output"
mkdir -p "$COMFY_ROOT/input"
mkdir -p "$WORKSPACE_DIR/logs"

# Critical: Fix NumPy compatibility FIRST
log "Checking NumPy compatibility..."
NUMPY_VERSION=$(python -c "import numpy; print(numpy.__version__)" 2>/dev/null || echo "missing")

if [[ "$NUMPY_VERSION" == 2.* ]] || [[ "$NUMPY_VERSION" == "missing" ]]; then
    log "NumPy $NUMPY_VERSION detected - fixing compatibility..."
    pip uninstall -y numpy || true
    pip install "numpy>=1.25.0,<2.0"
    log "NumPy fixed to 1.x series"
else
    log "NumPy $NUMPY_VERSION is compatible"
fi

# Reinstall opencv-python with correct NumPy
log "Ensuring opencv-python compatibility..."
pip uninstall -y opencv-python opencv-contrib-python || true
pip install opencv-python

# Install critical missing dependencies
log "Installing core dependencies..."
pip install -q diffusers>=0.33.0
pip install -q librosa
pip install -q imageio-ffmpeg
pip install -q soundfile
pip install -q scipy

# Install ComfyUI-KJNodes dependencies if directory exists
if [ -d "$COMFY_ROOT/custom_nodes/ComfyUI-KJNodes" ]; then
    log "Installing ComfyUI-KJNodes dependencies..."
    if [ -f "$COMFY_ROOT/custom_nodes/ComfyUI-KJNodes/requirements.txt" ]; then
        pip install -q -r "$COMFY_ROOT/custom_nodes/ComfyUI-KJNodes/requirements.txt"
    fi
fi

# Install ComfyUI-WanVideoWrapper dependencies if directory exists
if [ -d "$COMFY_ROOT/custom_nodes/ComfyUI-WanVideoWrapper" ]; then
    log "Installing ComfyUI-WanVideoWrapper dependencies..."
    if [ -f "$COMFY_ROOT/custom_nodes/ComfyUI-WanVideoWrapper/requirements.txt" ]; then
        pip install -q -r "$COMFY_ROOT/custom_nodes/ComfyUI-WanVideoWrapper/requirements.txt"
    fi
fi

# Install VideoHelperSuite dependencies if directory exists
if [ -d "$COMFY_ROOT/custom_nodes/ComfyUI-VideoHelperSuite" ]; then
    log "Installing ComfyUI-VideoHelperSuite dependencies..."
    pip install -q imageio-ffmpeg
fi

# Install audio-separation-nodes dependencies if directory exists
if [ -d "$COMFY_ROOT/custom_nodes/audio-separation-nodes-comfyui" ]; then
    log "Installing audio-separation-nodes dependencies..."
    pip install -q librosa soundfile
fi

# Verify critical imports
log "Verifying installation..."
python << 'PYEOF'
import sys

required_packages = [
    ('torch', 'PyTorch'),
    ('torchvision', 'TorchVision'),
    ('torchaudio', 'TorchAudio'),
    ('PIL', 'Pillow'),
    ('numpy', 'NumPy'),
    ('cv2', 'OpenCV'),
    ('aiohttp', 'aiohttp'),
    ('transformers', 'Transformers'),
    ('safetensors', 'SafeTensors'),
    ('soundfile', 'SoundFile'),
]

optional_packages = [
    ('diffusers', 'Diffusers'),
    ('librosa', 'Librosa'),
    ('imageio_ffmpeg', 'imageio-ffmpeg'),
]

failed = []
warnings = []

print("\nRequired packages:")
for module, name in required_packages:
    try:
        __import__(module)
        print(f"✓ {name}")
    except ImportError as e:
        print(f"✗ {name} - {e}")
        failed.append(name)

print("\nOptional packages:")
for module, name in optional_packages:
    try:
        __import__(module)
        print(f"✓ {name}")
    except ImportError as e:
        print(f"⚠ {name} - {e}")
        warnings.append(name)

if failed:
    print(f"\n✗ Missing required packages: {', '.join(failed)}")
    sys.exit(1)

if warnings:
    print(f"\n⚠ Missing optional packages: {', '.join(warnings)}")
    print("  (These may be needed for specific custom nodes)")

print("\n✓ All required packages installed")
PYEOF

if [ $? -ne 0 ]; then
    log "ERROR: Setup verification failed!"
    exit 1
fi

# Clone/Update ComfyUI API Wrapper if needed
if [ ! -d "$API_WRAPPER_DIR" ]; then
    log "Cloning ComfyUI API Wrapper..."
    git clone https://github.com/your-repo/comfyui-api-wrapper.git "$API_WRAPPER_DIR"
else
    log "ComfyUI API Wrapper already exists"
fi

# Install API Wrapper dependencies
if [ -f "$API_WRAPPER_DIR/requirements.txt" ]; then
    log "Installing API Wrapper dependencies..."
    pip install -q -r "$API_WRAPPER_DIR/requirements.txt"
fi

log "Setup complete!"