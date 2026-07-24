# CodexSwitch Release 가이드

이 문서는 CodexSwitch 관리자가 배포 파일을 만들 때 사용하는 절차입니다. 일반
사용자는 [README의 설치 안내](../README.md#다운로드-및-설치)를 참고하세요.

## 릴리스 전 확인

- `main`에 배포할 변경이 모두 반영되어 있어야 합니다.
- 실제 인증정보, Apple 인증서 파일, `.env` 파일이 커밋되지 않았는지 확인합니다.
- Apple Silicon Mac용 공개 배포에는 `Developer ID Application` 인증서와 Apple
  공증 자격증명이 필요합니다.

다음 명령으로 테스트와 로컬 앱 검증을 먼저 실행합니다.

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

## 공증 프로필 준비

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

## 배포용 빌드·서명·공증

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
7. 배포 ZIP과 SHA-256 파일 생성

모든 검증이 끝나기 전에는 기존 `dist` 산출물을 교체하지 않습니다.

## 산출물 검증

예를 들어 버전이 `0.1.0`이라면 다음 두 파일을 배포합니다.

- `dist/CodexSwitch-0.1.0-macos-arm64.zip`
- `dist/CodexSwitch-0.1.0-macos-arm64.zip.sha256`

체크섬과 압축 파일을 다시 확인합니다.

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

## GitHub Release

공증된 ZIP과 해당 SHA-256 파일만 Release asset으로 올립니다. `CodexSwitch.app`
폴더, 공증 제출용 임시 ZIP, ad-hoc ZIP은 올리지 않습니다.

```bash
VERSION=0.1.0
gh release create "v$VERSION" \
  "dist/CodexSwitch-$VERSION-macos-arm64.zip" \
  "dist/CodexSwitch-$VERSION-macos-arm64.zip.sha256" \
  --target main \
  --title "CodexSwitch $VERSION"
```

게시한 뒤 GitHub에서 asset을 다시 내려받아 함께 제공한 SHA-256 파일로 검증합니다.

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
