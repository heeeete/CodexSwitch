# CodexSwitch Release 가이드

이 문서는 CodexSwitch 관리자가 배포 파일을 만들 때 사용하는 절차입니다. 일반
사용자는 [README의 설치 안내](../README.ko.md#설치)를 참고하세요.

## 자동화 구성

저장소에는 두 개의 GitHub Actions 워크플로가 있습니다.

| 워크플로 | 실행 시점 | 역할 |
| --- | --- | --- |
| `CI` | PR, `main` 반영, 수동 실행 | 테스트와 ad-hoc 앱 검증 |
| `Release` | 관리자가 Actions 화면에서 실행 | 서명, 공증, ZIP 생성과 Release 게시 |

공개 배포는 `Release` 워크플로 사용을 권장합니다. 로컬 배포 절차는 Actions에
문제가 있거나 서명 과정을 직접 확인해야 할 때 사용할 수 있습니다.

일상적인 배포는 **코드와 릴리스 설명을 main에 push → Actions → Release →
Run workflow → 새 버전 입력**으로 끝납니다. 아래 Secrets 설정은 처음 한 번만
필요하며, 이후에는 GitHub의 Mac에서 빌드하므로 개인 Mac을 켜 둘 필요가 없습니다.

## Actions 최초 설정

### 1. Developer ID 인증서 준비

1. Mac의 **키체인 접근 → 로그인 → 내 인증서**를 엽니다.
2. 기존 배포에 사용한 **Developer ID Application: HUITAE PARK (6YUP32AZ63)**를
   선택합니다. 펼쳤을 때 개인 키가 함께 있어야 합니다.
3. 우클릭 → 내보내기로 `DeveloperIDApplication.p12`를 Downloads에 저장합니다.
   내보내기 암호를 지정합니다. 이 암호는 Apple 계정 암호가 아닙니다.
4. 다음 명령으로 파일을 클립보드에 복사해 `DEVELOPER_ID_APPLICATION_P12_BASE64`에
   붙여넣고, 내보내기 암호는 `DEVELOPER_ID_APPLICATION_P12_PASSWORD`에 등록합니다.

```bash
base64 -i ~/Downloads/DeveloperIDApplication.p12 | pbcopy
```

### 2. App Store Connect Team API Key 준비

1. [App Store Connect](https://appstoreconnect.apple.com/access/integrations/api)에
   로그인하고 **Users and Access → Integrations → App Store Connect API → Team Keys**를 엽니다.
   처음에는 Account Holder가 API 사용 권한을 요청해야 할 수 있습니다.
2. 공증용 Team Key를 생성하고 이름은 `CodexSwitch Actions`, Access는 **Developer**로
   지정합니다. 이 워크플로는 Issuer ID를 사용하는 **Team Key**용입니다.
3. `.p8` 파일을 다운로드하고 화면의 **Key ID**와 **Issuer ID**도 기록합니다.
   `.p8`은 한 번만 다운로드할 수 있습니다.
4. 아래 명령의 파일 이름을 실제 다운로드한 이름으로 바꿔 실행합니다.
   복사된 값은 `APP_STORE_CONNECT_API_KEY_P8_BASE64`, 두 ID는 표의 같은 이름
   Secret에 각각 등록합니다.

생성과 권한에 관한 자세한 내용은 [Apple의 API 키 안내](https://developer.apple.com/help/app-store-connect/get-started/app-store-connect-api/)를 참고하세요.

```bash
base64 -i ~/Downloads/AuthKey_XXXXXXXXXX.p8 | pbcopy
```

### 3. 기존 Sparkle 업데이트 키 준비

새 키를 만들지 않고 **지금 배포에 사용 중인 키**를 내보냅니다. 이 키가 달라지면
이미 설치된 앱이 업데이트를 신뢰하지 못합니다. 프로젝트 폴더에서 실행하세요.

```bash
cd /Users/bluepin/CodexSwitch
umask 077
sparkle_export="$(mktemp -d)"
.build/artifacts/sparkle/Sparkle/bin/generate_keys --account CodexSwitch -x "$sparkle_export/private.key"
pbcopy < "$sparkle_export/private.key"
rm -f "$sparkle_export/private.key"
rmdir "$sparkle_export"
```

복사된 내용을 **추가 Base64 변환 없이** `SPARKLE_PRIVATE_KEY`에 붙여넣습니다.
도구가 없으면 먼저 `swift package resolve`로 Sparkle를 내려받습니다.
키체인 접근 허용 창이 뜨면 기존 업데이트 키의 내보내기인지 확인하고 허용합니다.
Secret 저장 후에는 다른 텍스트를 복사해 클립보드를 비웁니다.

### 4. Actions Secrets 등록

[GitHub Secrets 설정](https://github.com/heeeete/CodexSwitch/settings/secrets/actions)을
열고 **New repository secret**을 누릅니다. 아래 이름을 **Name**, 준비한 값을
**Secret**에 넣고 **Add secret**을 누르는 과정을 여섯 번 반복합니다.

| Secret 이름 | 값 |
| --- | --- |
| `DEVELOPER_ID_APPLICATION_P12_BASE64` | `.p12` 파일을 Base64로 변환한 문자열 |
| `DEVELOPER_ID_APPLICATION_P12_PASSWORD` | `.p12`를 내보낼 때 설정한 암호 |
| `APP_STORE_CONNECT_API_KEY_P8_BASE64` | Team API Key `.p8`의 Base64 문자열 |
| `APP_STORE_CONNECT_API_KEY_ID` | App Store Connect Key ID |
| `APP_STORE_CONNECT_API_KEY_ISSUER_ID` | App Store Connect Issuer ID |
| `SPARKLE_PRIVATE_KEY` | 앱의 `SUPublicEDKey`에 대응하는 Sparkle EdDSA 개인 키 |

인증서와 API Key 파일은 저장소에 올리지 않습니다. 워크플로는 실행할 때마다
임시 키체인을 만들고 작업이 끝나면 삭제합니다.

별도 GitHub PAT나 `GITHUB_TOKEN` Secret은 등록하지 않습니다. GitHub가 실행마다
제공하는 토큰으로 버전 커밋·태그·릴리스를 게시합니다. 로컬 Keychain의
`CodexSwitch-notary` 프로필도 GitHub로 옮길 필요가 없습니다.

Repository secrets는 비공개 저장소를 포함한 모든 현재 GitHub 요금제에서 사용할
수 있습니다. 저장소를 공개한 뒤 별도의 배포 승인 절차가 필요하면 `release`
Environment와 승인 규칙을 추가해 Secrets 범위를 더 좁힐 수 있습니다.

## 릴리스 전 확인

- `main`에 배포할 변경이 모두 반영되어 있어야 합니다.
- 실제 인증정보, Apple 인증서 파일, `.env` 파일이 커밋되지 않았는지 확인합니다.
- Apple Silicon Mac용 공개 배포에는 `Developer ID Application` 인증서와 Apple
  공증 자격증명이 필요합니다.

CI가 통과했는지 확인합니다. 필요하면 다음 명령으로 같은 검증을 로컬에서
실행할 수 있습니다.

```bash
swift test
./scripts/build-app.sh dist
./scripts/verify-release.sh dist/CodexSwitch.app
```

## 버전은 어디서 관리하나요?

기준 파일은 **`Resources/Info.plist` 한 개**입니다. Actions를 사용할 때는
이 파일을 미리 수정하지 않고, Run workflow의 **version**에 배포할 버전을 입력합니다.

| 항목 | 현재 값 | 다음에 `0.3.11`을 입력하면 |
| --- | --- | --- |
| `CFBundleShortVersionString` | `0.3.10` | `0.3.11` — 사용자에게 보이는 버전 |
| `CFBundleVersion` | `14` | `15` — 자동 업데이트가 비교하는 내부 번호 |
| Git tag | `v0.3.10` | `v0.3.11` |

워크플로가 두 값을 갱신한 상태로 빌드·검증한 뒤, 버전 변경 커밋과 태그를
main에 함께 push하고 릴리스를 게시합니다. 같은 버전의 실패 작업을 재시도하면
내부 번호를 중복 증가시키지 않습니다. 이미 공개한 버전은 다시 게시할 수 없습니다.

배포 후 로컬에서 다음 작업을 시작하기 전에 `git pull --ff-only`로 자동 생성된
버전 커밋을 가져오세요. 로컬에서 직접 배포할 때만 위 두 값을 직접 올립니다.

## 릴리스 설명 작성

**`docs/releases/<버전>.md`**에 GitHub Release에 표시할 내용을 작성하고 코드와
함께 main에 push합니다. 예를 들어 다음 배포는 `docs/releases/0.3.11.md`입니다.
[기존 0.3.10 설명](releases/0.3.10.md)을 형식 참고용으로 사용할 수 있습니다.

액션은 이 파일의 Markdown을 그대로 게시합니다. 한국어·영어 설명 모두 한 파일에
작성하면 됩니다. 설명 파일이 없으면 서명·공증을 시작하기 전에 안내하고 멈춥니다.
AI가 자동으로 내용을 작성하는 방식은 아닙니다.

## Actions에서 배포

1. 코드와 `docs/releases/0.3.11.md` 같은 설명 파일을 `main`에 push합니다.
2. `CI`가 통과했는지 확인합니다.
3. GitHub의 [Actions → Release](https://github.com/heeeete/CodexSwitch/actions/workflows/release.yml)
   에서 **Run workflow**를 엽니다.
4. Branch는 `main`, version은 `0.3.11`처럼 새 버전을 입력하고 실행합니다.
5. 실행이 끝나면 생성된 태그와 GitHub Release를 확인합니다.

워크플로는 다음 조건을 먼저 검사합니다.

- 숫자 세 자리 버전이며 현재 버전보다 낮지 않은지, 해당 버전 설명 파일이 있는지
- 버전과 `CFBundleVersion`이 이전 릴리스보다 큰지
- 배포할 커밋이 실행 시점의 `origin/main` 최신 커밋인지
- 같은 버전의 게시된 Release가 없는지

검사가 끝나면 임시 키체인에 인증서를 가져오고 테스트, 서명, 공증, stapling,
Gatekeeper 검사를 수행합니다. 사용자용 ZIP과 서명된 `appcast.xml`을 초안 Release에
올린 뒤 다시 내려받아 원본 일치 여부와 피드 서명을 확인하고 게시합니다. 로컬에서 태그를 만들거나
공증 명령을 따로 실행할 필요는 없습니다.

빌드 중 다른 변경이 main에 push되면 버전 커밋을 덮어쓰지 않고 중단합니다.
이때는 최신 main에서 **Run workflow**를 다시 실행하세요. 버전 커밋 뒤 게시가
실패한 경우에도 최신 main에서 같은 버전으로 실행하면 기존 초안을 이어서 게시합니다.

> [!NOTE]
> 비공개 저장소의 macOS 러너와 공증 대기 시간은 GitHub Actions 사용량에
> 포함됩니다. 공개 저장소에서는 표준 GitHub-hosted 러너를 무료로 사용할 수
> 있습니다.

## 로컬 공증 프로필 준비

공증 자격증명은 프로젝트 파일이 아니라 macOS Keychain에 한 번 저장합니다.

```bash
xcrun notarytool store-credentials CodexSwitch-notary \
  --apple-id "APPLE_ID" \
  --team-id "TEAM_ID" \
  --password "APP_SPECIFIC_PASSWORD"
```

`CodexSwitch-notary`는 Keychain 프로필 이름입니다. Apple Developer 사이트에
표시되는 앱 이름이나 인증서 이름이 아닙니다.

## 로컬 ad-hoc 패키지

Developer ID 인증서가 없는 Mac에서는 설치 구조만 확인할 수 있습니다.

```bash
ALLOW_ADHOC=1 ./scripts/package-release.sh
```

산출물 이름에는 `-adhoc`이 붙습니다. 이 파일은 Gatekeeper용 Developer ID 서명과
Apple 공증이 없으므로 공개 배포하면 안 됩니다.

## 로컬 배포용 빌드·서명·공증

```bash
CODE_SIGN_IDENTITY="Developer ID Application: NAME (TEAM_ID)" \
NOTARY_PROFILE="CodexSwitch-notary" \
./scripts/package-release.sh
```

스크립트는 다음 작업을 순서대로 수행합니다.

1. Swift 테스트 실행
2. 고정된 `codex-auth`와 upstream 아카이브의 해시 검증
3. release 앱 조립과 Hardened Runtime 서명
4. 앱 구조·아이콘·아키텍처·독립 실행 조건 검증
5. 공증용 ZIP 업로드 및 결과 대기
6. 공증 티켓 stapling과 Gatekeeper 검사
7. 배포 ZIP, SHA-256 파일과 서명된 `appcast.xml` 생성

모든 검증이 끝나기 전에는 기존 `dist` 산출물을 교체하지 않습니다.

## 산출물 검증

예를 들어 버전이 `0.3.0`이라면 Release에는 다음 두 파일을 배포합니다.

- `dist/CodexSwitch-0.3.0-macos-arm64.zip`
- `dist/appcast.xml`

스크립트가 로컬 검증용으로 생성한 체크섬과 압축 파일을 다시 확인합니다.

```bash
cd dist
shasum -a 256 -c CodexSwitch-0.1.0-macos-arm64.zip.sha256
unzip -tq CodexSwitch-0.1.0-macos-arm64.zip
```

앱 번들의 서명, stapled ticket, Gatekeeper 판정도 확인합니다.

```bash
codesign --verify --deep --strict --verbose=4 CodexSwitch.app
xcrun stapler validate CodexSwitch.app
spctl --assess --type execute --verbose=4 CodexSwitch.app
```

현재 Mac에 설치된 ChatGPT 앱의 서명 조건까지 함께 확인하려면 opt-in 검증을
사용합니다.

```bash
VERIFY_CHATGPT_HOST=1 ./scripts/verify-release.sh dist/CodexSwitch.app
```

## 로컬 산출물을 GitHub Release에 게시

공증된 ZIP과 `appcast.xml`만 Release asset으로 올립니다. `CodexSwitch.app` 폴더,
SHA-256 파일, 공증 제출용 임시 ZIP, ad-hoc ZIP은 올리지 않습니다. Release 설명은
`**일반 사용자는 ZIP 파일만 다운로드하세요.**`로 시작합니다.

```bash
VERSION=0.3.0
gh release create "v$VERSION" \
  "dist/CodexSwitch-$VERSION-macos-arm64.zip" \
  "dist/appcast.xml" \
  --target main \
  --title "CodexSwitch $VERSION" \
  --notes "**일반 사용자는 ZIP 파일만 다운로드하세요.**"
```

게시한 뒤 GitHub에서 두 asset을 다시 내려받아 로컬 원본 및 서명과 비교합니다.

## 앱 내부 업데이트

`0.3.4`부터 배포 스크립트는 실제 App·Scene·시작 코드를 실행해 메뉴바 아이콘이
화면에 나타나는지도 검사합니다. 계정과 네트워크 작업은 테스트 대역으로 대체하며,
독립 실행은 `./scripts/test-startup.sh`로 할 수 있습니다.

`0.3.3`부터 다운로드한 앱의 첫 실행은 응용 프로그램 폴더에 자동 설치한 뒤
그 위치에서 다시 실행합니다. 설치가 끝나기 전에는 계정 조회와 업데이트 확인을
시작하지 않습니다. 기존 CodexSwitch가 실행 중이면 종료 후 재시도 안내를 표시합니다.
시스템 `/Applications`에 새 앱을 쓸 수 없으면 개인 `~/Applications`를 사용합니다.

서명 검증을 마친 설치본은 다운로드 격리 정보를 해제해 임시 위치에서 다시 실행되는
문제를 방지합니다. 다운로드 원본과 Apple 공증 티켓은 보존합니다.

서명·공증된 임시 앱의 실제 자동 설치·재실행은 다음 명령으로 검증합니다. 테스트 앱을
Apple 공증 서버에 제출하며, 사용자 계정과 실제 응용 프로그램 폴더는 사용하지 않습니다.

```bash
CODE_SIGN_IDENTITY="Developer ID Application: NAME (TEAM_ID)" \
NOTARY_PROFILE="CodexSwitch-notary" ./scripts/test-install.sh
```

앱은 자동 확인이 켜져 있으면 최신 Release의 `appcast.xml`을 매시간 확인합니다.
`0.3.1`부터 메뉴의 **설정…**에서 자동 확인을 켜고 끄거나 현재 버전을 확인할 수
있습니다. **지금 확인**은 자동 확인을 꺼도 사용할 수 있습니다. 다음 버전을 배포할 때도
반드시 ZIP과 피드 두 파일을 함께 올리고 최신 Release로 지정하세요.
피드와 ZIP은 EdDSA 서명으로 검증되며, 파일을 수정했다면 다시 서명해야 합니다.
`0.3.0` 이전 앱은 이 기능이 없어 최초 한 번은 수동으로 교체해야 합니다.

로컬 Sparkle 개인 키는 로그인 키체인의 `CodexSwitch` 계정에 저장되어 있습니다.
공개 키만 `Resources/Info.plist`에 포함되며, 공개 키와 대응하는 개인 키를 유지해야
이미 설치된 앱이 다음 업데이트를 신뢰할 수 있습니다. 새 키로 임의 교체하지 마세요.
개인 키는 저장소에 저장하지 않습니다. Actions 배포를 설정할 때만 키를 안전하게
`SPARKLE_PRIVATE_KEY` Secret으로 등록하세요. 로컬 배포는 키체인을 직접 사용합니다.

실제 다운로드부터 앱 교체·재실행까지는 다음 명령으로 시험합니다. 운영 코드의
업데이트 모듈을 별도 식별자의 임시 앱으로 빌드하므로 설치된 앱과 계정은 변경하지 않습니다.

```bash
CODE_SIGN_IDENTITY="Developer ID Application: NAME (TEAM_ID)" ./scripts/test-update.sh
UPDATE_TEST_MANUAL=1 CODE_SIGN_IDENTITY="Developer ID Application: NAME (TEAM_ID)" ./scripts/test-update.sh
```

두 번째 명령은 자동 확인을 끈 상태에서 수동 업데이트와 재시작 후 설정 유지를
확인합니다. 두 모드 모두 교체 후 수동 조회가 최신 버전 안내를 표시하는지도 검사합니다.
테스트용 다음 버전은 loopback 서버에서만 제공하며 GitHub에 게시하지 않습니다.

## 문제 해결

### `errSecInternalComponent`

Keychain이 잠겨 있거나 서명 인증서의 private key에 접근하지 못할 때 발생할 수
있습니다. 로그인 Keychain을 잠금 해제한 뒤 같은 명령을 다시 실행합니다.

```bash
security unlock-keychain ~/Library/Keychains/login.keychain-db
```

### 공증 대기가 오래 걸릴 때

`notarytool submit --wait`는 Apple 처리가 끝날 때까지 터미널에서 기다립니다.
터미널에서 `Control-C`를 눌러도 이미 제출된 작업은 Apple 서버에서 계속됩니다.
출력된 submission ID로 상태를 다시 확인할 수 있습니다.

```bash
xcrun notarytool info "SUBMISSION_ID" \
  --keychain-profile CodexSwitch-notary
```
