#!/bin/bash
set -euo pipefail

# 운영 서명 검증을 그대로 통과하는 임시 앱을 별도 Applications에 설치하고 재실행한다.
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_ROOT="$(mktemp -d /private/tmp/codexswitch-install-test.XXXXXX)"
SOURCE_APP="$TEST_ROOT/Downloads/CodexSwitch.app"
SIGNING_IDENTITY="${CODE_SIGN_IDENTITY:?Set CODE_SIGN_IDENTITY to a Developer ID Application certificate}"
SIGNING_NOTARY_PROFILE="${NOTARY_PROFILE:?Set NOTARY_PROFILE to a notarytool keychain profile}"
mkdir -p "$SOURCE_APP/Contents/MacOS" "$TEST_ROOT/Applications"
app_pid=""
trap 'test -z "$app_pid" || kill "$app_pid" 2>/dev/null || true' EXIT

swiftc -parse-as-library -swift-version 6 -target "$(uname -m)-apple-macosx14.0" \
    "$PROJECT_ROOT/Sources/CodexSwitch/Services/AppInstaller.swift" \
    "$PROJECT_ROOT/Tests/InstallIntegration/InstallFixture.swift" \
    -o "$SOURCE_APP/Contents/MacOS/InstallFixture"
python3 - "$TEST_ROOT" <<'PY'
import pathlib, plistlib, sys
root = pathlib.Path(sys.argv[1])
info = dict(CFBundleIdentifier="com.bluepin.CodexSwitch.InstallTest." + root.name,
            CFBundleName="InstallFixture", CFBundleExecutable="InstallFixture",
            CFBundleVersion="6", CFBundleShortVersionString="0.3.3",
            CFBundlePackageType="APPL", LSUIElement=True,
            LSMinimumSystemVersion="14.0", InstallationTestRoot=str(root))
(root / "Downloads/CodexSwitch.app/Contents/Info.plist").write_bytes(plistlib.dumps(info))
PY
codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$SOURCE_APP"
# 실제 배포처럼 공증된 앱을 사용해 다운로드 격리와 Gatekeeper가 적용된 재실행을 검증한다.
ditto -c -k --keepParent "$SOURCE_APP" "$TEST_ROOT/InstallFixture.zip"
xcrun notarytool submit "$TEST_ROOT/InstallFixture.zip" --keychain-profile "$SIGNING_NOTARY_PROFILE" --wait
xcrun stapler staple "$SOURCE_APP"
"$SOURCE_APP/Contents/MacOS/InstallFixture" > "$TEST_ROOT/app.log" 2>&1 &
app_pid=$!
for _ in {1..45}; do
    if [[ -f "$TEST_ROOT/failed" ]]; then
        cat "$TEST_ROOT/failed" "$TEST_ROOT/app.log"
        exit 1
    fi
    if [[ -f "$TEST_ROOT/installed" && -f "$TEST_ROOT/relaunched" ]]; then
        # macOS가 /private/tmp를 /tmp로 표준화해도 같은 실제 설치 위치로 판정한다.
        python3 - "$TEST_ROOT" <<'PY'
import pathlib, sys
root = pathlib.Path(sys.argv[1])
assert pathlib.Path((root / "installed").read_text()).resolve() == (root / "Applications/CodexSwitch.app").resolve()
PY
        codesign --verify --deep --strict "$TEST_ROOT/Applications/CodexSwitch.app"
        cmp "$SOURCE_APP/Contents/MacOS/InstallFixture" "$TEST_ROOT/Applications/CodexSwitch.app/Contents/MacOS/InstallFixture"
        # 원본은 다운로드 격리 상태로 남고 설치본은 임시 위치 실행 대상에서 제외되어야 한다.
        [[ "$(security translocate-policy-check "$SOURCE_APP")" == *"Would translocate"* ]]
        [[ "$(security translocate-policy-check "$TEST_ROOT/Applications/CodexSwitch.app")" == *"Would not translocate"* ]]
        echo "Signed app installation and relaunch passed: $TEST_ROOT"
        exit 0
    fi
    sleep 1
done
cat "$TEST_ROOT/app.log"
echo "Installation test timed out: $TEST_ROOT" >&2
exit 1
