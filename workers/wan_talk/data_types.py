import base64
import copy
import io
import json
import os
import random
import uuid
from dataclasses import dataclass, field
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

_DEFAULT_MODELS = {
    "multitalk_model": _WORKFLOW_TEMPLATE["120"]["inputs"]["model"],
    "video_model": _WORKFLOW_TEMPLATE["122"]["inputs"]["model"],
    "vae_model": _WORKFLOW_TEMPLATE["129"]["inputs"]["model_name"],
    "text_encoder_model": _WORKFLOW_TEMPLATE["136"]["inputs"]["model_name"],
    "clip_vision_model": _WORKFLOW_TEMPLATE["173"]["inputs"]["clip_name"],
    "lora_model": _WORKFLOW_TEMPLATE["138"]["inputs"]["lora"],
    "wav2vec_model": _WORKFLOW_TEMPLATE["137"]["inputs"]["model"],
}

_REQUEST_TEMPLATE = {
    "handler": "RawWorkflow",
    "workflow_json": {},
    "aws_access_key_id": "",
    "aws_secret_access_key": "",
    "aws_endpoint_url": "",
    "aws_bucket_name": "",
    "webhook_url": "",
    "webhook_extra_params": {},
}


def _strip_data_url(value: str) -> str:
    if "," in value and value.strip().lower().startswith("data:"):
        return value.split(",", 1)[1]
    return value


def _ensure_dir(path: Path) -> None:
    path.mkdir(parents=True, exist_ok=True)


def _merge_override(dst: Dict[str, Any], src: Dict[str, Any]) -> Dict[str, Any]:
    for key, value in src.items():
        if isinstance(value, dict) and isinstance(dst.get(key), dict):
            dst[key] = _merge_override(dst[key], value)
        else:
            dst[key] = value
    return dst


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

    audio_base64: Optional[str] = None
    audio_url: Optional[str] = None
    audio_path: Optional[str] = None
    image_base64: Optional[str] = None
    image_url: Optional[str] = None
    image_path: Optional[str] = None

    request_id: Optional[str] = None
    client_id: Optional[str] = None

    filename_prefix: str = "WanVideo2_1_multitalk"
    audio_seconds: Optional[float] = None
    audio_extension: str = "wav"
    image_extension: str = "png"

    width: int = 864
    height: int = 1536
    fps: int = 25
    num_frames: int = 500
    steps: int = 4
    cfg: float = 1.0
    shift: float = 8.0
    seed: Optional[int] = None

    chunk_length: float = 12.0
    chunk_overlap: float = 0.1
    audio_start: str = "0:00"
    audio_end: str = "12"

    loop_count: int = 0
    crf: int = 19
    output_format: str = "video/h264-mp4"
    pingpong: bool = False
    vae_tiling: bool = False
    lora_strength: float = 0.8

    multitalk_model: Optional[str] = None
    video_model: Optional[str] = None
    vae_model: Optional[str] = None
    text_encoder_model: Optional[str] = None
    clip_vision_model: Optional[str] = None
    lora_model: Optional[str] = None
    wav2vec_model: Optional[str] = None

    block_swap_blocks: int = 20
    workflow_overrides: Dict[str, Any] = field(default_factory=dict)

    @classmethod
    def for_test(cls) -> "WanTalkPayload":
        sr = 16000
        seconds = 3
        waveform = np.zeros(sr * seconds, dtype=np.int16)
        audio_buf = io.BytesIO()
        wavfile.write(audio_buf, sr, waveform)
        audio_b64 = base64.b64encode(audio_buf.getvalue()).decode("utf-8")

        img = Image.new("RGB", (864, 1536), color=(32, 32, 32))
        img_buf = io.BytesIO()
        img.save(img_buf, format="PNG")
        image_b64 = base64.b64encode(img_buf.getvalue()).decode("utf-8")

        return cls(
            positive_prompt="A woman talking",
            negative_prompt="low quality, artifacts",
            audio_base64=audio_b64,
            image_base64=image_b64,
            audio_seconds=float(seconds),
        )

    @classmethod
    def from_json_msg(cls, json_msg: Dict[str, Any]) -> "WanTalkPayload":
        required = ["positive_prompt", "negative_prompt"]
        missing = {key: "missing parameter" for key in required if key not in json_msg}
        if missing:
            raise JsonDataException(missing)

        has_audio = any(
            json_msg.get(field)
            for field in ("audio_base64", "audio_url", "audio_path")
        )
        has_image = any(
            json_msg.get(field)
            for field in ("image_base64", "image_url", "image_path")
        )

        errors: Dict[str, Any] = {}
        if not has_audio:
            errors["audio"] = "provide audio_base64, audio_url или audio_path"
        if not has_image:
            errors["image"] = "provide image_base64, image_url или image_path"
        if errors:
            raise JsonDataException(errors)

        return cls(**{k: v for k, v in json_msg.items() if hasattr(cls, k)})

    def _resolve_binary(
        self, *,
        base64_value: Optional[str],
        url: Optional[str],
        path: Optional[str],
        label: str,
    ) -> bytes:
        if base64_value:
            return base64.b64decode(_strip_data_url(base64_value))
        if url:
            resp = requests.get(url, timeout=60)
            resp.raise_for_status()
            return resp.content
        if path:
            return Path(path).expanduser().read_bytes()
        raise JsonDataException({label: "source missing after validation"})

    def _write_asset(self, data: bytes, root: Path, subdir: str, suffix: str) -> str:
        _ensure_dir(root / subdir)
        filename = f"{uuid.uuid4().hex}.{suffix}"
        destination = root / subdir / filename
        destination.write_bytes(data)
        return f"{subdir}/{filename}"

    def generate_payload_json(self) -> Dict[str, Any]:
        assets_root = Path(os.environ.get("WAN_INPUT_ROOT", "/workspace/ComfyUI/input"))
        audio_bytes = self._resolve_binary(
            base64_value=self.audio_base64,
            url=self.audio_url,
            path=self.audio_path,
            label="audio",
        )
        image_bytes = self._resolve_binary(
            base64_value=self.image_base64,
            url=self.image_url,
            path=self.image_path,
            label="image",
        )

        audio_rel = self._write_asset(
            audio_bytes, assets_root, "wan_talk/audio", self.audio_extension
        )
        image_rel = self._write_asset(
            image_bytes, assets_root, "wan_talk/images", self.image_extension
        )

        workflow = copy.deepcopy(_WORKFLOW_TEMPLATE)
        workflow["125"]["inputs"]["audioUI"] = audio_rel
        workflow["245"]["inputs"]["image"] = image_rel
        workflow["135"]["inputs"]["positive_prompt"] = self.positive_prompt
        workflow["135"]["inputs"]["negative_prompt"] = self.negative_prompt

        workflow["159"]["inputs"]["start_time"] = self.audio_start
        workflow["159"]["inputs"]["end_time"] = str(self.audio_end)

        workflow["170"]["inputs"]["chunk_length"] = float(self.chunk_length)
        workflow["170"]["inputs"]["chunk_overlap"] = float(self.chunk_overlap)

        workflow["235"]["inputs"]["value"] = int(self.width)
        workflow["236"]["inputs"]["value"] = int(self.height)

        workflow["192"]["inputs"]["width"] = int(self.width)
        workflow["192"]["inputs"]["height"] = int(self.height)
        workflow["192"]["inputs"]["tiled_vae"] = bool(self.vae_tiling)

        workflow["194"]["inputs"]["num_frames"] = int(self.num_frames)
        workflow["194"]["inputs"]["fps"] = int(self.fps)

        workflow["131"]["inputs"]["frame_rate"] = int(self.fps)
        workflow["131"]["inputs"]["loop_count"] = int(self.loop_count)
        workflow["131"]["inputs"]["filename_prefix"] = self.filename_prefix
        workflow["131"]["inputs"]["format"] = self.output_format
        workflow["131"]["inputs"]["crf"] = int(self.crf)
        workflow["131"]["inputs"]["pingpong"] = bool(self.pingpong)

        workflow["130"]["inputs"]["enable_vae_tiling"] = bool(self.vae_tiling)

        seed_value = self.seed if self.seed is not None else random.randrange(1 << 48)
        workflow["220"]["inputs"]["seed"] = int(seed_value)
        workflow["220"]["inputs"]["steps"] = int(self.steps)
        workflow["220"]["inputs"]["cfg"] = float(self.cfg)
        workflow["220"]["inputs"]["shift"] = float(self.shift)

        workflow["134"]["inputs"]["blocks_to_swap"] = int(self.block_swap_blocks)
        workflow["138"]["inputs"]["strength"] = float(self.lora_strength)

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

        if self.workflow_overrides:
            workflow = _merge_override(workflow, self.workflow_overrides)

        payload = copy.deepcopy(_REQUEST_TEMPLATE)
        payload["workflow_json"] = workflow
        payload["request_id"] = self.request_id or uuid.uuid4().hex
        if self.client_id:
            payload["client_id"] = self.client_id

        payload["aws_access_key_id"] = os.environ.get("WAN_AWS_ACCESS_KEY_ID", "")
        payload["aws_secret_access_key"] = os.environ.get("WAN_AWS_SECRET_ACCESS_KEY", "")
        payload["aws_endpoint_url"] = os.environ.get("WAN_AWS_ENDPOINT_URL", "")
        payload["aws_bucket_name"] = os.environ.get("WAN_AWS_BUCKET_NAME", "")
        payload["webhook_url"] = os.environ.get("WAN_WEBHOOK_URL", "")
        payload["webhook_extra_params"] = {}

        return {"input": payload}

    def count_workload(self) -> float:
        resolution_factor = (self.width * self.height) / (864 * 1536)
        frame_factor = self.num_frames / 500.0
        step_factor = max(self.steps / 4.0, 0.25)

        try:
            duration = _parse_time(self.audio_end) - _parse_time(self.audio_start)
        except Exception:
            duration = 0.0

        if self.audio_seconds:
            duration = max(duration, float(self.audio_seconds))
        if duration <= 0:
            duration = self.num_frames / max(self.fps, 1)

        duration_factor = max(duration / 12.0, 0.5)

        workload = 100.0 * resolution_factor * frame_factor * step_factor * duration_factor
        return max(workload, 1.0)