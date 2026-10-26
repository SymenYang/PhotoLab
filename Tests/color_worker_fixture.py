import json
import sys
import time
from pathlib import Path

request_path = Path(sys.argv[1])
request = json.loads(request_path.read_text())
directory = request_path.parent
if request["prompt"] == "fail":
    (directory / "error.json").write_text(json.dumps({"error": "fixture failure"}))
    sys.exit(1)
if request["prompt"] == "slow":
    time.sleep(30)
time.sleep(0.4)
recipe = {"processVersion": 17, "settings": {"values": {"basic.exposure": 0.3, "basic.contrast": 12}, "whiteBalance": "asShot"}}
(directory / "result.json").write_text(json.dumps({"english": "fixture English", "recipe": recipe, "audit": "fixture", "response": "fixture response"}))
