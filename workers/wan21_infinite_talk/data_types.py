import os, io, base64, uuid, dataclasses, inspect, json
from typing import Dict, Any, Optional
from urllib.request import urlopen
from lib.data_types import ApiPayload, JsonDataException

# Нормализация стоимости (можно подкрутить без перекомпиляции)
WAN_BASE_WIDTH = int(os.getenv("WAN_BASE_WIDTH", "864"))
WAN_BASE_HEIGHT = int(os.getenv("WAN_BASE_HEIGHT", "1536"))
WAN_BASE_FRAMES = int(os.getenv("WAN_BASE_FRAMES", "500"))
WAN_BASE_STEPS = int(os.getenv("WAN_BASE_STEPS", "4"))
WAN_COST_SCALE = float(os.getenv("WAN_COST_SCALE", "100.0"))

# Куда сохранять временные входные файлы для ComfyUI (общая FS)
COMFY_INPUT_DIR = os.getenv("COMFY_INPUT_DIR", "/workspace/comfy_inputs")

def _ensure_dir(p: str):
    os.makedirs(p, exist_ok=True)

def _load_bytes_from_ref(ref: str) -> bytes:
    # ref может быть data:*;base64, http(s)://... или просто base64 без префикса
    if not ref:
        return b""
    if ref.startswith("data:"):
        header, b64 = ref.split(",", 1)
        return base64.b64decode(b64)
    if ref.startswith("http://") or ref.startswith("https://"):
        with urlopen(ref) as r:
            return r.read()
    # иначе пробуем как base64
    return base64.b64decode(ref)

def _write_temp(ext: str, data: bytes) -> str:
    _ensure_dir(COMFY_INPUT_DIR)
    name = f"{uuid.uuid4().hex}{ext}"
    path = os.path.join(COMFY_INPUT_DIR, name)
    with open(path, "wb") as f:
        f.write(data)
    return path

@dataclasses.dataclass
class Wan21Payload(ApiPayload):
    # входные поля API вашего воркера
    prompt: str = "A woman talking"
    negative_prompt: str = ""
    width: int = 360
    height: int = 360
    fps: int = 25
    num_frames: int = 500
    steps: int = 4
    seed: int = 123456789
    # входные медиа
    image: Optional[str] = None   # base64|data:|url
    audio: Optional[str] = None   # base64|data:|url
    # доп. опции видео вывода
    crf: int = 19
    loop_count: int = 0
    filename_prefix: str = "WanVideo2_1_multitalk"

    # внутренние: пути до временных файлов
    _image_path: Optional[str] = None
    _audio_path: Optional[str] = None

    @classmethod
    def for_test(cls) -> "Wan21Payload":
        return cls()

    def _prepare_io_files(self) -> None:
        if self.image:
            img_bytes = _load_bytes_from_ref(self.image)
            self._image_path = _write_temp(".png", img_bytes)
        if self.audio:
            aud_bytes = _load_bytes_from_ref(self.audio)
            # под ваш AudioCrop/LoadAudio ожидается wav/mp3. Лучше предоставить wav/mp3.
            self._audio_path = _write_temp(".wav", aud_bytes)

    def generate_payload_json(self) -> Dict[str, Any]:
        # Подготовим файлы и соберём workflow как в вашем примере с подстановками
        self._prepare_io_files()

        # ваш workflow (укороченный набросок: возьмём предоставленный JSON как объект)
        # ВАЖНО: заменим ноды LoadImage/LoadAudio на пути self._image_path / self._audio_path
        workflow = {
  "120": {
    "inputs": {
      "model": "Wan2_1-InfiniTetalk-Single_fp16.safetensors"
    },
    "class_type": "MultiTalkModelLoader",
    "_meta": {
      "title": "Multi/InfiniteTalk Model Loader"
    }
  },
  "122": {
    "inputs": {
      "model": "Wan2_1-I2V-14B-480P_fp8_e4m3fn.safetensors",
      "base_precision": "fp16",
      "quantization": "disabled",
      "load_device": "offload_device",
      "attention_mode": "sdpa",
      "block_swap_args": [
        "134",
        0
      ],
      "lora": [
        "138",
        0
      ],
      "multitalk_model": [
        "120",
        0
      ]
    },
    "class_type": "WanVideoModelLoader",
    "_meta": {
      "title": "WanVideo Model Loader"
    }
  },
  "125": {
    "inputs": {
      "audioUI": ""
    },
    "class_type": "LoadAudio",
    "_meta": {
      "title": "LoadAudio"
    }
  },
  "129": {
    "inputs": {
      "model_name": "Wan2_1_VAE_bf16.safetensors",
      "precision": "bf16"
    },
    "class_type": "WanVideoVAELoader",
    "_meta": {
      "title": "WanVideo VAE Loader"
    }
  },
  "130": {
    "inputs": {
      "enable_vae_tiling": false,
      "tile_x": 272,
      "tile_y": 272,
      "tile_stride_x": 144,
      "tile_stride_y": 128,
      "normalization": "default",
      "vae": [
        "129",
        0
      ],
      "samples": [
        "220",
        0
      ]
    },
    "class_type": "WanVideoDecode",
    "_meta": {
      "title": "WanVideo Decode"
    }
  },
  "131": {
    "inputs": {
      "frame_rate": 25,
      "loop_count": 0,
      "filename_prefix": "WanVideo2_1_multitalk",
      "format": "video/h264-mp4",
      "pix_fmt": "yuv420p",
      "crf": 19,
      "save_metadata": true,
      "trim_to_audio": true,
      "pingpong": false,
      "save_output": true,
      "images": [
        "130",
        0
      ],
      "audio": [
        "194",
        1
      ]
    },
    "class_type": "VHS_VideoCombine",
    "_meta": {
      "title": "Video Combine 🎥🅥🅗🅢"
    }
  },
  "134": {
    "inputs": {
      "blocks_to_swap": 20,
      "offload_img_emb": false,
      "offload_txt_emb": false,
      "use_non_blocking": true,
      "vace_blocks_to_swap": 0,
      "prefetch_blocks": 0,
      "block_swap_debug": false
    },
    "class_type": "WanVideoBlockSwap",
    "_meta": {
      "title": "WanVideo Block Swap"
    }
  },
  "135": {
    "inputs": {
      "positive_prompt": "A woman talking",
      "negative_prompt": "bright tones, overexposed, static, blurred details, subtitles, style, works, paintings, images, static, overall gray, worst quality, low quality, JPEG compression residue, ugly, incomplete, extra fingers, poorly drawn hands, poorly drawn faces, deformed, disfigured, misshapen limbs, fused fingers, still picture, messy background, three legs, many people in the background, walking backwards",
      "force_offload": true,
      "use_disk_cache": false,
      "device": "gpu",
      "t5": [
        "136",
        0
      ]
    },
    "class_type": "WanVideoTextEncode",
    "_meta": {
      "title": "WanVideo TextEncode"
    }
  },
  "136": {
    "inputs": {
      "model_name": "umt5-xxl-enc-fp8_e4m3fn.safetensors",
      "precision": "bf16",
      "load_device": "offload_device",
      "quantization": "disabled"
    },
    "class_type": "LoadWanVideoT5TextEncoder",
    "_meta": {
      "title": "WanVideo T5 Text Encoder Loader"
    }
  },
  "137": {
    "inputs": {
      "model": "TencentGameMate/chinese-wav2vec2-base",
      "base_precision": "fp16",
      "load_device": "main_device"
    },
    "class_type": "DownloadAndLoadWav2VecModel",
    "_meta": {
      "title": "(Down)load Wav2Vec Model"
    }
  },
  "138": {
    "inputs": {
      "lora": "Wan21_I2V_14B_lightx2v_cfg_step_distill_lora_rank64.safetensors",
      "strength": 0.8000000000000002,
      "low_mem_load": false,
      "merge_loras": true
    },
    "class_type": "WanVideoLoraSelect",
    "_meta": {
      "title": "WanVideo Lora Select"
    }
  },
  "159": {
    "inputs": {
      "start_time": "0:00",
      "end_time": "12",
      "audio": [
        "125",
        0
      ]
    },
    "class_type": "AudioCrop",
    "_meta": {
      "title": "AudioCrop"
    }
  },
  "170": {
    "inputs": {
      "chunk_fade_shape": "linear",
      "chunk_length": 12,
      "chunk_overlap": 0.1,
      "audio": [
        "159",
        0
      ]
    },
    "class_type": "AudioSeparation",
    "_meta": {
      "title": "AudioSeparation"
    }
  },
  "171": {
    "inputs": {
      "width": [
        "235",
        0
      ],
      "height": [
        "236",
        0
      ],
      "upscale_method": "lanczos",
      "keep_proportion": "crop",
      "pad_color": "0, 0, 0",
      "crop_position": "center",
      "divisible_by": 2,
      "device": "cpu",
      "image": [
        "245",
        0
      ]
    },
    "class_type": "ImageResizeKJv2",
    "_meta": {
      "title": "Resize Image v2"
    }
  },
  "173": {
    "inputs": {
      "clip_name": "clip_vision_h.safetensors"
    },
    "class_type": "CLIPVisionLoader",
    "_meta": {
      "title": "Load CLIP Vision"
    }
  },
  "192": {
    "inputs": {
      "width": 864,
      "height": 1536,
      "frame_window_size": 81,
      "motion_frame": 9,
      "force_offload": false,
      "colormatch": "disabled",
      "tiled_vae": false,
      "mode": "infinitetalk",
      "vae": [
        "129",
        0
      ],
      "start_image": [
        "171",
        0
      ],
      "clip_embeds": [
        "193",
        0
      ]
    },
    "class_type": "WanVideoImageToVideoMultiTalk",
    "_meta": {
      "title": "WanVideo Long I2V Multi/InfiniteTalk"
    }
  },
  "193": {
    "inputs": {
      "strength_1": 1,
      "strength_2": 1,
      "crop": "center",
      "combine_embeds": "average",
      "force_offload": true,
      "tiles": 0,
      "ratio": 0.5000000000000001,
      "clip_vision": [
        "173",
        0
      ],
      "image_1": [
        "171",
        0
      ]
    },
    "class_type": "WanVideoClipVisionEncode",
    "_meta": {
      "title": "WanVideo ClipVision Encode"
    }
  },
  "194": {
    "inputs": {
      "normalize_loudness": true,
      "num_frames": 500,
      "fps": 25,
      "audio_scale": 1,
      "audio_cfg_scale": 1,
      "multi_audio_type": "para",
      "wav2vec_model": [
        "137",
        0
      ],
      "audio_1": [
        "170",
        3
      ]
    },
    "class_type": "MultiTalkWav2VecEmbeds",
    "_meta": {
      "title": "Multi/InfiniteTalk Wav2vec2 Embeds"
    }
  },
  "220": {
    "inputs": {
      "steps": 4,
      "cfg": 1.0000000000000002,
      "shift": 8.000000000000002,
      "seed": 936718434218980,
      "force_offload": true,
      "scheduler": "flowmatch_distill",
      "riflex_freq_index": 0,
      "denoise_strength": 1,
      "batched_cfg": false,
      "rope_function": "comfy",
      "start_step": 0,
      "end_step": -1,
      "add_noise_to_samples": false,
      "model": [
        "122",
        0
      ],
      "image_embeds": [
        "192",
        0
      ],
      "text_embeds": [
        "135",
        0
      ],
      "multitalk_embeds": [
        "194",
        0
      ]
    },
    "class_type": "WanVideoSampler",
    "_meta": {
      "title": "WanVideo Sampler"
    }
  },
  "235": {
    "inputs": {
      "value": 864
    },
    "class_type": "INTConstant",
    "_meta": {
      "title": "width"
    }
  },
  "236": {
    "inputs": {
      "value": 1536
    },
    "class_type": "INTConstant",
    "_meta": {
      "title": "height"
    }
  },
  "245": {
    "inputs": {
      "image": "ComfyUI_00040_.png"
    },
    "class_type": "LoadImage",
    "_meta": {
      "title": "Load Image"
    }
  }
}  # ВСТАВЬТЕ ПОЛНЫЙ JSON ИЗ ВОПРОСА БЕЗ ИЗМЕНЕНИЙ

        # Точечные подстановки значений, соответствующих вашим нодам:
        # width/height в INTConstant
        workflow["235"]["inputs"]["value"] = int(self.width)
        workflow["236"]["inputs"]["value"] = int(self.height)
        # LoadImage
        if self._image_path:
            workflow["245"]["inputs"]["image"] = self._image_path
        # LoadAudio + AudioCrop + AudioSeparation
        if self._audio_path:
            workflow["125"]["inputs"]["audioUI"] = self._audio_path
            # при необходимости задайте crop
            # workflow["159"]["inputs"]["start_time"] = "0:00"
            # workflow["159"]["inputs"]["end_time"] = str(int(self.num_frames / self.fps))

        # Промпты/семена/шаги/видео параметры
        workflow["135"]["inputs"]["positive_prompt"] = self.prompt
        workflow["135"]["inputs"]["negative_prompt"] = self.negative_prompt
        workflow["220"]["inputs"]["steps"] = int(self.steps)
        workflow["220"]["inputs"]["seed"] = int(self.seed)
        # Комбайн видео
        workflow["131"]["inputs"]["frame_rate"] = int(self.fps)
        workflow["131"]["inputs"]["loop_count"] = int(self.loop_count)
        workflow["131"]["inputs"]["filename_prefix"] = self.filename_prefix
        workflow["131"]["inputs"]["crf"] = int(self.crf)
        # MultiTalk аудио → кадры
        workflow["194"]["inputs"]["num_frames"] = int(self.num_frames)
        workflow["194"]["inputs"]["fps"] = int(self.fps)

        # Оборачиваем как ожидает ComfyUI API Wrapper
        return {
            "input": {
                "handler": "RawWorkflow",
                "workflow_json": workflow,
                # Рекомендуется настроить выгрузку в S3 через ENV или прямо здесь:
                # "s3": {...}, "webhook": {...}
            }
        }

    def count_workload(self) -> float:
        area = max(1, self.width * self.height)
        base_area = max(1, WAN_BASE_WIDTH * WAN_BASE_HEIGHT)
        frames = max(1, self.num_frames)
        cost = WAN_COST_SCALE * (area / base_area) * (frames / WAN_BASE_FRAMES) * (max(1, self.steps) / WAN_BASE_STEPS)
        return float(cost)

    @classmethod
    def from_json_msg(cls, json_msg: Dict[str, Any]) -> "Wan21Payload":
        # простая валидация обязательных полей
        errors = {}
        for name, param in inspect.signature(cls).parameters.items():
            if name.startswith("_"):
                continue
            # image/audio/negative_prompt необязательны
        # Можно добавить детальные проверки типов/диапазонов
        return cls(**{k: v for k, v in json_msg.items() if k in inspect.signature(cls).parameters})