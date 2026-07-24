# CodexSwitch

<!--
실제 스크린샷을 준비하면 아래 안내 문구를 다음 이미지로 교체하세요.
![CodexSwitch 메뉴 화면](docs/images/codexswitch-menu.png)
-->
<p align="center"><em>앱 스크린샷이 들어갈 자리입니다.</em></p>

CodexSwitch는 여러 ChatGPT/Codex 계정을 메뉴바에서 확인하고 빠르게 전환하는
비공식 macOS 앱입니다.

## 주요 기능

- 현재 계정과 5시간·주간 사용량 확인
- 남은 사용량과 정확한 재설정 시각 표시
- 여러 계정 사이 전환
- 새 계정 추가 및 저장된 계정 제거
- 비공개 ChatGPT API를 호출하지 않는 로컬 조회를 기본값으로 제공
- 검증된 `codex-auth`를 앱에 포함해 별도 npm 설치 없이 실행

## 다운로드 및 설치

1. [최신 Release](https://github.com/heeeete/CodexSwitch/releases/latest)에서
   `CodexSwitch-<버전>-macos-arm64.zip`을 내려받습니다.
2. ZIP의 압축을 풀고 `CodexSwitch.app`을 **응용 프로그램** 폴더로 옮깁니다.
3. 응용 프로그램 폴더에서 CodexSwitch를 실행합니다.
4. 메뉴바의 CodexSwitch 아이콘을 눌러 계정을 확인합니다.

배포 앱은 Apple Developer ID로 서명하고 Apple 공증을 마쳤습니다. Dock 아이콘이나
일반 창이 나타나지 않는 메뉴바 앱입니다.

## 사용 환경

- macOS 14 이상
- Apple Silicon Mac
- 공식 Codex CLI 또는 공식 ChatGPT 데스크톱 앱 중 하나

CodexSwitch에는 검증된 `codex-auth` 0.2.10 네이티브 바이너리가 들어 있습니다.
설치하거나 실행할 때 `npm i -g codex-auth`를 호출하지 않습니다.

새 계정 로그인에는 설치된 공식 Codex CLI를 우선 사용합니다. CLI가 없으면 서명을
검증한 ChatGPT 앱 내부 Codex를 사용합니다. 둘 다 찾지 못하면 필요한 설치 항목을
안내합니다.

## 사용 방법

1. Codex CLI나 ChatGPT에 이미 로그인했다면 기존 계정을 자동으로 가져옵니다.
2. 계정이 없다면 **계정 추가**를 눌러 브라우저에서 ChatGPT에 로그인합니다.
3. 다른 계정으로 바꾸려면 **계정 변경**에 마우스를 올리고 오른쪽 목록에서
   계정을 선택합니다.
4. 이 Mac에 저장된 계정을 지우려면 **계정 제거**에 마우스를 올리고 제거할
   계정을 선택합니다.

계정 추가는 현재 계정과 실행 중인 ChatGPT를 그대로 유지합니다. 계정 제거는 이
Mac에 저장된 Codex 인증정보만 지우며 실제 ChatGPT 계정을 삭제하지 않습니다.

## 보안 및 데이터

- CodexSwitch가 관리하는 계정 스냅샷은 `~/.codex` 아래에 저장하며 별도 서버로
  전송하지 않습니다.
- 계정을 변경하기 전에 기존 인증 파일을 로컬에 백업합니다.
- 기본 사용량 조회는 비공개 ChatGPT API를 호출하지 않습니다.
- CodexSwitch에서 계정을 변경하거나 제거하는 동안 터미널에서 별도의
  `codex-auth login`, `switch`, `remove` 명령을 동시에 실행하지 마세요.

### 실험적 API 조회

**실험적 API 조회**를 켜면 새로 고칠 때 `codex-auth`가 액세스 토큰으로 OpenAI의
비공개 ChatGPT 사용량·워크스페이스 엔드포인트를 호출합니다. 앱은 기능을 켜기
전에 위험을 알리고 동의를 받습니다.

이 과정에서 액세스 토큰이 로컬 Node 프로세스 인자에 잠시 전달될 수 있습니다.
`codex-auth` 원본 프로젝트는 이 방식이 이용약관 위반으로 감지되어 계정 제한이나
정지로 이어질 가능성을 경고합니다. 이 기능은 선택 사항이며 기본적으로 꺼져
있습니다.

## 개발 문서

- [개발 및 로컬 빌드](docs/DEVELOPMENT.md)
- [서명·공증·Release](docs/RELEASING.md)
- [오픈소스 출처와 라이선스](THIRD_PARTY_NOTICES.md)

## 라이선스 및 상표

CodexSwitch 자체 소스에는 별도의 오픈소스 라이선스를 부여하지 않습니다. 포함된
오픈소스 구성요소에는 각 프로젝트의 라이선스가 적용됩니다.

CodexSwitch는 OpenAI와 제휴하거나 OpenAI가 보증하는 공식 제품이 아닙니다.
ChatGPT와 Codex는 각 권리자의 상표입니다.
