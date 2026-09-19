[English](README.md) · **한국어**

<div align="center">
  <img src="docs/images/codexswitch-icon.png" width="104" alt="CodexSwitch 앱 아이콘">
  <h1>CodexSwitch</h1>
  <p><strong>1초 만에, ChatGPT·Codex 실제 계정 전환.</strong></p>
  <p>메뉴바에서 고르면, 선택한 계정으로 ChatGPT가 다시 열립니다.</p>
  <p>
    <a href="https://github.com/heeeete/CodexSwitch/releases/latest"><img src="https://img.shields.io/badge/Download-latest-5865E8?style=flat-square&logo=apple&logoColor=white" alt="최신 버전 다운로드"></a>
    <img src="https://img.shields.io/badge/macOS-14%2B-30363D?style=flat-square&logo=macos&logoColor=white" alt="macOS 14 이상">
    <img src="https://img.shields.io/badge/Apple%20Silicon-arm64-42B7B3?style=flat-square" alt="Apple Silicon">
  </p>
</div>

## 주요 기능

- **계정 전환** — 터미널을 열지 않고 저장된 계정을 바로 바꿉니다.
- **사용량 확인** — Codex 잔여량, 초기화까지 남은 시간, 하루 사용 가능량을 한눈에 확인합니다.
- **초기화 쿠폰** — 현재 계정의 사용 가능한 쿠폰을 만료가 가까운 순서로 보여줍니다. 남은 기간은 `5d 20h`처럼 표시하며 자동 조회합니다.
- **자동 새로고침** — 메뉴를 닫아도 1분마다 사용량과 쿠폰을 갱신합니다. 기본값은 켜짐이며 선택은 앱을 다시 실행해도 유지됩니다.
- **로그인 시 자동 실행** — Mac에 로그인하면 자동으로 실행됩니다. 기본값은 켜짐이며 설정에서 언제든 끌 수 있습니다.
- **앱 업데이트** — 새 업데이트를 자동으로 확인하고 준비되면 하단에서 재시작을 안내합니다.
- **계정 관리** — 새 계정을 추가하고 이 Mac에 저장된 계정을 제거합니다.

## 설치

1. [최신 Release](https://github.com/heeeete/CodexSwitch/releases/latest)에서 Apple Silicon용 ZIP을 내려받습니다.
2. 압축을 풀고 `CodexSwitch.app`을 실행합니다. 처음 실행하면 **응용 프로그램** 폴더에 자동으로 설치한 뒤 다시 열립니다.
3. 메뉴바의 CodexSwitch 아이콘을 누릅니다. 기존 CodexSwitch가 실행 중이면 종료한 뒤 설치 안내에서 **다시 시도**를 누르세요.

> [!NOTE]
> 배포 앱은 Apple Developer ID로 서명하고 Apple 공증을 마쳤습니다. 설치가 끝나면 메뉴바에서 실행됩니다. `/Applications`에 쓸 수 없으면 개인 `~/Applications` 폴더를 사용합니다.

`0.3.0` 이전 버전을 사용 중이면 한 번 직접 내려받아 교체해 주세요. `0.3.0`부터는
새 업데이트를 매시간 확인하고 다운로드·검증이 끝나면 <strong>“새로운 업데이트가 있어요!
다시 시작할까요?”</strong>라고 알려줍니다. **다시 시작**을 누르면 CodexSwitch만 업데이트하고
다시 실행합니다. 진행 중인 계정 작업이 있으면 해당 작업이 끝난 뒤 누를 수 있습니다.

## 사용 환경

- macOS 14 이상
- Apple Silicon Mac
- 공식 Codex CLI 또는 공식 ChatGPT 데스크톱 앱 중 하나

## 사용 방법

1. Codex CLI나 ChatGPT에 이미 로그인했다면 기존 계정을 자동으로 가져옵니다.
2. 계정이 없다면 **계정 추가**를 눌러 브라우저에서 로그인합니다. 현재 계정과 실행 중인 ChatGPT는 그대로 유지됩니다.
3. 다른 계정으로 바꾸려면 **계정 변경**에 마우스를 올리고 오른쪽 목록에서 계정을 선택합니다.
4. 이 Mac에 저장된 계정을 지우려면 **계정 제거**에서 제거할 계정을 선택합니다.

계정 제거는 이 Mac의 Codex 인증정보만 지우며 실제 ChatGPT 계정을 삭제하지 않습니다.

계정 전환 후 새 계정을 적용하는 방법은 다음과 같습니다.

- **데스크톱 앱** — 기본 설정에서는 실행 중인 ChatGPT 앱을 자동으로 종료한 뒤 새 계정으로 다시 엽니다. **변경 후 ChatGPT 열기**를 꺼두었다면 직접 다시 열어 주세요.
- **Codex CLI** — 계정을 전환한 뒤 실행 중인 Codex CLI를 직접 종료하고 다시 실행해 주세요. CLI는 자동으로 재시작되지 않습니다.

## 사용량 조회

사용량은 최근 기록을 기준으로 표시됩니다. 계정 전환 직후 새 기록이 없으면 ‘사용량 정보 없음’으로 표시될 수 있습니다.

## 데이터와 계정

- 계정 정보는 이 Mac에 저장되며, 별도의 CodexSwitch 서버로 전송하지 않습니다.
- 계정을 변경하기 전에 기존 로그인 정보를 로컬에 백업합니다.
- CodexSwitch에서 계정을 변경하거나 제거하는 동안 다른 도구에서 같은 계정을 변경하지 마세요.

## 오픈소스 및 고지

CodexSwitch에는 MIT 라이선스의 [`codex-auth`](https://github.com/Loongphy/codex-auth)가 포함되어 있습니다. 전체 출처와 라이선스는 [Third-party notices](THIRD_PARTY_NOTICES.md)에서 확인할 수 있습니다.

CodexSwitch 자체 소스에는 별도의 오픈소스 라이선스가 적용되지 않습니다. CodexSwitch는 OpenAI와 제휴하거나 OpenAI가 보증하는 공식 제품이 아니며, ChatGPT와 Codex는 각 권리자의 상표입니다.
