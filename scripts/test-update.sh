#!/bin/bash
set -euo pipefail

# 별도 식별자의 임시 앱 두 개로 실제 다운로드, 서명 확인, 설치, 재실행을 끝까지 시험한다.
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SPARKLE_ROOT="$PROJECT_ROOT/.build/artifacts/sparkle/Sparkle"
SIGNING_IDENTITY="${CODE_SIGN_IDENTITY:--}"
TEST_ROOT="$(mktemp -d /private/tmp/codexswitch-update-test.XXXXXX)"
FEED_ROOT="$TEST_ROOT/feed"
INSTALLED_APP="$TEST_ROOT/installed/UpdateFixture.app"
NEXT_APP="$FEED_ROOT/UpdateFixture.app"
TEST_IDENTIFIER="com.bluepin.CodexSwitch.UpdateTest.$(basename "$TEST_ROOT")"
mkdir -p "$FEED_ROOT" "$INSTALLED_APP/Contents/MacOS" "$INSTALLED_APP/Contents/Frameworks"
server_pid=""
app_pid=""
trap 'test -z "$server_pid" || kill "$server_pid" 2>/dev/null || true; test -z "$app_pid" || kill "$app_pid" 2>/dev/null || true' EXIT

# 테스트 피드는 loopback에서만 제공하고 빈 포트를 OS가 고르게 한다.
python3 - "$TEST_ROOT" <<'PY' > "$TEST_ROOT/server.log" 2>&1 &
import functools, http.server, pathlib, sys
root = pathlib.Path(sys.argv[1])
handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=str(root / "feed"))
server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
(root / "port").write_text(str(server.server_port))
server.serve_forever()
PY
server_pid=$!
for _ in {1..100}; do
    test ! -s "$TEST_ROOT/port" || break
    sleep 0.1
done
TEST_PORT="$(cat "$TEST_ROOT/port")"

# 운영 UpdateStore를 그대로 컴파일하되 계정 관리 기능은 테스트 앱에 넣지 않는다.
swiftc -parse-as-library -swift-version 6 -target "$(uname -m)-apple-macosx14.0" \
    -F "$SPARKLE_ROOT/Sparkle.xcframework/macos-arm64_x86_64" \
    -framework Sparkle -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
    "$PROJECT_ROOT/Sources/CodexSwitch/Store/UpdateStore.swift" \
    "$PROJECT_ROOT/Tests/UpdateIntegration/UpdateFixture.swift" \
    -o "$INSTALLED_APP/Contents/MacOS/UpdateFixture"
ditto "$SPARKLE_ROOT/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework" \
    "$INSTALLED_APP/Contents/Frameworks/Sparkle.framework"
python3 - "$PROJECT_ROOT" "$TEST_ROOT" "$TEST_IDENTIFIER" "$TEST_PORT" <<'PY'
import pathlib, plistlib, sys
project, root = map(pathlib.Path, sys.argv[1:3])
info = plistlib.loads((project / "Resources/Info.plist").read_bytes())
info.update(CFBundleIdentifier=sys.argv[3], CFBundleName="UpdateFixture",
            CFBundleDisplayName="UpdateFixture", CFBundleExecutable="UpdateFixture",
            CFBundleVersion="3", CFBundleShortVersionString="0.3.0",
            SUFeedURL=f"http://127.0.0.1:{sys.argv[4]}/appcast.xml",
            NSAppTransportSecurity={"NSAllowsLocalNetworking": True},
            UpdateTestResultDirectory=str(root))
(root / "installed/UpdateFixture.app/Contents/Info.plist").write_bytes(plistlib.dumps(info))
PY
ditto "$INSTALLED_APP" "$NEXT_APP"
/usr/libexec/PlistBuddy -c 'Set :CFBundleVersion 4' "$NEXT_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleShortVersionString 0.3.1' "$NEXT_APP/Contents/Info.plist"

# 인증서가 있으면 배포와 같은 Hardened Runtime으로, 없으면 ad-hoc 테스트로 실행한다.
SIGNING_ARGUMENTS=(--force --sign "$SIGNING_IDENTITY")
if [[ "$SIGNING_IDENTITY" == "-" ]]; then
    SIGNING_ARGUMENTS+=(--timestamp=none)
else
    SIGNING_ARGUMENTS+=(--options runtime --timestamp)
fi
for test_app in "$INSTALLED_APP" "$NEXT_APP"; do
    framework="$test_app/Contents/Frameworks/Sparkle.framework"
    for component in \
        "$framework/Versions/B/XPCServices/Downloader.xpc" \
        "$framework/Versions/B/XPCServices/Installer.xpc" \
        "$framework/Versions/B/Autoupdate" \
        "$framework/Versions/B/Updater.app" \
        "$framework" "$test_app"; do
        codesign "${SIGNING_ARGUMENTS[@]}" "$component"
    done
done
ditto -c -k --norsrc --keepParent "$NEXT_APP" "$FEED_ROOT/update.zip"
APPCAST_ARGUMENTS=(--account CodexSwitch --maximum-deltas 0
    --download-url-prefix "http://127.0.0.1:$TEST_PORT/")
if [[ -n "${SPARKLE_ED_KEY_FILE:-}" ]]; then
    APPCAST_ARGUMENTS+=(--ed-key-file "$SPARKLE_ED_KEY_FILE")
fi
"$SPARKLE_ROOT/bin/generate_appcast" "${APPCAST_ARGUMENTS[@]}" "$FEED_ROOT"

"$INSTALLED_APP/Contents/MacOS/UpdateFixture" > "$TEST_ROOT/app.log" 2>&1 &
app_pid=$!
for _ in {1..120}; do
    if ! kill -0 "$app_pid" 2>/dev/null && [[ ! -f "$TEST_ROOT/clicked" ]]; then
        cat "$TEST_ROOT/app.log"
        echo "Update test app exited before restart: $TEST_ROOT" >&2
        exit 1
    fi
    if [[ -f "$TEST_ROOT/failed" ]]; then
        cat "$TEST_ROOT/failed" "$TEST_ROOT/app.log"
        echo "Update test failed: $TEST_ROOT" >&2
        exit 1
    fi
    if [[ -f "$TEST_ROOT/passed" ]]; then
        test -f "$TEST_ROOT/ready"
        test -f "$TEST_ROOT/clicked"
        test "$(cat "$TEST_ROOT/ready")" = "새로운 업데이트가 있어요! 다시 시작할까요?"
        test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INSTALLED_APP/Contents/Info.plist")" = "4"
        echo "Update download, verification, replacement, and relaunch passed: $TEST_ROOT"
        exit 0
    fi
    sleep 1
done
cat "$TEST_ROOT/app.log"
echo "Update test timed out: $TEST_ROOT" >&2
exit 1
