#!/bin/bash
set -euo pipefail

# 앱 진입점과 설치 후 시작 상태가 실제 메뉴바 표시로 이어지는지 별도 앱으로 검증한다.
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_ROOT="$(mktemp -d /private/tmp/codexswitch-startup-test.XXXXXX)"
TEST_APP="$TEST_ROOT/CodexSwitch.app"
trap 'rm -rf "$TEST_ROOT"' EXIT
mkdir -p "$TEST_APP/Contents/MacOS"
python3 - "$TEST_APP" <<'PY'
import pathlib, plistlib, sys
app = pathlib.Path(sys.argv[1])
info = dict(CFBundleIdentifier="com.bluepin.CodexSwitch.StartupTest." + app.parent.name,
            CFBundleName="CodexSwitch Startup Test", CFBundleExecutable="StartupTest",
            CFBundlePackageType="APPL", LSUIElement=True, CFBundleVersion="1")
(app / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
PY

# DEBUG는 설치 경로 검사만 건너뛰며 설치된 앱과 같은 startRuntime·Scene을 실행한다.
swiftc -parse-as-library -swift-version 6 -DDEBUG -target "$(uname -m)-apple-macosx14.0" \
    "$PROJECT_ROOT/Sources/CodexSwitch/CodexSwitchApp.swift" \
    "$PROJECT_ROOT/Sources/CodexSwitch/Store/AppStartup.swift" \
    "$PROJECT_ROOT/Sources/CodexSwitch/Services/AppInstaller.swift" \
    "$PROJECT_ROOT/Tests/StartupIntegration/StartupFixture.swift" \
    -o "$TEST_APP/Contents/MacOS/StartupTest"
python3 - "$TEST_APP/Contents/MacOS/StartupTest" <<'PY'
import subprocess, sys
result = subprocess.run([sys.argv[1]], capture_output=True, text=True, timeout=15)
print(result.stdout, end="")
print(result.stderr, end="", file=sys.stderr)
if result.returncode != 0 or "PASS: startup displayed a menu bar item on screen" not in result.stdout:
    sys.exit(1)
PY
