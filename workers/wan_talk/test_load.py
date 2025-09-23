from lib.test_utils import test_load_cmd, test_args
from .data_types import WanTalkPayload

WORKER_ENDPOINT = "/wan-talk"

if __name__ == "__main__":
    test_load_cmd(WanTalkPayload, WORKER_ENDPOINT, arg_parser=test_args)