# CodexSwitch 개발 가이드

사용자 설치와 사용법은 프로젝트 [README](../README.md)를 참고하세요. 이 문서는
소스에서 앱을 빌드하고 내부 동작을 확인하려는 개발자를 위한 안내입니다.

배포 절차와 버전 관리는 [배포 가이드](RELEASING.md), 버전별 공개 설명은
[`docs/releases`](releases)에 작성합니다. 사용자용 README에는 설치·사용법을 유지합니다.

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
open dist/local-test/CodexSwitch.app
```

`build-app.sh`는 현재 Mac 아키텍처에 맞는 Swift 실행 파일과 `codex-auth` helper,
앱 아이콘, 오픈소스 고지를 표준 macOS 앱 번들로 조립합니다. 기본 빌드는 로컬
테스트용 ad-hoc 서명을 사용하며, Team ID가 없는 이 빌드에는 Hardened Runtime을
적용하지 않습니다. 로컬 빌드는 배포용 최적화를 유지하면서 자동 설치와 로그인 항목
등록을 건너뛰고 바로 메뉴바에서 실행됩니다. 로컬 확인용 최신 앱은 `dist/local-test/CodexSwitch.app` 하나만
유지하며 다음 빌드가 같은 경로를 교체합니다. 자동 설치까지 확인할 때는
`CODE_SIGN_IDENTITY`에 Developer ID Application 인증서를 지정합니다.

다른 아키텍처를 명시하려면 `CODEXSWITCH_ARCH`를 설정합니다.

```bash
CODEXSWITCH_ARCH=arm64 ./scripts/build-app.sh
```

## 테스트

Swift 테스트 전체를 실행합니다.

```bash
swift test
```

배포 스크립트는 실제 GitHub 게시나 공증 없이 임시 Git 저장소에서 확인합니다.

```bash
python3 scripts/test-prepare-release.py
python3 scripts/test-release.py
```

빌드된 앱의 구조, 아키텍처, 아이콘, helper 버전, 외부 라이브러리 의존성, 코드
서명을 검사합니다. 이 검증에는 npm과 Node.js가 없는 새 사용자 환경의 계정 추가
흐름도 포함됩니다.

```bash
./scripts/build-app.sh
./scripts/verify-release.sh dist/local-test/CodexSwitch.app
```

새 사용자 환경만 따로 확인할 수도 있습니다.

```bash
./scripts/test-clean-install.sh dist/local-test/CodexSwitch.app
```

## GitHub Actions CI

`CI` 워크플로는 앱 동작에 영향을 주는 파일이 바뀌면 자동으로 실행됩니다.

- `main`을 대상으로 한 Pull Request
- `main`에 반영된 변경
- Actions 화면에서 시작한 수동 실행

CI는 Apple Silicon용 앱을 ad-hoc 서명으로 조립한 뒤 Swift 테스트, 고정된 helper의
무결성, 앱 구조, 아이콘, 아키텍처와 새 사용자 계정 연결 흐름을 확인합니다. PR
코드에는 Apple 서명·공증 Secrets가 전달되지 않습니다.

`main`이나 수동 실행에서는 결과 화면의 **Artifacts**에서 개발용 ZIP과 SHA-256
파일을 받을 수 있습니다. 보관 기간은 7일입니다. 이 ZIP은 다른 Mac에서 기능을
확인하는 용도이며 Developer ID 서명과 Apple 공증을 거친 공개 배포본은 아닙니다.

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
| `scripts/release.sh` | 로컬에서 버전 갱신·패키징·GitHub 게시를 한 번에 실행 |
| `.github/workflows/ci.yml` | PR·main의 테스트와 개발용 앱 생성 |
| `.github/workflows/release.yml` | Developer ID 서명·공증과 GitHub Release 게시 |

메뉴바에는 선택한 탭의 현재 계정 사용량을 그 서비스 아이콘과 함께 표시합니다. 아이콘은 앱에 포함하지
않고 설치된 서비스 앱(`com.openai.codex`의 `chatgptTemplate`, `com.anthropic.claudefordesktop`의
`TrayIconTemplate`)에서 실행 중 한 번 읽습니다. 앱이 없거나 파일 이름이 바뀌면 CodexSwitch 로고를 쓰고,
현재 계정이 없으면 숫자 없이 로고만 표시합니다.

## 계정 데이터와 전환

- UI는 `~/.codex/accounts/registry.json`의 계정 메타데이터와 일반 Codex의 로컬 사용량 기록을 읽어 표시합니다.
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

## Claude 데스크톱

`ProviderAccounts`가 서비스별 `AccountStore`와 마지막 선택 탭을 관리합니다. 인증 동작은
`AccountService`로 분리하고 기존 Codex 인증 경로는 유지합니다. 앱 업데이트와 종료는
두 서비스의 계정 작업이 끝난 뒤에만 실행합니다. 탭 전환과 계정 메뉴는 인증을 바꾸는 작업
(`isAccountOperationBusy`) 중에만 막고, 새로 고침 중에 요청한 계정 작업은 그 조회가 끝난 뒤
이어서 실행합니다. 자동 조회는 다른 작업의 안내를 지우지 않고 자신이 띄운 오류만 다음 성공 때 지웁니다.
Claude를 종료할 때는 쿠키 DB를 쥔 보조 프로세스까지 끝나길 기다리고, Codex는 본 앱 종료만 확인합니다.

`ClaudeAuthService`는 `~/Library/Application Support/Claude/config.json`의 인증 캐시와
계정 UUID, 같은 프로필의 쿠키 파일을 함께 저장·복원합니다. 스냅샷과 메타데이터는
`~/Library/Application Support/CodexSwitch/Claude`에 보관하며 파일 권한은 `0600`입니다.
정상 종료가 확인된 뒤에만 쿠키를 복사하고, 전환 전 복구 기록을 먼저 작성합니다.
실패하거나 이전 작업이 중단되었으면 복구 기록으로 인증과 계정 목록을 되돌립니다.

`ClaudeUsageClient`는 기존 macOS 키체인으로 인증 캐시를 메모리에서 복호화한 뒤
Anthropic의 OAuth 프로필·사용량 주소를 조회합니다. 응답의 계정 UUID를 검증하고
5시간·주간 창을 공통 사용량 모델에 매핑합니다. 요청은 임시 세션을 사용하며 리다이렉트를
거부합니다. 자동 조회에서는 키체인 상호작용을 금지하고, 조회 실패나 요청 제한 시에는
이전 사용량과 조회 시각을 유지합니다. 액세스 토큰 갱신은 Claude 데스크톱이 담당합니다.
Code OAuth가 아직 없는 일반 데스크톱 로그인은 `ClaudeWebClient`가 읽기 전용 쿠키 DB의
세션으로 확인합니다. Chromium 24 이상 쿠키의 도메인 해시와 서버 계정 UUID를 검증한 뒤
`claude.ai`의 계정·조직·사용량 주소를 조회합니다.

사용량의 기본 출처는 Claude 데스크톱이 남기는 `plan-usage-history.json`입니다.
`ClaudeDesktopUsage`가 버전 2 형식의 표본(`org`, `t`, `u.fh`, `u.sd`)을 읽으며 키체인과
네트워크를 쓰지 않습니다. 표본에는 조직만 있으므로 `~/Library/Logs/Claude/main.log`의 계정
로드 기록으로 표본 직전에 열린 계정을 확인하고, 그 시점의 로그가 없으면 `claude-code-sessions`
폴더와 로그를 합쳐 한 계정만 쓰는 조직일 때만 귀속합니다. 여러 계정이 함께 쓰는 조직은 추측하지
않습니다. 쿠키 세션으로 실시간 조회할 때는 같은 로그에서 계정이 마지막으로 연 조직을 먼저 고르고,
서버의 조직 목록에 없으면 채팅 조직을 사용합니다.
두 기간은 따로 변환해 미제공 값과 실제 0%를 구분하고, 표본에 없는 초기화 시각은 만들지 않습니다.
이전 온라인 조회가 알려 준 초기화 시각은 그 기간이 끝나기 전의 표본에만 이어 씁니다.
초기화 시각 없이 기록된 값은 기간 길이(5시간·7일)를 넘기면 표시하지 않습니다.

특정 모델에만 걸린 주간 한도는 사용량 응답의 `limits` 목록에서 `group`이 `weekly`이고
`scope.model.display_name`이 있는 항목(`percent`, `resets_at`)으로 읽어 `UsageSnapshot.scoped`에
둡니다. 데스크톱 기록에는 이 값이 없으므로, 더 새로운 표본을 반영할 때는 초기화 시각이 표본보다
뒤인 값만 이어 쓰고 그 뒤에는 다음 실시간 조회까지 표시하지 않습니다. 메뉴 막대 문구에는 넣지 않고
현재 계정 영역과 계정 목록 문구에만 표시합니다.

Claude 탭을 처음 열 때는 데스크톱 기록만 반영해 목록을 바로 표시하고, 이어서 승인창 없는
실시간 조회를 한 번 실행합니다. 계정별 실시간 조회는 동시에 보내고 결과는 저장된 계정 순서로
반영합니다. 동시 조회는 `TaskGroup` 대신 계정별 `Task`로 실행합니다. Swift 6.4.2의 릴리스
최적화에서 `TaskGroup`이 자식 결과를 돌려주지 않아 배포 빌드에서만 조회 결과가 버려졌기 때문이며,
같은 종류의 문제는 `swift test -c release -Xswiftc -enable-testing -Xswiftc -DDEBUG`로 확인합니다.
한 계정 안에서는 서버가 확인한 계정 UUID를 먼저 검증한 뒤에 사용량을 요청합니다.

온라인 조회는 더 새로운 값이 있을 때만 기록을 대체하며, 실패하면 이전 값과 시각을 유지합니다.
401은 로그아웃, 403은 단계(프로필·조직·사용량)가 있는 접근 거부, 연결 실패, 요청 제한을 서로
구분합니다. 표시할 값이 없는 계정에는 로컬 기록의 상태(없음·미지원 형식·조직 구분 불가·오래됨)와
온라인 실패 원인을 함께 붙여 화면에서 안내합니다. 자동 갱신의 키체인 미승인은 표시할 값이 있으면
오류로 알리지 않습니다. 요청 제한(429)은 이전 값이 그대로 남으므로 현재 계정에 표시할 값이 있으면
수동 갱신에서도 알리지 않습니다. 실패한 단계·상태 코드·오류 종류는 인증값 없이 `NSLog`에 남깁니다.

실시간 조회는 데스크톱이 암호화해 둔 로그인 세션을 사용하는 비공식 경로입니다. 데스크톱 기록을
다시 읽어도 서버의 새 사용량이 생기지는 않으며, 제3자 앱의 Claude.ai 인증정보 사용에는 Anthropic의
[인증 정책](https://code.claude.com/docs/en/legal-and-compliance#authentication-and-credential-use)상
제한이 있습니다. 공식 지원 경로가 확인되기 전까지 실시간 값은 보조 수단으로만 다룹니다.

Claude 테스트는 임시 폴더·가짜 앱 런타임·고정 암호화 벡터·모의 HTTP 응답을 사용합니다.
실제 Claude 설치와 두 계정으로 전환하는 검증은 별도로 필요합니다.

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

사용량 조회는 항상 `--skip-api`로 실행합니다. 앱의 `LocalUsageReader`가 최근 세션에서
`limit_id`가 `codex`인 기록과 모델 구분값이 없던 구형 기록만 선택합니다.
계정 활성화 시각 이전 기록은 제외하고 5시간·주간 창 구성은 원본을 따릅니다.
쿠폰 조회는 별도 GET API를 사용하며 토큰을 프로세스 인자에 전달하지 않습니다.

인증 파일은 비밀번호처럼 취급해야 합니다. 실제 `auth.json`, registry, 계정
스냅샷을 저장소나 이슈에 첨부하지 마세요. CodexSwitch가 계정을 변경하거나
제거하는 동안 별도의 `codex-auth` 명령도 동시에 실행하지 마세요.
