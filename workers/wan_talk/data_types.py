import copy
import io
import json
import os
import random
import uuid
from dataclasses import dataclass, field, fields
from pathlib import Path
from typing import Any, Dict, Optional

import numpy as np
import requests
from PIL import Image
from scipy.io import wavfile

from lib.data_types import ApiPayload, JsonDataException

_WORKFLOW_PATH = Path(__file__).with_name("workflow.json")
if not _WORKFLOW_PATH.exists():
    raise FileNotFoundError(f"Workflow template not found: {_WORKFLOW_PATH}")

with _WORKFLOW_PATH.open("r", encoding="utf-8") as fh:
    _WORKFLOW_TEMPLATE: Dict[str, Any] = json.load(fh)


def _parse_time(value: Any) -> float:
    if isinstance(value, (int, float)):
        return float(value)
    if isinstance(value, str):
        text = value.strip()
        if ":" in text:
            mins, secs = text.split(":", 1)
            return float(mins) * 60.0 + float(secs)
        return float(text)
    raise ValueError(f"Unsupported time format: {value!r}")


@dataclass
class WanTalkPayload(ApiPayload):
    positive_prompt: str
    negative_prompt: str

    # Audio input (provide one)
    audio_url: Optional[str] = None
    audio_path: Optional[str] = None

    # Image input (provide one)
    image_url: Optional[str] = None
    image_path: Optional[str] = None

    # Optional request metadata
    request_id: Optional[str] = None

    # Generation parameters
    width: int = 864
    height: int = 1536
    fps: int = 25
    num_frames: int = 500
    steps: int = 4
    cfg: float = 1.0
    shift: float = 8.0
    seed: Optional[int] = None

    # Audio processing
    chunk_length: float = 12.0
    chunk_overlap: float = 0.1
    audio_start: str = "0:00"
    audio_end: str = "12"

    # Video output
    filename_prefix: str = "WanVideo2_1_multitalk"
    loop_count: int = 0
    crf: int = 19
    output_format: str = "video/h264-mp4"
    pingpong: bool = False

    # Advanced settings
    vae_tiling: bool = False
    lora_strength: float = 0.8
    block_swap_blocks: int = 20

    # Model overrides (optional)
    multitalk_model: Optional[str] = None
    video_model: Optional[str] = None
    vae_model: Optional[str] = None
    text_encoder_model: Optional[str] = None
    clip_vision_model: Optional[str] = None
    lora_model: Optional[str] = None
    wav2vec_model: Optional[str] = None

    # S3 configuration (optional, can also use env vars)
    s3_access_key_id: Optional[str] = None
    s3_secret_access_key: Optional[str] = None
    s3_endpoint_url: Optional[str] = None
    s3_bucket_name: Optional[str] = None
    s3_region: Optional[str] = None

    # Webhook configuration (optional)
    webhook_url: Optional[str] = None
    webhook_extra_params: Dict[str, Any] = field(default_factory=dict)

    # Advanced workflow customization
    workflow_overrides: Dict[str, Any] = field(default_factory=dict)

    @classmethod
    def for_test(cls) -> "WanTalkPayload":
        # Generate test audio (3 seconds of silence)
        sr = 16000
        seconds = 3
        waveform = np.zeros(sr * seconds, dtype=np.int16)
        
        # Create temporary test files
        import tempfile
        audio_file = tempfile.NamedTemporaryFile(suffix='.wav', delete=False)
        wavfile.write(audio_file.name, sr, waveform)
        
        img = Image.new("RGB", (864, 1536), color=(32, 32, 32))
        image_file = tempfile.NamedTemporaryFile(suffix='.png', delete=False)
        img.save(image_file.name, format="PNG")

        return cls(
            positive_prompt="A woman talking",
            negative_prompt="low quality, artifacts",
            audio_path=audio_file.name,
            image_path=image_file.name,
        )

    @classmethod
    def from_json_msg(cls, json_msg: Dict[str, Any]) -> "WanTalkPayload":
        field_names = {f.name for f in fields(cls)}

        missing_required = {
            key: "missing parameter"
            for key in ("positive_prompt", "negative_prompt")
            if key not in json_msg
        }
        if missing_required:
            raise JsonDataException(missing_required)

        has_audio = any(
            json_msg.get(name) for name in ("audio_url", "audio_path")
        )
        has_image = any(
            json_msg.get(name) for name in ("image_url", "image_path")
        )

        errors: Dict[str, Any] = {}
        if not has_audio:
            errors["audio"] = "provide audio_url or audio_path"
        if not has_image:
            errors["image"] = "provide image_url or image_path"
        if errors:
            raise JsonDataException(errors)

        payload_kwargs = {k: v for k, v in json_msg.items() if k in field_names}
        return cls(**payload_kwargs)

    def generate_payload_json(self) -> Dict[str, Any]:
        """Generate the request payload for ComfyUI API Wrapper"""
        
        workflow = copy.deepcopy(_WORKFLOW_TEMPLATE)
        
        # Set audio and image URLs directly in the workflow
        # The API Wrapper will download them automatically
        if self.audio_url:
            workflow["125"]["inputs"]["audioUI"] = self.audio_url
        elif self.audio_path:
            workflow["125"]["inputs"]["audioUI"] = self.audio_path
            
        if self.image_url:
            workflow["245"]["inputs"]["image"] = self.image_url
        elif self.image_path:
            workflow["245"]["inputs"]["image"] = self.image_path

        # Set prompts
        workflow["135"]["inputs"]["positive_prompt"] = self.positive_prompt
        workflow["135"]["inputs"]["negative_prompt"] = self.negative_prompt

        # Audio timing
        workflow["159"]["inputs"]["start_time"] = self.audio_start
        workflow["159"]["inputs"]["end_time"] = str(self.audio_end)
        workflow["170"]["inputs"]["chunk_length"] = float(self.chunk_length)
        workflow["170"]["inputs"]["chunk_overlap"] = float(self.chunk_overlap)

        # Resolution
        workflow["235"]["inputs"]["value"] = int(self.width)
        workflow["236"]["inputs"]["value"] = int(self.height)
        workflow["192"]["inputs"]["width"] = int(self.width)
        workflow["192"]["inputs"]["height"] = int(self.height)
        workflow["192"]["inputs"]["tiled_vae"] = bool(self.vae_tiling)

        # Frame settings
        workflow["194"]["inputs"]["num_frames"] = int(self.num_frames)
        workflow["194"]["inputs"]["fps"] = int(self.fps)
        workflow["131"]["inputs"]["frame_rate"] = int(self.fps)

        # Output settings
        workflow["131"]["inputs"]["loop_count"] = int(self.loop_count)
        workflow["131"]["inputs"]["filename_prefix"] = self.filename_prefix
        workflow["131"]["inputs"]["format"] = self.output_format
        workflow["131"]["inputs"]["crf"] = int(self.crf)
        workflow["131"]["inputs"]["pingpong"] = bool(self.pingpong)

        # VAE tiling
        workflow["130"]["inputs"]["enable_vae_tiling"] = bool(self.vae_tiling)

        # Sampling parameters
        seed_value = self.seed if self.seed is not None else random.randrange(1 << 48)
        workflow["220"]["inputs"]["seed"] = int(seed_value)
        workflow["220"]["inputs"]["steps"] = int(self.steps)
        workflow["220"]["inputs"]["cfg"] = float(self.cfg)
        workflow["220"]["inputs"]["shift"] = float(self.shift)

        # Advanced settings
        workflow["134"]["inputs"]["blocks_to_swap"] = int(self.block_swap_blocks)
        workflow["138"]["inputs"]["strength"] = float(self.lora_strength)

        # Model overrides
        if self.multitalk_model:
            workflow["120"]["inputs"]["model"] = self.multitalk_model
        if self.video_model:
            workflow["122"]["inputs"]["model"] = self.video_model
        if self.vae_model:
            workflow["129"]["inputs"]["model_name"] = self.vae_model
        if self.text_encoder_model:
            workflow["136"]["inputs"]["model_name"] = self.text_encoder_model
        if self.clip_vision_model:
            workflow["173"]["inputs"]["clip_name"] = self.clip_vision_model
        if self.lora_model:
            workflow["138"]["inputs"]["lora"] = self.lora_model
        if self.wav2vec_model:
            workflow["137"]["inputs"]["model"] = self.wav2vec_model

        # Apply workflow overrides
        if self.workflow_overrides:
            workflow = self._merge_override(workflow, self.workflow_overrides)

        # Build the request payload in the ComfyUI API Wrapper format
        payload = {
            "input": {
                "request_id": self.request_id or str(uuid.uuid4()),
                "workflow_json": workflow,
            }
        }

        # Add S3 configuration if provided
        s3_config = {}
        if self.s3_access_key_id or os.getenv("S3_ACCESS_KEY_ID"):
            s3_config["access_key_id"] = self.s3_access_key_id or os.getenv("S3_ACCESS_KEY_ID")
        if self.s3_secret_access_key or os.getenv("S3_SECRET_ACCESS_KEY"):
            s3_config["secret_access_key"] = self.s3_secret_access_key or os.getenv("S3_SECRET_ACCESS_KEY")
        if self.s3_endpoint_url or os.getenv("S3_ENDPOINT_URL"):
            s3_config["endpoint_url"] = self.s3_endpoint_url or os.getenv("S3_ENDPOINT_URL")
        if self.s3_bucket_name or os.getenv("S3_BUCKET_NAME"):
            s3_config["bucket_name"] = self.s3_bucket_name or os.getenv("S3_BUCKET_NAME")
        if self.s3_region or os.getenv("S3_REGION"):
            s3_config["region"] = self.s3_region or os.getenv("S3_REGION")
        
        if s3_config:
            payload["input"]["s3"] = s3_config

        # Add webhook configuration if provided
        webhook_config = {}
        if self.webhook_url or os.getenv("WEBHOOK_URL"):
            webhook_config["url"] = self.webhook_url or os.getenv("WEBHOOK_URL")
        if self.webhook_extra_params:
            webhook_config["extra_params"] = self.webhook_extra_params
        
        if webhook_config:
            payload["input"]["webhook"] = webhook_config

        return payload

    def _merge_override(self, dst: Dict[str, Any], src: Dict[str, Any]) -> Dict[str, Any]:
        """Recursively merge workflow overrides"""
        for key, value in src.items():
            if isinstance(value, dict) and isinstance(dst.get(key), dict):
                dst[key] = self._merge_override(dst[key], value)
            else:
                dst[key] = value
        return dst

    def count_workload(self) -> float:
        """Calculate workload based on generation parameters"""
        # Base workload on resolution, frames, steps, and duration
        resolution_factor = (self.width * self.height) / (864 * 1536)
        frame_factor = self.num_frames / 500.0
        step_factor = max(self.steps / 4.0, 0.25)

        # Calculate duration from audio timing
        try:
            duration = _parse_time(self.audio_end) - _parse_time(self.audio_start)
        except Exception:
            duration = 12.0  # Default

        duration_factor = max(duration / 12.0, 0.5)

        # Combined workload
        workload = 100.0 * resolution_factor * frame_factor * step_factor * duration_factor
        return max(workload, 1.0)