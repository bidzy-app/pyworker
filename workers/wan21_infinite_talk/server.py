import os, logging, dataclasses, base64, json
from typing import Optional, Union, Type, List
from aiohttp import web, ClientResponse
from anyio import open_file

from lib.backend import Backend, LogAction
from lib.data_types import EndpointHandler
from lib.server import start_server
from .data_types import Wan21Payload

MODEL_SERVER_URL = os.getenv("MODEL_SERVER_URL", "http://127.0.0.1:18288")
MODEL_SERVER_START_LOG_MSG = "To see the GUI go to: "
MODEL_SERVER_ERROR_LOG_MSGS = ["MetadataIncompleteBuffer", "Value not in list: "]

logging.basicConfig(level=logging.DEBUG, format="%(asctime)s[%(levelname)-5s] %(message)s", datefmt="%Y-%m-%d %H:%M:%S")
log = logging.getLogger(__file__)

async def _send_raw(client_request: web.Request, model_response: ClientResponse) -> Union[web.Response, web.StreamResponse]:
    # Прозрачно проксируем ответ от API Wrapper
    content = await model_response.read()
    return web.Response(body=content, status=model_response.status, content_type=model_response.content_type)

async def _send_video_or_json(client_request: web.Request, model_response: ClientResponse) -> Union[web.Response, web.StreamResponse]:
    if model_response.status != 200:
        return web.Response(status=model_response.status)
    res = await model_response.json()
    # API Wrapper обычно возвращает {"output": {"images": [...]}}, но для видео плагины пишут "videos" или "files"
    output = res.get("output", {})
    videos: List[dict] = output.get("videos") or output.get("files") or []
    images: List[dict] = output.get("images") or []
    # Если настроен S3, Wrapper вернёт url’ы — просто возвращаем JSON как есть
    if any("url" in f for f in videos + images):
        return web.json_response(res)
    # Иначе читаем локальные пути
    def _collect_paths(entries):
        paths = []
        for e in entries:
            p = e.get("local_path") or e.get("path")
            if p: paths.append(p)
        return paths
    video_paths = _collect_paths(videos)
    image_paths = _collect_paths(images)

    if video_paths:
        # Вернём base64 одного результата (или массив — по пожеланию)
        items = []
        for vp in video_paths:
            async with await open_file(vp, mode="rb") as f:
                b = await f.read()
            items.append(f"data:video/mp4;base64,{base64.b64encode(b).decode('utf-8')}")
        return web.json_response({"videos": items})
    if image_paths:
        items = []
        for ip in image_paths:
            async with await open_file(ip, mode="rb") as f:
                b = await f.read()
            items.append(f"data:image/png;base64,{base64.b64encode(b).decode('utf-8')}")
        return web.json_response({"images": items})
    # fallback: отдать как есть
    return web.json_response(res)

@dataclasses.dataclass
class Wan21Handler(EndpointHandler[Wan21Payload]):

    @property
    def endpoint(self) -> str:
        return "/generate/sync"

    @property
    def healthcheck_endpoint(self) -> Optional[str]:
        return "/health"

    @classmethod
    def payload_cls(cls) -> Type[Wan21Payload]:
        return Wan21Payload

    def make_benchmark_payload(self) -> Wan21Payload:
        # короткий тест: дефолтные поля (500 кадров × 4 шага)
        return Wan21Payload.for_test()

    async def generate_client_response(self, client_request: web.Request, model_response: ClientResponse) -> Union[web.Response, web.StreamResponse]:
        # Если хочется прозрачно: return await _send_raw(client_request, model_response)
        return await _send_video_or_json(client_request, model_response)

backend = Backend(
    model_server_url=MODEL_SERVER_URL,
    model_log_file=os.environ["MODEL_LOG"],
    allow_parallel_requests=False,  # ComfyUI — единичная очередь
    benchmark_handler=Wan21Handler(benchmark_runs=1, benchmark_words=10),
    log_actions=[
        (LogAction.ModelLoaded, MODEL_SERVER_START_LOG_MSG),
        (LogAction.Info, "Downloading:"),
        *[(LogAction.ModelError, e) for e in MODEL_SERVER_ERROR_LOG_MSGS],
    ],
)

async def handle_ping(_):
    return web.Response(body="pong")

routes = [
    web.post("/wan21/infinite_talk", backend.create_handler(Wan21Handler())),
    web.get("/ping", handle_ping),
]

if __name__ == "__main__":
    start_server(backend, routes)