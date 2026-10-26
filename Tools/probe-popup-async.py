#!/usr/bin/env python3
"""Execute the actual StudyPopup.toggleAI body with deterministic suspended Worker responses.

Uses a mock WorkerClient; does not need SwiftUI, Apple frameworks, credentials or network.
"""
from pathlib import Path
import re
import subprocess
import tempfile
import sys

root = Path(__file__).resolve().parents[1]
text = (root / "Shared/StudyPopup.swift").read_text()
start = text.index("    private func toggleAI() async {")
brace = text.index("{", start)
depth = 0
for end in range(brace, len(text)):
    if text[end] == "{":
        depth += 1
    elif text[end] == "}":
        depth -= 1
        if depth == 0:
            break
else:
    raise RuntimeError("Could not parse toggleAI body")
method = text[start:end + 1].replace("private func", "func", 1)
template = (root / "Tools/popup_async_probe.template").read_text()
assert template.count("__TOGGLE_AI_METHOD__") == 1
with tempfile.TemporaryDirectory(prefix="jplive-popup-probe-") as temp:
    source = Path(temp) / "probe.swift"
    binary = Path(temp) / "probe"
    source.write_text(template.replace("__TOGGLE_AI_METHOD__", method))
    subprocess.run(["swiftc", "-parse-as-library", "-swift-version", "6",
                    "-strict-concurrency=complete", "-warnings-as-errors",
                    str(source), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
