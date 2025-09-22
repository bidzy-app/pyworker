from lib.test_utils import test_load_cmd, test_args
from .data_types import ComfyWorkflowData

WORKER_ENDPOINT = "/generate/sync"


if __name__ == "__main__":
    test_load_cmd(ComfyWorkflowData, WORKER_ENDPOINT, arg_parser=test_args)
