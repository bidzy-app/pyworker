import base64
import logging
import os
from dataclasses import dataclass
from pathlib import Path
from typing import Optional, Type, Union

from aiohttp import web, ClientResponse
from anyio import open_file

from lib.backend import Backend, LogAction
from lib.data_types import EndpointHandler
from lib.server import start_server
from .data_types import WanTalkPayload

MODEL_SERVER_URL = os.environ.get("MODEL_SERVER_URL", "http://127.0.0.1:18288")

MODEL_SERVER_START_LOG_MSG = "To see the GUI go to: "
MODEL_SERVER_ERROR_LOG_MSGS = [
    "MetadataIncompleteBuffer",
    "Value not in list:",
]

logging.basicConfig(
    level=logging.DEBUG,
    format="%(asctime)s[%(levelname)-5s] %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
log = logging.getLogger(__file__)


async def _encode_binary(path: str) -> Optional[str]:
    if not path:
        return None
    file_path = Path(path)
    if not file_path.exists():
        return None
    async with await open_file(file_path, mode="rb") as fh:
        data = await fh.read()
    mime = "video/mp4" if file_path.suffix.lower() == ".mp4" else "application/octet-stream"
    return f"data:{mime};base64,{base64.b64encode(data).decode('utf-8')}"


async def _prepare_response(
    request: web.Request,
    model_response: ClientResponse,
) -> Union[web.Response, web.StreamResponse]:
    _ = request
    if model_response.status != 200:
        log.debug("Model returned status %s", model_response.status)
        return web.Response(status=model_response.status)

    payload = await model_response.json()
    output = payload.get("output")
    if not output:
        return web.json_response(data={"error": "workflow returned no output"}, status=422)

    videos = []
    for item in output.get("videos", []):
        encoded = await _encode_binary(item.get("local_path", ""))
        if encoded:
            videos.append({"filename": Path(item["local_path"]).name, "data": encoded})

    images = []
    for item in output.get("images", []):
        encoded = await _encode_binary(item.get("local_path", ""))
        if encoded:
            images.append({"filename": Path(item["local_path"]).name, "data": encoded})

    audios = []
    for item in output.get("audios", []):
        encoded = await _encode_binary(item.get("local_path", ""))
        if encoded:
            audios.append({"filename": Path(item["local_path"]).name, "data": encoded})

    if not any([videos, images, audios]):
        return web.json_response(data={"error": "workflow produced no media outputs"}, status=422)

    return web.json_response(
        data={
            "videos": videos,
            "images": images,
            "audios": audios,
            "meta": payload.get("output_info", {}),
        }
    )


@dataclass
class WanTalkHandler(EndpointHandler[WanTalkPayload]):

    @property
    def endpoint(self) -> str:
        return "/runsync"

    @property
    def healthcheck_endpoint(self) -> Optional[str]:
        return None

    @classmethod
    def payload_cls(cls) -> Type[WanTalkPayload]:
        return WanTalkPayload

    def make_benchmark_payload(self) -> WanTalkPayload:
        return WanTalkPayload.for_test()

    async def generate_client_response(
        self,
        client_request: web.Request,
        model_response: ClientResponse,
    ) -> Union[web.Response, web.StreamResponse]:
        return await _prepare_response(client_request, model_response)


benchmark_handler = WanTalkHandler(benchmark_runs=3, benchmark_words=100)
generate_handler = WanTalkHandler()

backend = Backend(
    model_server_url=MODEL_SERVER_URL,
    model_log_file=os.environ["MODEL_LOG"],
    allow_parallel_requests=False,
    benchmark_handler=benchmark_handler,
    log_actions=[
        (LogAction.ModelLoaded, MODEL_SERVER_START_LOG_MSG),
        (LogAction.Info, "Downloading:"),
        *[(LogAction.ModelError, msg) for msg in MODEL_SERVER_ERROR_LOG_MSGS],
    ],
)


async def handle_ping(_: web.Request) -> web.Response:
    return web.Response(body="pong")


routes = [
    web.get("/ping", handle_ping),
    web.post("/generate", backend.create_handler(generate_handler)),
    web.post("/generate/", backend.create_handler(generate_handler)),
]

if __name__ == "__main__":
    start_server(backend, routes)