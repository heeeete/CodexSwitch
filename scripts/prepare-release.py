#!/usr/bin/env python3
"""로컬 배포와 Actions에서 공개 버전과 내부 빌드 번호를 함께 갱신한다."""

import plistlib
import re
import subprocess
import sys
from pathlib import Path


def prepare_release(path, version):
    # 숫자 세 자리 버전만 받아 명령 인수와 버전 비교를 단순하게 유지한다.
    if not re.fullmatch(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)", version):
        raise ValueError("버전은 0.3.11과 같은 숫자 세 자리 형식이어야 합니다.")
    info = plistlib.loads(path.read_bytes())
    current = info["CFBundleShortVersionString"]
    build = int(info["CFBundleVersion"])
    if build < 1 or tuple(map(int, version.split("."))) < tuple(map(int, current.split("."))):
        raise ValueError("현재 버전보다 낮게 배포할 수 없으며 빌드 번호는 양수여야 합니다.")

    # 실패 후 같은 버전을 재시도할 때는 빌드 번호를 다시 올리지 않는다.
    if version != current:
        subprocess.run([
            "/usr/libexec/PlistBuddy", "-c", f"Set :CFBundleShortVersionString {version}",
            "-c", f"Set :CFBundleVersion {build + 1}", str(path),
        ], check=True)


if __name__ == "__main__":
    try:
        prepare_release(Path("Resources/Info.plist"), sys.argv[1])
    except (ValueError, IndexError) as error:
        sys.exit(str(error))
