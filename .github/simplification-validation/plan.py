"""Expose exact source identities to the validation-only Actions workflow."""
import json
import os
from pathlib import Path
import re

config = json.loads(Path(__file__).with_name("sources.json").read_text())
assert config["mode"] in ("documentation", "validate")
required = ("base", "reference7", "candidate", "reference8")
if config["mode"] == "validate":
    required += ("stack",)
for key in required:
    assert re.fullmatch(r"[0-9a-f]{40}", config[key]), (key, config[key])
with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as stream:
    for key, value in config.items():
        stream.write(f"{key}={value}\n")
print(json.dumps(config, indent=2))
