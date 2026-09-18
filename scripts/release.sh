#!/bin/bash
set -euo pipefail

# 이 Mac의 기존 인증서·공증 프로필로 빌드한 뒤 같은 커밋을 GitHub에 배포한다.
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"
if [[ $# != 1 || ! "$1" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
    echo "Usage: ./scripts/release.sh 0.3.11" >&2
    exit 1
fi
VERSION="$1"
TAG="v$VERSION"
REPOSITORY="heeeete/CodexSwitch"
NOTES="docs/releases/$VERSION.md"
ARCHIVE="dist/CodexSwitch-$VERSION-macos-arm64.zip"

# 커밋되지 않은 앱 코드나 설명을 실수로 배포하지 않는다. output/ 같은 참고 파일은 무관하다.
[[ "$(git branch --show-current)" == "main" ]] || { echo "main에서 실행해 주세요." >&2; exit 1; }
git diff --quiet && git diff --cached --quiet || { echo "변경 사항을 먼저 커밋해 주세요." >&2; exit 1; }
[[ -z "$(git ls-files --others --exclude-standard Sources Resources Tests scripts Vendor Package.swift Package.resolved)" ]] \
    || { echo "추가한 소스·스크립트를 먼저 커밋해 주세요." >&2; exit 1; }
git ls-files --error-unmatch "$NOTES" >/dev/null
[[ -s "$NOTES" ]] || { echo "$NOTES 에 릴리스 설명을 작성해 주세요." >&2; exit 1; }
case "$(git remote get-url origin)" in
    https://github.com/heeeete/CodexSwitch.git|https://github.com/heeeete/CodexSwitch|git@github.com:heeeete/CodexSwitch.git) ;;
    *) echo "origin이 $REPOSITORY 저장소가 아닙니다." >&2; exit 1 ;;
esac
gh auth status --hostname github.com >/dev/null
git fetch origin main --tags
git merge-base --is-ancestor origin/main HEAD || { echo "원격 main 변경을 먼저 가져와 주세요." >&2; exit 1; }
START_SHA="$(git rev-parse HEAD)"
release_state="$(gh release list --repo "$REPOSITORY" --limit 100 --json tagName,isDraft \
    --jq ".[] | select(.tagName == \"$TAG\") | .isDraft")"
[[ "$release_state" != "false" ]] || { echo "$TAG 은 이미 공개되었습니다." >&2; exit 1; }

# 실패한 빌드는 버전 파일만 복원한다. 사용자가 도중에 수정한 파일은 덮어쓰지 않는다.
TEMP_ROOT="$(mktemp -d)"
cp Resources/Info.plist "$TEMP_ROOT/original.plist"
VERSION_SAVED=0
cleanup() {
    status=$?
    if [[ "$VERSION_SAVED" == 0 && -f "$TEMP_ROOT/prepared.plist" ]] \
        && cmp -s Resources/Info.plist "$TEMP_ROOT/prepared.plist"; then
        cp "$TEMP_ROOT/original.plist" Resources/Info.plist
    fi
    rm -rf "$TEMP_ROOT"
    exit "$status"
}
trap cleanup EXIT
python3 scripts/prepare-release.py "$VERSION"
cp Resources/Info.plist "$TEMP_ROOT/prepared.plist"
if git rev-parse --verify --quiet "refs/tags/$TAG" >/dev/null; then
    [[ "$(git rev-list -n 1 "$TAG")" == "$START_SHA" ]] && git diff --quiet -- Resources/Info.plist \
        || { echo "$TAG 태그가 배포할 코드·버전과 다릅니다." >&2; exit 1; }
fi

# Actions와 같은 패키징을 재사용하며 공개 배포는 Apple Silicon용으로 고정한다.
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export CODE_SIGN_IDENTITY="${CODE_SIGN_IDENTITY:-Developer ID Application: HUITAE PARK (6YUP32AZ63)}"
export NOTARY_PROFILE="${NOTARY_PROFILE:-CodexSwitch-notary}"
export CODEXSWITCH_ARCH=arm64
[[ "$CODE_SIGN_IDENTITY" != "-" ]] || { echo "공개 배포에는 Developer ID 서명이 필요합니다." >&2; exit 1; }
python3 scripts/test-prepare-release.py
./scripts/package-release.sh
mkdir -p dist/local-test
rm -rf dist/local-test/CodexSwitch.app
mv dist/CodexSwitch.app dist/local-test/CodexSwitch.app

# 빌드 도중 바뀐 코드를 같은 릴리스에 섞지 않고, 버전 커밋과 태그를 원자적으로 push한다.
[[ "$(git rev-parse HEAD)" == "$START_SHA" ]] && cmp -s Resources/Info.plist "$TEMP_ROOT/prepared.plist" \
    && git diff --quiet -- . ':!Resources/Info.plist' && git diff --cached --quiet \
    || { echo "빌드 중 작업 파일이나 커밋이 변경되었습니다. 다시 실행해 주세요." >&2; exit 1; }
if ! git diff --quiet -- Resources/Info.plist; then
    git add Resources/Info.plist
    git commit -m "chore: release $TAG" \
        -m $'## Summary\n\n공개 버전과 내부 빌드 번호를 검증된 배포 산출물에 맞춰 갱신.\n\n- 앱 버전과 릴리스 태그 일치'
fi
VERSION_SAVED=1
if ! git rev-parse --verify --quiet "refs/tags/$TAG" >/dev/null; then
    git tag "$TAG"
fi
git push --atomic origin HEAD:refs/heads/main "refs/tags/$TAG"

# ZIP·피드를 초안에 올리고 원격 파일이 원본과 일치할 때만 최신 릴리스로 공개한다.
if [[ "$release_state" != "true" ]]; then
    gh release create "$TAG" --repo "$REPOSITORY" --verify-tag --draft \
        --title "CodexSwitch $VERSION" --notes-file "$NOTES"
fi
gh release edit "$TAG" --repo "$REPOSITORY" --notes-file "$NOTES"
gh release upload "$TAG" --repo "$REPOSITORY" "$ARCHIVE" dist/appcast.xml --clobber
gh release download "$TAG" --repo "$REPOSITORY" --pattern "$(basename "$ARCHIVE")" \
    --pattern appcast.xml --dir "$TEMP_ROOT"
cmp "$ARCHIVE" "$TEMP_ROOT/$(basename "$ARCHIVE")"
cmp dist/appcast.xml "$TEMP_ROOT/appcast.xml"
gh release edit "$TAG" --repo "$REPOSITORY" --draft=false --latest
gh release view "$TAG" --repo "$REPOSITORY" --json url --jq .url
