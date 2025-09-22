import os
import sys
import random
import dataclasses
from typing import Dict, Any
from functools import cache
from math import ceil

from lib.data_types import ApiPayload, JsonDataException


with open("workers/comfyui/misc/test_prompts.txt", "r") as f:
    test_prompts = f.readlines()

def count_workload() -> float:
    # Always 100.0 where there is a single instance of ComfyUI handling requests
    # Results will indicate % or a job completed per second.  Avoids sub 0.1 sec performance indication
    return 100.0

@dataclasses.dataclass
class ComfyWorkflowData(ApiPayload):
    input: dict

    @classmethod
    def for_test(cls):
        """
        Use the variables available to simulate workflows of the required running time
        Example: SD1.5, simple image gen 10000 steps, 512px x 512px will run for approximately 9 minutes @ ~18 it/s (RTX 4090)
        """
        test_prompt = random.choice(test_prompts).rstrip()
        return cls(
            input={
                "request_id": f"test-{random.randint(1000, 99999)}",
                "modifier": "Text2Image",
                "modifications": {
                    "prompt": test_prompt,
                    "width": os.getenv('BENCHMARK_TEST_WIDTH', 512),
                    "height": os.getenv('BENCHMARK_TEST_HEIGHT', 512),
                    "steps": os.getenv('BENCHMARK_TEST_STEPS', 20),
                    "seed": random.randint(0, sys.maxsize),
                }
            }
        )

    def generate_payload_json(self) -> Dict[str, Any]:
        # input is already a dict, just return it wrapped in the expected structure
        return {"input": self.input}

    def count_workload(self) -> float:
        return count_workload()

    @classmethod
    def from_json_msg(cls, json_msg: Dict[str, Any]) -> "ComfyWorkflowData":
        # Extract required fields
        if "input" not in json_msg:
            raise JsonDataException({"input": "missing parameter"})
        
        return cls(
            input=json_msg["input"]
        )