#!/bin/bash

set -euo pipefail

# npm, Node, 전역 Codex가 없는 새 사용자 환경을 가짜 공식 로그인으로 재현한다.
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_BUNDLE="${1:-$PROJECT_ROOT/dist/CodexSwitch.app}"
HELPER_EXECUTABLE="$APP_BUNDLE/Contents/Helpers/codex-auth"
FIXTURE_CODEX="$PROJECT_ROOT/Tests/Fixtures/fake-codex"
FIRST_AUTH="$PROJECT_ROOT/Tests/Fixtures/fake-auth.json"
SECOND_AUTH="$PROJECT_ROOT/Tests/Fixtures/fake-auth-second.json"
TEST_ROOT="$(mktemp -d /private/tmp/codexswitch-clean-install.XXXXXX)"
FAKE_BIN="$TEST_ROOT/bin"
CODEX_HOME_PATH="$TEST_ROOT/.codex"

trap 'rm -rf "$TEST_ROOT"' EXIT
mkdir -m 700 "$FAKE_BIN"
cp "$FIXTURE_CODEX" "$FAKE_BIN/codex"
chmod 755 "$FAKE_BIN/codex"

# 첫 연결은 helper 전역 설정이나 자동 전환 서비스를 건드리지 않고 계정을 생성해야 한다.
env -i \
    HOME="$TEST_ROOT" \
    CODEXSWITCH_FAKE_AUTH="$FIRST_AUTH" \
    CODEX_AUTH_SKIP_SERVICE_RECONCILE=1 \
    PATH="$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    "$HELPER_EXECUTABLE" login >/dev/null

test -f "$CODEX_HOME_PATH/accounts/registry.json"
cmp -s "$FIRST_AUTH" "$CODEX_HOME_PATH/auth.json"
grep '"usage": true' "$CODEX_HOME_PATH/accounts/registry.json" >/dev/null
env -i \
    HOME="$TEST_ROOT" \
    CODEX_AUTH_SKIP_SERVICE_RECONCILE=1 \
    PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
    "$HELPER_EXECUTABLE" list --skip-api | grep 'user@example.com' >/dev/null

# 두 번째 연결 뒤에도 첫 계정이 보존되고 정확히 두 계정이 등록돼야 한다.
env -i \
    HOME="$TEST_ROOT" \
    CODEXSWITCH_FAKE_AUTH="$SECOND_AUTH" \
    CODEX_AUTH_SKIP_SERVICE_RECONCILE=1 \
    PATH="$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    "$HELPER_EXECUTABLE" login >/dev/null

test "$(grep -c '"account_key"' "$CODEX_HOME_PATH/accounts/registry.json")" = "2"
env -i \
    HOME="$TEST_ROOT" \
    CODEX_AUTH_SKIP_SERVICE_RECONCILE=1 \
    PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
    "$HELPER_EXECUTABLE" list --skip-api | grep 'second@example.com' >/dev/null

echo "Clean-install helper flow passed."
