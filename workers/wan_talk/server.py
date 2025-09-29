import logging
import os
from dataclasses import dataclass
from typing import Optional, Type, Union

from aiohttp import web, ClientResponse

from lib.backend import Backend, LogAction
from lib.data_types import EndpointHandler
from lib.server import start_server
from .data_types import WanTalkPayload

# CRITICAL: Point to API Wrapper, not ComfyUI directly
MODEL_SERVER_URL = os.environ.get("MODEL_SERVER_URL", "http://127.0.0.1:8000")

# Wait for this message to indicate API Wrapper is ready
MODEL_SERVER_START_LOG_MSG = "Application startup complete"

# Error messages to watch for
MODEL_SERVER_ERROR_LOG_MSGS = [
    "Failed to connect to ComfyUI",
    "Error processing request",
    "Workflow execution failed",
    "Network error",
]

logging.basicConfig(
    level=logging.DEBUG,
    format="%(asctime)s[%(levelname)-5s] %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
log = logging.getLogger(__file__)


async def _prepare_response(
    request: web.Request,
    model_response: ClientResponse,
) -> Union[web.Response, web.StreamResponse]:
    """Convert API Wrapper response to PyWorker response format"""
    _ = request
    
    if model_response.status != 200:
        log.error(f"API Wrapper returned status {model_response.status}")
        try:
            text = await model_response.text()
            log.error(f"Response body: {text[:500]}")
        except:
            pass
        return web.Response(status=model_response.status)

    try:
        result = await model_response.json()
        log.debug(f"API Wrapper result status: {result.get('status')}")
        return web.json_response(data=result)
    except Exception as e:
        log.error(f"Failed to parse API Wrapper response: {e}")
        return web.Response(status=500, text="Invalid response from generation service")


@dataclass
class WanTalkHandler(EndpointHandler[WanTalkPayload]):

    @property
    def endpoint(self) -> str:
        # Use the sync endpoint from API Wrapper
        return "/generate/sync"

    @property
    def healthcheck_endpoint(self) -> Optional[str]:
        return "/health"

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


# Create handlers
benchmark_handler = WanTalkHandler(benchmark_runs=2, benchmark_words=100)
generate_handler = WanTalkHandler()

# Create backend
backend = Backend(
    model_server_url=MODEL_SERVER_URL,
    model_log_file=os.environ["MODEL_LOG"],
    allow_parallel_requests=False,
    benchmark_handler=benchmark_handler,
    log_actions=[
        (LogAction.ModelLoaded, MODEL_SERVER_START_LOG_MSG),
        (LogAction.Info, "Starting"),
        (LogAction.Info, "Uvicorn running"),
        *[(LogAction.ModelError, msg) for msg in MODEL_SERVER_ERROR_LOG_MSGS],
    ],
)


async def handle_ping(_: web.Request) -> web.Response:
    return web.Response(text="pong")


# Define routes
routes = [
    web.get("/ping", handle_ping),
    web.post("/generate", backend.create_handler(generate_handler)),
]

if __name__ == "__main__":
    log.info(f"Starting WanTalk PyWorker")
    log.info(f"MODEL_SERVER_URL: {MODEL_SERVER_URL}")
    log.info(f"MODEL_LOG: {os.environ.get('MODEL_LOG')}")
    start_server(backend, routes)