import json
import sys

with open(sys.argv[1], encoding="utf-8") as source:
    devices = json.load(source)["devices"]
minimum = int(sys.argv[2])
choices = []
for runtime, values in devices.items():
    if ".iOS-" not in runtime:
        continue
    version = tuple(int(x) for x in runtime.split(".iOS-")[-1].split("-"))
    if version[0] < minimum:
        continue
    for device in values:
        if device.get("isAvailable") and "iPad" in device["name"]:
            choices.append((version, device["name"], device["udid"]))
if not choices:
    raise SystemExit(f"No available iPad simulator with iOS {minimum}+; install a matching runtime in Xcode.")
print(sorted(choices)[-1][2])
