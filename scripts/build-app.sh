#!/bin/bash

set -euo pipefail

# SwiftPM 산출물과 고정된 helper를 표준 macOS 앱 번들로 조립한다.
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT_ROOT="${1:-$PROJECT_ROOT/dist}"
APP_BUNDLE="$OUTPUT_ROOT/CodexSwitch.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_HELPERS="$APP_CONTENTS/Helpers"
APP_RESOURCES="$APP_CONTENTS/Resources"
ICONSET_PATH="$PROJECT_ROOT/.build/CodexSwitch.iconset"
TARGET_ARCH="${CODEXSWITCH_ARCH:-$(uname -m)}"
SIGNING_IDENTITY="${CODE_SIGN_IDENTITY:--}"

# 지원 아키텍처와 그에 대응하는 vendored 바이너리를 고정한다.
case "$TARGET_ARCH" in
    arm64)
        PLATFORM_DIRECTORY="darwin-arm64"
        NPM_ARCHIVE_NAME="codex-auth-darwin-arm64-0.2.10.tgz"
        ;;
    x86_64)
        PLATFORM_DIRECTORY="darwin-x86_64"
        NPM_ARCHIVE_NAME="codex-auth-darwin-x64-0.2.10.tgz"
        ;;
    *) echo "Unsupported architecture: $TARGET_ARCH" >&2; exit 1 ;;
esac

VENDOR_ROOT="$PROJECT_ROOT/Vendor/codex-auth"
VENDOR_RELATIVE_PATH="bin/$PLATFORM_DIRECTORY/codex-auth"
VENDOR_BINARY="$VENDOR_ROOT/$VENDOR_RELATIVE_PATH"
CHECKSUM_MANIFEST="$VENDOR_ROOT/SHA256SUMS"
UPSTREAM_MANIFEST="$VENDOR_ROOT/UPSTREAM_SHA256SUMS"
NPM_ARCHIVE="$VENDOR_ROOT/upstream/$NPM_ARCHIVE_NAME"
EXPECTED_HASH="$(awk -v path="$VENDOR_RELATIVE_PATH" '$2 == path { print $1 }' "$CHECKSUM_MANIFEST")"
ACTUAL_HASH="$(shasum -a 256 "$VENDOR_BINARY" | awk '{ print $1 }')"
ARCHIVE_BINARY_HASH="$(tar -xOf "$NPM_ARCHIVE" package/bin/codex-auth | shasum -a 256 | awk '{ print $1 }')"

if [[ -z "$EXPECTED_HASH" || "$ACTUAL_HASH" != "$EXPECTED_HASH" || "$ARCHIVE_BINARY_HASH" != "$ACTUAL_HASH" ]]; then
    echo "Vendored codex-auth checksum verification failed." >&2
    exit 1
fi
(
    cd "$VENDOR_ROOT"
    shasum -a 256 -c "$UPSTREAM_MANIFEST"
)

# 같은 아키텍처의 release 실행 파일을 만들고 이전 앱 번들은 깨끗이 교체한다.
swift build -c release --arch "$TARGET_ARCH" --package-path "$PROJECT_ROOT"
BUILD_PRODUCTS="$(swift build -c release --arch "$TARGET_ARCH" --package-path "$PROJECT_ROOT" --show-bin-path)"
rm -rf "$APP_BUNDLE" "$ICONSET_PATH"
mkdir -p "$APP_MACOS" "$APP_HELPERS" "$APP_RESOURCES"

cp "$BUILD_PRODUCTS/CodexSwitch" "$APP_MACOS/CodexSwitch"
cp "$PROJECT_ROOT/Resources/Info.plist" "$APP_CONTENTS/Info.plist"
cp "$PROJECT_ROOT/Resources/ThirdPartyNotices.txt" "$APP_RESOURCES/ThirdPartyNotices.txt"
cp "$PROJECT_ROOT/Vendor/codex-auth/source/LICENSE" "$APP_RESOURCES/codex-auth-LICENSE.txt"
cp "$PROJECT_ROOT/Vendor/codex-auth/VERSION" "$APP_RESOURCES/codex-auth-VERSION.txt"
cp "$PROJECT_ROOT/Vendor/codex-auth/SOURCE_COMMIT" "$APP_RESOURCES/codex-auth-SOURCE_COMMIT.txt"
cp "$VENDOR_BINARY" "$APP_HELPERS/codex-auth"
chmod 755 "$APP_MACOS/CodexSwitch" "$APP_HELPERS/codex-auth"

# 코드로 관리하는 원본 아이콘을 icns로 변환한다.
swift "$PROJECT_ROOT/scripts/generate-icon.swift" "$ICONSET_PATH"

# Retina 디스플레이 배율과 무관하게 iconset 파일의 실제 픽셀 크기를 검증한다.
while read -r icon_file expected_pixels; do
    actual_width="$(sips -g pixelWidth "$ICONSET_PATH/$icon_file" | awk '/pixelWidth/ { print $2 }')"
    actual_height="$(sips -g pixelHeight "$ICONSET_PATH/$icon_file" | awk '/pixelHeight/ { print $2 }')"
    if [[ "$actual_width" != "$expected_pixels" || "$actual_height" != "$expected_pixels" ]]; then
        echo "Invalid icon dimensions: $icon_file (${actual_width}x${actual_height})" >&2
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
iconutil -c icns "$ICONSET_PATH" -o "$APP_RESOURCES/CodexSwitch.icns"

# 복사 과정에서 따라온 Finder/provenance 확장 속성을 서명 전에 제거한다.
xattr -cr "$APP_BUNDLE"

# 중첩 helper를 먼저 서명한 뒤 앱 전체를 Hardened Runtime으로 서명한다.
if [[ "$SIGNING_IDENTITY" == "-" ]]; then
    TIMESTAMP_ARGUMENT="--timestamp=none"
else
    TIMESTAMP_ARGUMENT="--timestamp"
fi

codesign --force --options runtime "$TIMESTAMP_ARGUMENT" \
    --sign "$SIGNING_IDENTITY" "$APP_HELPERS/codex-auth"
codesign --force --options runtime "$TIMESTAMP_ARGUMENT" \
    --sign "$SIGNING_IDENTITY" "$APP_BUNDLE"
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"

echo "$APP_BUNDLE"
