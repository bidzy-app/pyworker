#!/bin/bash

set -e -o pipefail

WORKSPACE_DIR="${WORKSPACE_DIR:-/workspace}"

SERVER_DIR="$WORKSPACE_DIR/vast-pyworker"
ENV_PATH="$WORKSPACE_DIR/worker-env"
DEBUG_LOG="$WORKSPACE_DIR/debug.log"
PYWORKER_LOG="$WORKSPACE_DIR/pyworker.log"

REPORT_ADDR="${REPORT_ADDR:-https://cloud.vast.ai/api/v0,https://run.vast.ai}"
USE_SSL="${USE_SSL:-true}"
WORKER_PORT="${WORKER_PORT:-3000}"

mkdir -p "$WORKSPACE_DIR"
cd "$WORKSPACE_DIR"

# make all output go to $DEBUG_LOG and stdout without having to add `... | tee -a $DEBUG_LOG` to every command
exec &> >(tee -a "$DEBUG_LOG")

function echo_var(){
    echo "$1: ${!1}"
}

function log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*"
}

[ -z "$BACKEND" ] && echo "BACKEND must be set!" && exit 1
[ -z "$MODEL_LOG" ] && echo "MODEL_LOG must be set!" && exit 1
[ -z "$HF_TOKEN" ] && echo "HF_TOKEN must be set!" && exit 1
[ "$BACKEND" = "comfyui" ] && [ -z "$COMFY_MODEL" ] && echo "For comfyui backends, COMFY_MODEL must be set!" && exit 1

echo "start_server.sh"
date

echo_var BACKEND
echo_var REPORT_ADDR
echo_var WORKER_PORT
echo_var WORKSPACE_DIR
echo_var SERVER_DIR
echo_var ENV_PATH
echo_var DEBUG_LOG
echo_var PYWORKER_LOG
echo_var MODEL_LOG

# Populate /etc/environment with quoted values
if ! grep -q "VAST" /etc/environment; then
    env -0 | grep -zEv "^(HOME=|SHLVL=)|CONDA" | while IFS= read -r -d '' line; do
            name=${line%%=*}
            value=${line#*=}
            printf '%s="%s"\n' "$name" "$value"
        done > /etc/environment
fi

if [ ! -d "$ENV_PATH" ]
then
    echo "setting up venv"
    if ! which uv; then
        curl -LsSf https://astral.sh/uv/install.sh | sh
        source ~/.local/bin/env
    fi

    # Fork testing
    [[ ! -d $SERVER_DIR ]] && git clone "${PYWORKER_REPO:-https://github.com/bidzy-app/pyworker}" "$SERVER_DIR"
    if [[ -n ${PYWORKER_REF:-} ]]; then
        (cd "$SERVER_DIR" && git checkout "$PYWORKER_REF")
    fi

    uv venv --python-preference only-managed "$ENV_PATH" -p 3.10
    source "$ENV_PATH/bin/activate"

    uv pip install -r "${SERVER_DIR}/requirements.txt"

    touch ~/.no_auto_tmux
else
    [[ -f ~/.local/bin/env ]] && source ~/.local/bin/env
    source "$WORKSPACE_DIR/worker-env/bin/activate"
    echo "environment activated"
    echo "venv: $VIRTUAL_ENV"
fi

# Backend-specific bootstrap (models, custom nodes, etc.)
if [ "$BACKEND" = "wan_talk" ]; then
    SETUP_SCRIPT="$SERVER_DIR/workers/wan_talk/setup.sh"
    if [ -x "$SETUP_SCRIPT" ]; then
        log "Running wan_talk setup..."
        bash "$SETUP_SCRIPT"
        log "wan_talk setup complete"
    else
        log "ERROR: wan_talk setup script missing or not executable: $SETUP_SCRIPT"
        exit 1
    fi
    
    # Additional dependency verification for wan_talk
    log "Verifying wan_talk dependencies..."
    
    # Ensure we're in the correct environment
    if [ -d "/opt/micromamba/envs/comfyui" ]; then
        source /opt/micromamba/envs/comfyui/bin/activate
    fi
    
    # Critical: Check and fix NumPy before starting ComfyUI
    NUMPY_VERSION=$(python -c "import numpy; print(numpy.__version__)" 2>/dev/null || echo "missing")
    if [[ "$NUMPY_VERSION" == 2.* ]] || [[ "$NUMPY_VERSION" == "missing" ]]; then
        log "WARNING: NumPy $NUMPY_VERSION detected - fixing compatibility..."
        pip uninstall -y numpy
        pip install "numpy>=1.25.0,<2.0"
        pip uninstall -y opencv-python
        pip install opencv-python
        log "NumPy compatibility fixed"
    fi
    
    # Verify critical dependencies are installed
    log "Checking critical dependencies..."
    if ! python -c "import cv2, diffusers, librosa, imageio_ffmpeg" 2>/dev/null; then
        log "WARNING: Missing dependencies detected, installing..."
        pip install opencv-python diffusers>=0.33.0 librosa imageio-ffmpeg
        log "Dependencies installed"
    fi
    
    log "Dependency verification complete"
fi

[ ! -d "$SERVER_DIR/workers/$BACKEND" ] && echo "$BACKEND not supported!" && exit 1

if [ "$USE_SSL" = true ]; then

    cat << EOF > /etc/openssl-san.cnf
    [req]
    default_bits       = 2048
    distinguished_name = req_distinguished_name
    req_extensions     = v3_req

    [req_distinguished_name]
    countryName         = US
    stateOrProvinceName = CA
    organizationName    = Vast.ai Inc.
    commonName          = vast.ai

    [v3_req]
    basicConstraints = CA:FALSE
    keyUsage         = nonRepudiation, digitalSignature, keyEncipherment
    subjectAltName   = @alt_names

    [alt_names]
    IP.1   = 0.0.0.0
EOF

    openssl req -newkey rsa:2048 -subj "/C=US/ST=CA/CN=pyworker.vast.ai/" \
        -nodes \
        -sha256 \
        -keyout /etc/instance.key \
        -out /etc/instance.csr \
        -config /etc/openssl-san.cnf

    curl --header 'Content-Type: application/octet-stream' \
        --data-binary @//etc/instance.csr \
        -X \
        POST "https://console.vast.ai/api/v0/sign_cert/?instance_id=$CONTAINER_ID" > /etc/instance.crt;
fi

UNSECURED=${UNSECURED:-true}
export REPORT_ADDR WORKER_PORT USE_SSL UNSECURED

# Start ComfyUI and API Wrapper for wan_talk backend
if [ "$BACKEND" = "wan_talk" ]; then
    export COMFY_ROOT="$WORKSPACE_DIR/ComfyUI"
    export API_WRAPPER_DIR="$WORKSPACE_DIR/comfyui-api-wrapper"
    export MODEL_SERVER_URL="http://127.0.0.1:8000"
    export COMFYUI_API_BASE="http://127.0.0.1:8188"
    
    # Create logs directory
    mkdir -p "$WORKSPACE_DIR/logs"
    COMFY_LOG="$WORKSPACE_DIR/logs/comfyui.log"
    API_WRAPPER_LOG="$WORKSPACE_DIR/logs/api_wrapper.log"
    
    log "Starting ComfyUI services for wan_talk backend..."
    
    # Kill any existing processes on the ports
    log "Checking for existing processes..."
    lsof -ti:8188 | xargs kill -9 2>/dev/null || true
    lsof -ti:8000 | xargs kill -9 2>/dev/null || true
    sleep 2
    
    # Start ComfyUI in background if not already running
    if ! pgrep -f "python.*main.py.*--port 8188" > /dev/null; then
        log "Starting ComfyUI on port 8188..."
        cd "$COMFY_ROOT"
        
        # Clear the model log before starting
        : > "$MODEL_LOG"
        
        # Start ComfyUI with output to both MODEL_LOG and COMFY_LOG
        nohup python main.py \
            --listen 127.0.0.1 \
            --port 8188 \
            --output-directory "$COMFY_ROOT/output" \
            --input-directory "$COMFY_ROOT/input" \
            >> "$MODEL_LOG" 2>&1 &
        
        COMFY_PID=$!
        log "ComfyUI started with PID $COMFY_PID"
        
        # Wait for ComfyUI to be ready (check /system_stats endpoint)
        log "Waiting for ComfyUI to start (checking http://127.0.0.1:8188/system_stats)..."
        COMFY_READY=false
        for i in {1..60}; do
            if curl -s -f http://127.0.0.1:8188/system_stats > /dev/null 2>&1; then
                log "✓ ComfyUI is ready! (attempt $i/60)"
                COMFY_READY=true
                break
            fi
            echo "  Waiting for ComfyUI... (attempt $i/60)"
            sleep 2
        done
        
        if [ "$COMFY_READY" = false ]; then
            log "ERROR: ComfyUI failed to start within 120 seconds"
            log "Last 50 lines of ComfyUI log:"
            tail -n 50 "$MODEL_LOG"
            exit 1
        fi
    else
        log "ComfyUI is already running"
    fi
    
    # Start API Wrapper in background if not already running
    if ! pgrep -f "uvicorn.*main:app.*--port 8000" > /dev/null; then
        log "Starting ComfyUI API Wrapper on port 8000..."
        cd "$API_WRAPPER_DIR"
        
        # Set API Wrapper environment variables
        export COMFYUI_API_BASE="http://127.0.0.1:8188"
        export API_HOST="127.0.0.1"
        export API_PORT="8000"
        export API_WORKERS="1"
        export PREPROCESS_WORKERS="${PREPROCESS_WORKERS:-3}"
        export GENERATION_WORKERS="${GENERATION_WORKERS:-1}"
        export POSTPROCESS_WORKERS="${POSTPROCESS_WORKERS:-3}"
        export MAX_QUEUE_SIZE="${MAX_QUEUE_SIZE:-100}"
        
        # Use Redis cache if available, otherwise use memory
        if command -v redis-cli > /dev/null 2>&1 && redis-cli ping > /dev/null 2>&1; then
            export API_CACHE="redis"
            export REDIS_HOST="${REDIS_HOST:-localhost}"
            export REDIS_PORT="${REDIS_PORT:-6379}"
            export REDIS_DB="${REDIS_DB:-0}"
            log "Using Redis cache"
        else
            export API_CACHE="memory"
            log "Using in-memory cache"
        fi
        
        # Start API Wrapper
        nohup uvicorn main:app \
            --host 127.0.0.1 \
            --port 8000 \
            --workers 1 \
            >> "$API_WRAPPER_LOG" 2>&1 &
        
        WRAPPER_PID=$!
        log "API Wrapper started with PID $WRAPPER_PID"
        
        # Wait for API Wrapper to be ready (check /health endpoint)
        log "Waiting for API Wrapper to start (checking http://127.0.0.1:8000/health)..."
        WRAPPER_READY=false
        for i in {1..60}; do
            if curl -s -f http://127.0.0.1:8000/health > /dev/null 2>&1; then
                log "✓ API Wrapper is ready! (attempt $i/60)"
                WRAPPER_READY=true
                break
            fi
            echo "  Waiting for API Wrapper... (attempt $i/60)"
            sleep 2
        done
        
        if [ "$WRAPPER_READY" = false ]; then
            log "ERROR: API Wrapper failed to start within 120 seconds"
            log "Last 50 lines of API Wrapper log:"
            tail -n 50 "$API_WRAPPER_LOG"
            exit 1
        fi
    else
        log "API Wrapper is already running"
    fi
    
    # Verify both services are responding
    log "Verifying services..."
    if ! curl -s -f http://127.0.0.1:8188/system_stats > /dev/null 2>&1; then
        log "ERROR: ComfyUI is not responding on http://127.0.0.1:8188"
        exit 1
    fi
    
    if ! curl -s -f http://127.0.0.1:8000/health > /dev/null 2>&1; then
        log "ERROR: API Wrapper is not responding on http://127.0.0.1:8000"
        exit 1
    fi
    
    log "✓ All services are running and healthy"
    log "  - ComfyUI: http://127.0.0.1:8188"
    log "  - API Wrapper: http://127.0.0.1:8000"
    log "  - ComfyUI Log: $MODEL_LOG"
    log "  - API Wrapper Log: $API_WRAPPER_LOG"
fi

cd "$SERVER_DIR"

log "Launching PyWorker server"

# if instance is rebooted, we want to clear out the log file so pyworker doesn't read lines
# from the run prior to reboot. past logs are saved in $MODEL_LOG.old for debugging only
if [ "$BACKEND" != "wan_talk" ]; then
    # For non-wan_talk backends, clear the log as before
    [ -e "$MODEL_LOG" ] && cat "$MODEL_LOG" >> "$MODEL_LOG.old" && : > "$MODEL_LOG"
fi

# Start PyWorker server
(python3 -m "workers.$BACKEND.server" |& tee -a "$PYWORKER_LOG") &
PYWORKER_PID=$!
log "PyWorker server started with PID $PYWORKER_PID"

# Keep the script running and monitor processes
log "All services started successfully!"
log "Monitoring processes..."

# Function to check if a process is running
check_process() {
    local pid=$1
    local name=$2
    if ! kill -0 $pid 2>/dev/null; then
        log "ERROR: $name (PID $pid) has stopped!"
        return 1
    fi
    return 0
}

# Monitor loop
while true; do
    sleep 30
    
    if [ "$BACKEND" = "wan_talk" ]; then
        # Check all services
        if [ -n "${COMFY_PID:-}" ]; then
            check_process $COMFY_PID "ComfyUI" || exit 1
        fi
        
        if [ -n "${WRAPPER_PID:-}" ]; then
            check_process $WRAPPER_PID "API Wrapper" || exit 1
        fi
    fi
    
    check_process $PYWORKER_PID "PyWorker" || exit 1
done