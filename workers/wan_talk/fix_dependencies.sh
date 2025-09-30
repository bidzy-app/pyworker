#!/bin/bash
# Emergency dependency fix script
# Run this if you encounter import errors

set -e

echo "=== Emergency Dependency Fix ==="

# Activate environment
if [ -d "/opt/micromamba/envs/comfyui" ]; then
    source /opt/micromamba/envs/comfyui/bin/activate
    echo "✓ Activated comfyui environment"
elif [ -d "/workspace/worker-env" ]; then
    source /workspace/worker-env/bin/activate
    echo "✓ Activated worker-env environment"
else
    echo "✗ No environment found!"
    exit 1
fi

echo ""
echo "Step 1: Fixing NumPy compatibility..."
pip uninstall -y numpy
pip install "numpy>=1.25.0,<2.0"
echo "✓ NumPy fixed"

echo ""
echo "Step 2: Reinstalling OpenCV..."
pip uninstall -y opencv-python opencv-contrib-python
pip install opencv-python
echo "✓ OpenCV reinstalled"

echo ""
echo "Step 3: Installing missing dependencies..."
pip install diffusers>=0.33.0
pip install librosa
pip install imageio-ffmpeg
pip install soundfile
pip install scipy
echo "✓ Dependencies installed"

echo ""
echo "Step 4: Verifying installation..."
python << 'EOF'
import sys
try:
    import numpy
    assert numpy.__version__.startswith('1.'), f"Wrong NumPy version: {numpy.__version__}"
    import cv2
    import diffusers
    import librosa
    import imageio_ffmpeg
    print(f"✓ NumPy {numpy.__version__}")
    print(f"✓ OpenCV {cv2.__version__}")
    print(f"✓ Diffusers {diffusers.__version__}")
    print("✓ Librosa")
    print("✓ imageio-ffmpeg")
    print("\n✓ All critical imports successful!")
except Exception as e:
    print(f"\n✗ Error: {e}")
    sys.exit(1)
EOF

echo ""
echo "Step 5: Restarting ComfyUI..."
pkill -9 -f "python.*main.py.*--port 8188" 2>/dev/null || true
sleep 2

cd /workspace/ComfyUI
nohup python main.py \
    --listen 127.0.0.1 \
    --port 8188 \
    --output-directory /workspace/ComfyUI/output \
    --input-directory /workspace/ComfyUI/input \
    >> /workspace/logs/comfyui.log 2>&1 &

echo "ComfyUI restarted with PID $!"

echo ""
echo "Step 6: Waiting for ComfyUI..."
for i in {1..30}; do
    if curl -s -f http://127.0.0.1:8188/system_stats > /dev/null 2>&1; then
        echo "✓ ComfyUI is ready!"
        break
    fi
    sleep 2
    echo "  Waiting... ($i/30)"
done

echo ""
echo "=== Fix Complete ==="
echo "Check logs: tail -f /workspace/logs/comfyui.log"