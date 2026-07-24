#!/bin/bash

set -euo pipefail

# 만들어진 앱 번들의 구조, 버전, 실행 가능성, 서명을 한 번에 검증한다.
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_BUNDLE="${1:-$PROJECT_ROOT/dist/CodexSwitch.app}"
APP_EXECUTABLE="$APP_BUNDLE/Contents/MacOS/CodexSwitch"
HELPER_EXECUTABLE="$APP_BUNDLE/Contents/Helpers/codex-auth"
INFO_PLIST="$APP_BUNDLE/Contents/Info.plist"
ICON_FILE="$APP_BUNDLE/Contents/Resources/CodexSwitch.icns"
EXPECTED_ARCH="${CODEXSWITCH_ARCH:-$(uname -m)}"

test -d "$APP_BUNDLE"
test -x "$APP_EXECUTABLE"
test -x "$HELPER_EXECUTABLE"
test -s "$ICON_FILE"
test -f "$APP_BUNDLE/Contents/Resources/ThirdPartyNotices.txt"
test -f "$APP_BUNDLE/Contents/Resources/codex-auth-LICENSE.txt"

# 배포 메타데이터가 앱 식별자와 최소 시스템 요구사항을 유지하는지 확인한다.
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INFO_PLIST")" = "com.bluepin.CodexSwitch"
test "$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$INFO_PLIST")" = "14.0"
test "$(/usr/libexec/PlistBuddy -c 'Print :LSUIElement' "$INFO_PLIST")" = "true"
test "$(/usr/libexec/PlistBuddy -c 'Print :LSApplicationCategoryType' "$INFO_PLIST")" = "public.app-category.developer-tools"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$INFO_PLIST")" = "CodexSwitch"

# icns가 디코딩되고 모든 표준·Retina 슬롯을 정확한 픽셀 크기로 포함하는지 확인한다.
VERIFY_HOME="$(mktemp -d /private/tmp/codexswitch-verify.XXXXXX)"
trap 'rm -rf "$VERIFY_HOME"' EXIT
VERIFY_ICONSET="$VERIFY_HOME/CodexSwitch.iconset"
iconutil -c iconset "$ICON_FILE" -o "$VERIFY_ICONSET"
while read -r icon_file expected_pixels; do
    actual_width="$(sips -g pixelWidth "$VERIFY_ICONSET/$icon_file" | awk '/pixelWidth/ { print $2 }')"
    actual_height="$(sips -g pixelHeight "$VERIFY_ICONSET/$icon_file" | awk '/pixelHeight/ { print $2 }')"
    if [[ "$actual_width" != "$expected_pixels" || "$actual_height" != "$expected_pixels" ]]; then
        echo "Invalid release icon dimensions: $icon_file (${actual_width}x${actual_height})" >&2
        exit 1
    fi
done <<'EOF'
icon_16x16.png 16
icon_16x16@2x.png 32
icon_32x32.png 32
icon_32x32@2x.png 64
icon_128x128.png 128
icon_128x128@2x.png 256
icon_256x256.png 256
icon_256x256@2x.png 512
icon_512x512.png 512
icon_512x512@2x.png 1024
EOF

# 앱과 helper가 같은 대상 아키텍처이며 고정 버전을 실행하는지 확인한다.
lipo "$APP_EXECUTABLE" -verify_arch "$EXPECTED_ARCH"
lipo "$HELPER_EXECUTABLE" -verify_arch "$EXPECTED_ARCH"
test "$($HELPER_EXECUTABLE --version)" = "codex-auth 0.2.10"

# 호스트 ChatGPT 검증은 선택 사항이며 앱 산출물 자체의 합격 조건과 분리한다.
if [[ "${VERIFY_CHATGPT_HOST:-0}" == "1" ]]; then
    CHATGPT_APP="${CHATGPT_APP_PATH:-/Applications/ChatGPT.app}"
    CHATGPT_CODEX="$CHATGPT_APP/Contents/Resources/codex"
    CHATGPT_NODE="$CHATGPT_APP/Contents/Resources/cua_node/bin/node"
    OPENAI_REQUIREMENT='anchor apple generic and certificate leaf[subject.OU] = "2DC432GLL2"'

    test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$CHATGPT_APP/Contents/Info.plist")" = "com.openai.codex"
    codesign --verify --deep --strict --verbose=4 \
        -R="identifier \"com.openai.codex\" and $OPENAI_REQUIREMENT" \
        "$CHATGPT_APP"
    codesign --verify --strict --verbose=4 \
        -R="identifier \"codex\" and $OPENAI_REQUIREMENT" \
        "$CHATGPT_CODEX"
    codesign --verify --strict --verbose=4 \
        -R="identifier \"node\" and $OPENAI_REQUIREMENT" \
        "$CHATGPT_NODE"
    "$CHATGPT_CODEX" --version >/dev/null
    "$CHATGPT_NODE" --version >/dev/null
fi

# 격리된 홈과 시스템 PATH만으로 local-only 목록 명령이 동작해야 한다.
mkdir -m 700 "$VERIFY_HOME/.codex"
env -i \
    HOME="$VERIFY_HOME" \
    CODEX_HOME="$VERIFY_HOME/.codex" \
    CODEX_AUTH_SKIP_SERVICE_RECONCILE=1 \
    PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
    "$HELPER_EXECUTABLE" list --skip-api >/dev/null

# 가짜 브라우저 로그인으로 첫 계정과 두 번째 계정 연결을 Node 없이 검증한다.
"$PROJECT_ROOT/scripts/test-clean-install.sh" "$APP_BUNDLE"

# macOS 기본 awk만 사용해 외부 라이브러리 의존성과 코드 서명 봉인을 검사한다.
if otool -L "$APP_EXECUTABLE" "$HELPER_EXECUTABLE" | awk '
    /^[^[:space:]]/ { next }
    /\/System\/Library\/|\/usr\/lib\// { next }
    /[^[:space:]]/ { unexpected = 1 }
    END { exit unexpected ? 0 : 1 }
'; then
    echo "Unexpected non-system dynamic library dependency." >&2
    exit 1
fi
codesign --verify --deep --strict --verbose=4 "$APP_BUNDLE"

echo "Release verification passed: $APP_BUNDLE"
