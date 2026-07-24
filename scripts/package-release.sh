#!/bin/bash

set -euo pipefail

# 공개 배포는 Developer ID와 공증을 요구하고, 명시적 플래그에서만 로컬 ad-hoc 패키지를 허용한다.
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT_ROOT="${1:-$PROJECT_ROOT/dist}"
SIGNING_IDENTITY="${CODE_SIGN_IDENTITY:--}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
ALLOW_ADHOC="${ALLOW_ADHOC:-0}"
TARGET_ARCH="${CODEXSWITCH_ARCH:-$(uname -m)}"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PROJECT_ROOT/Resources/Info.plist")"
ARCH_LABEL="$(printf '%s' "$TARGET_ARCH" | sed 's/x86_64/intel/')"
PUBLIC_BASENAME="CodexSwitch-$VERSION-macos-$ARCH_LABEL.zip"
ADHOC_BASENAME="CodexSwitch-$VERSION-macos-$ARCH_LABEL-adhoc.zip"
NOTARY_BASENAME="CodexSwitch-$VERSION-notary.zip"

if [[ "$SIGNING_IDENTITY" == "-" && "$ALLOW_ADHOC" != "1" ]]; then
    echo "Set CODE_SIGN_IDENTITY to a Developer ID Application certificate." >&2
    echo "For a local test package only, set ALLOW_ADHOC=1." >&2
    exit 1
fi
if [[ "$SIGNING_IDENTITY" != "-" && -z "$NOTARY_PROFILE" ]]; then
    echo "Set NOTARY_PROFILE to a notarytool keychain profile." >&2
    exit 1
fi

# 기존 릴리스는 staging 검증과 최종 게시가 모두 성공할 때까지 보존한다.
mkdir -p "$OUTPUT_ROOT"

# 같은 파일시스템의 staging에서 전 과정을 마쳐 최종 게시를 원자적인 rename으로 제한한다.
STAGING_ROOT="$(mktemp -d "$OUTPUT_ROOT/.release.XXXXXX")"
PUBLISH_STARTED=0
PUBLISH_COMPLETE=0

# 게시 도중 rename 하나라도 실패하면 이번 실행의 파일을 제거하고 이전 산출물을 복구한다.
cleanup() {
    status=$?
    trap - EXIT
    if [[ "$PUBLISH_STARTED" == "1" && "$PUBLISH_COMPLETE" != "1" ]]; then
        set +e
        for name in "${PUBLISH_NAMES[@]}"; do
            target="$OUTPUT_ROOT/$name"
            backup="$BACKUP_ROOT/$name"
            marker="$BACKUP_ROOT/$name.was-present"
            if [[ -e "$marker" ]]; then
                if [[ -e "$backup" || -L "$backup" ]]; then
                    rm -rf "$target"
                    mv "$backup" "$target"
                fi
            else
                rm -rf "$target"
            fi
        done
    fi
    rm -rf "$STAGING_ROOT"
    exit "$status"
}
trap cleanup EXIT

# 테스트 후 동일 스크립트로 앱을 조립하고 검증한다.
swift test --package-path "$PROJECT_ROOT"
"$PROJECT_ROOT/scripts/build-app.sh" "$STAGING_ROOT"
"$PROJECT_ROOT/scripts/verify-release.sh" "$STAGING_ROOT/CodexSwitch.app"

# 빌드된 버전을 원본 메타데이터와 맞추고 ad-hoc 산출물에는 공개 이름을 절대 재사용하지 않는다.
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$STAGING_ROOT/CodexSwitch.app/Contents/Info.plist")" = "$VERSION"
if [[ "$SIGNING_IDENTITY" == "-" ]]; then
    FINAL_BASENAME="$ADHOC_BASENAME"
else
    FINAL_BASENAME="$PUBLIC_BASENAME"
fi
FINAL_ZIP="$STAGING_ROOT/$FINAL_BASENAME"
NOTARY_ZIP="$STAGING_ROOT/$NOTARY_BASENAME"

# Developer ID 빌드는 업로드용 ZIP을 공증한 뒤 앱에 티켓을 스테이플한다.
if [[ "$SIGNING_IDENTITY" != "-" ]]; then
    ditto -c -k --norsrc --keepParent "$STAGING_ROOT/CodexSwitch.app" "$NOTARY_ZIP"
    xcrun notarytool submit "$NOTARY_ZIP" \
        --keychain-profile "$NOTARY_PROFILE" \
        --wait
    xcrun stapler staple "$STAGING_ROOT/CodexSwitch.app"
    xcrun stapler validate "$STAGING_ROOT/CodexSwitch.app"
    spctl --assess --type execute --verbose=4 "$STAGING_ROOT/CodexSwitch.app"
    rm -f "$NOTARY_ZIP"
fi

# 리소스 포크를 제외해 __MACOSX 항목 없는 ZIP과 dist에서 검증 가능한 체크섬을 만든다.
ditto -c -k --norsrc --keepParent "$STAGING_ROOT/CodexSwitch.app" "$FINAL_ZIP"
unzip -tq "$FINAL_ZIP" >/dev/null
if unzip -Z1 "$FINAL_ZIP" | grep '^__MACOSX/' >/dev/null; then
    echo "Release archive contains forbidden __MACOSX entries." >&2
    exit 1
fi
(
    cd "$STAGING_ROOT"
    shasum -a 256 "$FINAL_BASENAME" > "$FINAL_BASENAME.sha256"
)

# 검증된 앱과 이번 실행에서 선택한 ZIP·체크섬만 백업 후 같은 파일시스템에서 교체한다.
BACKUP_ROOT="$STAGING_ROOT/.previous"
PUBLISH_NAMES=("CodexSwitch.app" "$FINAL_BASENAME" "$FINAL_BASENAME.sha256")
mkdir -p "$BACKUP_ROOT"
for name in "${PUBLISH_NAMES[@]}"; do
    target="$OUTPUT_ROOT/$name"
    if [[ -e "$target" || -L "$target" ]]; then
        touch "$BACKUP_ROOT/$name.was-present"
    fi
done

PUBLISH_STARTED=1
for name in "${PUBLISH_NAMES[@]}"; do
    target="$OUTPUT_ROOT/$name"
    if [[ -e "$target" || -L "$target" ]]; then
        mv "$target" "$BACKUP_ROOT/$name"
    fi
done
mv "$STAGING_ROOT/CodexSwitch.app" "$OUTPUT_ROOT/CodexSwitch.app"
mv "$FINAL_ZIP" "$OUTPUT_ROOT/$FINAL_BASENAME"
mv "$FINAL_ZIP.sha256" "$OUTPUT_ROOT/$FINAL_BASENAME.sha256"
PUBLISH_COMPLETE=1

echo "$OUTPUT_ROOT/$FINAL_BASENAME"
