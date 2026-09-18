#!/usr/bin/env python3
"""실제 버전 파일을 건드리지 않고 버전 증가와 재시도 규칙을 검증한다."""

import importlib.util
import plistlib
import sys
import tempfile
from pathlib import Path

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("prepare_release", Path(__file__).with_name("prepare-release.py"))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

with tempfile.TemporaryDirectory() as directory:
    path = Path(directory) / "Info.plist"
    path.write_bytes(plistlib.dumps({
        "CFBundleShortVersionString": "0.3.10", "CFBundleVersion": "14", "SUPublicEDKey": "unchanged",
    }))
    module.prepare_release(path, "0.3.11")
    assert plistlib.loads(path.read_bytes()) == {
        "CFBundleShortVersionString": "0.3.11", "CFBundleVersion": "15", "SUPublicEDKey": "unchanged",
    }
    prepared = path.read_bytes()
    module.prepare_release(path, "0.3.11")
    assert path.read_bytes() == prepared
    for invalid in ["0.3.9", "0.3.10", "v0.3.12", "0.03.12", "0.3.12\n", "0.3.12; echo bad", ""]:
        try:
            module.prepare_release(path, invalid)
        except ValueError:
            pass
        else:
            raise AssertionError(f"Invalid version accepted: {invalid!r}")
        assert path.read_bytes() == prepared
    module.prepare_release(path, "0.4.0")
    assert plistlib.loads(path.read_bytes())["CFBundleVersion"] == "16"

print("Release version checks passed")
