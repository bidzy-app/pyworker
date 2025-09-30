#!/bin/bash
# Test generation with wan_talk backend

set -e

echo "=== Testing WanTalk Generation ==="

# Check services are running
echo "Checking services..."
if ! curl -s -f http://127.0.0.1:8188/system_stats > /dev/null 2>&1; then
    echo "✗ ComfyUI is not running!"
    exit 1
fi

if ! curl -s -f http://127.0.0.1:8000/health > /dev/null 2>&1; then
    echo "✗ API Wrapper is not running!"
    exit 1
fi

echo "✓ All services are running"
echo ""

# Create test request
cat > /tmp/test_request.json << 'EOF'
{
  "request_id": "test-direct-001",
  "workflow_json": {
    "125": {
      "inputs": {
        "audioUI": "https://github.com/bidzy-app/pyworker/raw/refs/heads/main/workers/wan_talk/audio.m4a"
      },
      "class_type": "LoadAudio"
    },
    "245": {
      "inputs": {
        "image": "https://raw.githubusercontent.com/bidzy-app/pyworker/refs/heads/main/workers/wan_talk/9b55dbeb1c9a71af093b3b386da70d5a.jpg"
      },
      "class_type": "LoadImage"
    }
  }
}
EOF

# Send request
echo "Sending generation request..."
RESPONSE=$(curl -s -X POST http://127.0.0.1:8000/generate \
  -H "Content-Type: application/json" \
  -d @/tmp/test_request.json)

echo "Response:"
echo "$RESPONSE" | jq '.' || echo "$RESPONSE"

# Check status
echo ""
echo "Checking status..."
curl -s http://127.0.0.1:8000/status/test-direct-001 | jq '.' || echo "Status check failed"

echo ""
echo "=== Test Complete ==="
echo "Monitor logs: tail -f /workspace/logs/api_wrapper.log"