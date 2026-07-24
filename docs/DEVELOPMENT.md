# CodexSwitch 개발 가이드

사용자 설치와 사용법은 프로젝트 [README](../README.md)를 참고하세요. 이 문서는
소스에서 앱을 빌드하고 내부 동작을 확인하려는 개발자를 위한 안내입니다.

## 개발 환경

- macOS 14 이상
- Xcode 16 이상
- Swift 6

Node.js나 전역 `codex-auth` 설치는 필요하지 않습니다. 빌드에는 저장소에 고정된
네이티브 `codex-auth` 바이너리를 사용합니다.

## 로컬 빌드 및 실행

```bash
cd ~/CodexSwitch
swift test
./scripts/build-app.sh
open dist/CodexSwitch.app
```

`build-app.sh`는 현재 Mac 아키텍처에 맞는 Swift 실행 파일과 `codex-auth` helper,
앱 아이콘, 오픈소스 고지를 표준 macOS 앱 번들로 조립합니다. 기본 빌드는 로컬
테스트용 ad-hoc 서명을 사용합니다.

다른 아키텍처를 명시하려면 `CODEXSWITCH_ARCH`를 설정합니다.

```bash
CODEXSWITCH_ARCH=arm64 ./scripts/build-app.sh
```

## 테스트

Swift 테스트 전체를 실행합니다.

```bash
swift test
```

빌드된 앱의 구조, 아키텍처, 아이콘, helper 버전, 외부 라이브러리 의존성, 코드
서명을 검사합니다. 이 검증에는 npm과 Node.js가 없는 새 사용자 환경의 계정 추가
흐름도 포함됩니다.

```bash
./scripts/build-app.sh
./scripts/verify-release.sh dist/CodexSwitch.app
```

새 사용자 환경만 따로 확인할 수도 있습니다.

```bash
./scripts/test-clean-install.sh dist/CodexSwitch.app
```

## 프로젝트 구조

| 경로 | 역할 |
| --- | --- |
| `Sources/CodexSwitch` | SwiftUI 메뉴와 계정 관리 로직 |
| `Resources` | 앱 메타데이터와 번들에 포함할 고지 |
| `Tests` | 모델·서비스·스토어·레이아웃 테스트와 가짜 인증 fixture |
| `Vendor/codex-auth` | 고정된 helper, upstream 소스·아카이브·해시 |
| `scripts/build-app.sh` | SwiftPM 산출물을 macOS 앱 번들로 조립 |
| `scripts/verify-release.sh` | 앱 구조와 독립 실행 조건 검증 |
| `scripts/package-release.sh` | 테스트부터 서명·공증·ZIP 생성까지 처리 |

## 계정 데이터와 전환

- UI는 `~/.codex/accounts/registry.json`의 계정 메타데이터만 읽어 표시합니다.
- 계정 선택은 화면 순서나 이메일 일부가 아니라 정확한 `account_key`를 사용합니다.
- 계정을 바꾸기 전에 현재 인증정보를 스냅샷에 동기화합니다.
- 선택한 스냅샷은 임시 파일을 거쳐 `auth.json`에 원자적으로 적용합니다.
- 기존 `auth.json`과 registry는 변경 전에 최대 5개까지 백업합니다.
- 인증 스냅샷은 `~/.codex/accounts` 아래에서 `codex-auth`가 관리합니다.

## 계정 추가와 제거

계정 추가는 실제 `~/.codex`와 분리한 임시 `CODEX_HOME`에서 로그인을 진행합니다.
로그인이 끝나면 새 스냅샷만 가져오고 기존 활성 계정은 유지합니다. 임시 로그인
폴더는 성공·실패·취소 여부와 관계없이 제거합니다.

비활성 계정은 실행 중인 ChatGPT를 건드리지 않고 제거합니다. 활성 계정을
제거하면 남은 계정 중 하나로 전환하고, 마지막 계정을 제거하면 이 Mac의 Codex
인증만 해제합니다.

## Codex 실행 파일 선택과 검증

새 계정 로그인에는 설치된 공식 Codex CLI를 먼저 사용합니다. CLI가 없으면
ChatGPT 앱과 내부 Codex 실행 파일이 OpenAI Team ID와 코드 식별자 조건을
충족하는지 검증한 뒤 사용합니다. 서명 검증에 실패한 앱은 fallback 대상에서
제외합니다.

CodexSwitch는 앱에 포함된 helper만 실행하며 전역 npm 설치본으로 fallback하지
않습니다. 계정 로그인 후 `codex-auth`의 선택적 팀 메타데이터 조회도 막습니다.
기존 helper의 전역 API 설정값은 바꾸지 않습니다.

## 고정된 codex-auth 의존성

- upstream: [Loongphy/codex-auth](https://github.com/Loongphy/codex-auth)
- 버전: `0.2.10`
- source commit: `0642f6fa16df2941afe42f8ee5f9ead2d8595a9e`
- 전체 upstream 소스: `Vendor/codex-auth/source`
- macOS 바이너리와 해시: `Vendor/codex-auth/bin`, `SHA256SUMS`
- 원본 GitHub/npm 아카이브와 무결성 정보: `Vendor/codex-auth/upstream`,
  `NPM_PROVENANCE.json`, `UPSTREAM_SHA256SUMS`

`build-app.sh`는 바이너리가 `SHA256SUMS`와 일치하고 npm 아카이브 내부
바이너리와 같은지 확인합니다. upstream 아카이브도 별도 manifest로 검증합니다.
어느 하나라도 다르면 빌드를 중단합니다.

라이선스 전문과 출처는 [THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md)에
정리되어 있습니다.

## 보안 경계

기본 사용량 조회는 비공개 ChatGPT API를 호출하지 않습니다. 실험적 API 조회는
사용자가 명시적으로 동의했을 때만 `--api`를 전달하며, 기본 모드는 `--skip-api`를
사용합니다.

인증 파일은 비밀번호처럼 취급해야 합니다. 실제 `auth.json`, registry, 계정
스냅샷을 저장소나 이슈에 첨부하지 마세요. CodexSwitch가 계정을 변경하거나
제거하는 동안 별도의 `codex-auth` 명령도 동시에 실행하지 마세요.
