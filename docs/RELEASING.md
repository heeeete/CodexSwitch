# CodexSwitch Release 가이드

이 문서는 CodexSwitch 관리자가 배포 파일을 만들 때 사용하는 절차입니다. 일반
사용자는 [README의 설치 안내](../README.md#설치)를 참고하세요.

## 자동화 구성

저장소에는 두 개의 GitHub Actions 워크플로가 있습니다.

| 워크플로 | 실행 시점 | 역할 |
| --- | --- | --- |
| `CI` | PR, `main` 반영, 수동 실행 | 테스트와 ad-hoc 앱 검증 |
| `Release` | 관리자가 Actions 화면에서 실행 | 서명, 공증, ZIP 생성과 Release 게시 |

공개 배포는 `Release` 워크플로 사용을 권장합니다. 로컬 배포 절차는 Actions에
문제가 있거나 서명 과정을 직접 확인해야 할 때 사용할 수 있습니다.

## Actions 최초 설정

### 1. Developer ID 인증서 준비

키체인 접근에서 private key가 연결된 `Developer ID Application` 인증서를
`.p12`로 내보냅니다. 내보낼 때 설정한 암호를 보관하고, 파일을 Base64로
변환합니다.

```bash
base64 -i ~/Downloads/DeveloperIDApplication.p12 | pbcopy
```

### 2. App Store Connect Team API Key 준비

[App Store Connect API Key 안내](https://developer.apple.com/help/app-store-connect/get-started/app-store-connect-api/)에
따라 Team Key를 만들고 `.p8` 파일, Key ID, Issuer ID를 보관합니다. `.p8` 파일은
한 번만 내려받을 수 있습니다.

```bash
base64 -i ~/Downloads/AuthKey_XXXXXXXXXX.p8 | pbcopy
```

### 3. Actions Secrets 등록

GitHub 저장소의 **Settings → Secrets and variables → Actions**에서 다음 값을
**Repository secrets**로 등록합니다.

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
./scripts/build-app.sh
./scripts/verify-release.sh dist/CodexSwitch.app
```

## 버전 관리

`Resources/Info.plist`에서 두 값을 갱신합니다.

- `CFBundleShortVersionString`: 사용자에게 표시할 버전
- `CFBundleVersion`: 이전 배포보다 큰 빌드 번호

Git tag는 `v0.1.0`, Release 제목은 `CodexSwitch 0.1.0` 형식을 사용합니다.
이미 게시한 앱의 코드나 리소스가 바뀌면 버전을 올리고 새로 서명·공증합니다.

## Actions에서 배포

1. `Resources/Info.plist`의 `CFBundleShortVersionString`과 `CFBundleVersion`을
   올립니다.
2. 변경을 `main`에 반영하고 `CI`가 통과할 때까지 기다립니다.
3. GitHub의 **Actions → Release → Run workflow**를 엽니다.
4. Branch는 `main`, Version은 `0.2.0`처럼 Info.plist와 같은 값을 입력합니다.
5. 실행이 끝나면 생성된 태그와 GitHub Release를 확인합니다.

워크플로는 다음 조건을 먼저 검사합니다.

- 숫자 세 자리 버전과 Info.plist 버전이 일치하는지
- 버전과 `CFBundleVersion`이 이전 릴리스보다 큰지
- 배포할 커밋이 `origin/main`에 포함되어 있는지
- 같은 버전의 게시된 Release가 없는지

검사가 끝나면 임시 키체인에 인증서를 가져오고 테스트, 서명, 공증, stapling,
Gatekeeper 검사를 수행합니다. 사용자용 ZIP과 서명된 `appcast.xml`을 초안 Release에
올린 뒤 다시 내려받아 원본 일치 여부와 피드 서명을 확인하고 게시합니다. 로컬에서 태그를 만들거나
공증 명령을 따로 실행할 필요는 없습니다.

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
