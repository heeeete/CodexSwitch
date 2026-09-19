# CodexSwitch website

앱 저장소의 `website/`에서 독립적으로 빌드·배포하는 Astro 정적 랜딩 페이지.
공개 주소: [codexswitch.mkoiui98.workers.dev](https://codexswitch.mkoiui98.workers.dev/)

한국어 `/ko/`, 영어 `/en/`을 제공합니다. 앱의 Swift 빌드·서명·릴리스와 분리됩니다.
기본 주소 `/`에서만 저장한 선택이나 브라우저의 우선 언어를 감지합니다.
한국어는 `/ko/`, 나머지 언어는 `/en/`으로 이동하며 JavaScript가 없으면 영어로 표시합니다.
언어별 주소는 브라우저 언어와 관계없이 유지되며, EN/KO로 선택한 언어를 기억합니다.
저장소가 차단되어도 전환할 수 있고, 기존 `?lang=ko`·`?lang=en` 링크도 지원합니다.

## 실행과 배포

Node.js 22.12 이상:

```bash
cd website
npm ci
npm run dev
```

`npm run build`로 `dist/`를 생성하고 `npm run preview`로 확인합니다.
Cloudflare Workers Static Assets로 배포하며, 설정은 `wrangler.jsonc`에서 관리합니다.
GitHub의 `main`에 `website/` 변경을 푸시하면 Cloudflare가 테스트·빌드 후 자동 배포합니다.
앱의 Swift 코드만 변경한 경우에는 웹사이트 빌드를 실행하지 않습니다.

Cloudflare Builds 설정:

| 항목 | 값 |
| --- | --- |
| 저장소 | `heeeete/CodexSwitch` |
| 프로덕션 브랜치 | `main` |
| 프로젝트 폴더 | `website` |
| 빌드 명령 | `npm test && npm run build` |
| 배포 명령 | `npx wrangler deploy` |
| 변경 감지 경로 | `website/*` |
| 다른 브랜치 빌드 | 비활성화 |

Wrangler는 Cloudflare 빌드 서버에서도 사용하는 배포 도구입니다.
로컬에서 직접 배포해야 하는 경우에만 아래 명령을 사용합니다.

```bash
npx wrangler login --scopes account:read user:read workers_scripts:write
npm run deploy
```

서버 코드나 유료 리소스 없이 `workers.dev` 주소로 정적 파일을 제공합니다.
다운로드 링크는 GitHub의 최신 릴리스로 연결됩니다.

## 검색과 공유

- `astro.config.mjs`의 `site`가 canonical, 언어별 hreflang, 사이트맵과 공유 URL의 기준입니다.
- `/robots.txt`는 크롤링을 허용하고 `/sitemap.xml`을 안내합니다.
- 한국어·영어 제목과 설명, Open Graph·Twitter 공유 카드, WebSite 구조화 데이터를 정적 HTML에 포함합니다.
- 공유 이미지는 `public/images/social-card.png`이며 벡터 원본은 `src/assets/social-card.svg`입니다.
- `Seo.astro`의 `google-site-verification`은 공개 소유권 확인 값입니다. Search Console 인증 유지를 위해 보존합니다.

도메인을 변경하면 `site`를 수정해 재배포한 뒤, Search Console에 새 주소와 사이트맵을 등록합니다.
검색 결과 반영과 순위는 검색엔진의 수집·처리에 따라 달라집니다.

## 화면 구현

- Mac 디스플레이, 노치, 메뉴바, 앱 메뉴를 HTML/CSS로 구현합니다.
- `AppPreview.astro`: 실제 앱의 372px 메뉴, 계정 행, 스위치와 명령.
- `ChatGPTPreview.astro`: 선택한 예시 계정으로 다시 열리는 ChatGPT 창과 프로필.
- `UsageMeter.astro`, `CreditList.astro`: 재사용하는 사용량·쿠폰 컴포넌트.
- `AppMark.astro`: `CodexSwitchIcon.swift`의 기존 브랜드 경로와 색상을 옮긴 SVG.
- `src/data/demo.ts`: 실제 계정과 연결되지 않는 예시 계정 데이터.
- `src/scripts/site.ts`: 예시 계정 전환, 메뉴 키보드 탐색, 테마와 FAQ.
- `src/scripts/language.js`: 본문 렌더링 전 언어 감지와 명시적 선택 복원.
- `src/data/copy.ts`: 두 언어의 제품 설명.
- `src/styles/global.css`: 중립 색상, 네이티브 메뉴 스타일, 반응형 배치.

본문에 래스터 이미지나 앱 스크린샷을 사용하지 않습니다.
`public/images/app-icon.png`는 저장소의 기존 앱 아이콘으로, 파비콘에만 사용합니다.
서체는 운영체제의 네이티브 서체이며 외부 폰트를 요청하지 않습니다.
일반 UI 아이콘은 Framework7 Icons(MIT), Apple·GitHub 로고는 Simple Icons의 원본
SVG를 사용합니다. 라이선스 원문과 브랜드별 출처는 각 패키지에 포함되어 있습니다.
OpenAI 로고는 Simple Icons 13.21.0 원본 벡터이며 `src/assets/icons/README.md`에 출처를 기록합니다.
아이콘 폰트나 외부 CDN은 로드하지 않습니다. 배터리는 원본 경로를 유지하면서
SVG의 상하 여백만 줄여 가로 비율로 표시합니다.

## 데모 범위

예시 계정 선택은 잔여량, 초기화 시간, 쿠폰, 메뉴바 표시와 ChatGPT 프로필을 함께 갱신합니다.
체험 CTA는 다음 계정을 선택할 수 있도록 메뉴를 펼칩니다. 선택하면 ChatGPT 창이
닫혔다가 해당 계정으로 열리고, ‘변경 후 ChatGPT 열기’를 끄면 직접 열 수 있습니다.
스위치, 새로고침, 메뉴 닫기·재열기를 조작할 수 있습니다.
메뉴의 열기·닫기와 사용량 전환에는 짧은 모션을 적용합니다. 빠른 재조작은
현재 프레임부터 이어지고, 동작 줄이기 설정에서는 이동 없이 상태만 전달합니다.
추가·제거·설정은 설치 후 사용할 수 있다는 안내를 표시합니다.
실제 계정, 인증 정보, OpenAI API에는 연결하지 않습니다.

## 검증

- 두 언어의 정적 프로덕션 빌드.
- `npm test`: 우선 브라우저 언어, 저장된 선택, 명시적 링크, 저장소 차단, 리디렉션 루프 검증.
- `npm run build`: 생성한 HTML의 언어·canonical·hreflang·공유 메타데이터, 사이트맵과 이미지 파일 검증. 실패하면 자동 배포 중단.
- 320, 390, 768, 1024, 1440px 반응형과 밝은·어두운 테마 확인.
- 예시 계정 전환, 빈 쿠폰 상태, 키보드 탐색, 스위치, 메뉴 닫기·재열기 확인.
- FAQ, 데이터 처리 링크의 자동 펼침, 언어 전환 시 테마 유지 확인.
- 디자인 검사에서 발견한 사용량 막대의 레이아웃 애니메이션 제거.
- 이전 Geist 서체와 해당 검사 예외 제거. 디자인 규칙 억제 없음.

디자인 기준은 `DESIGN.md`, 이번 페이지의 구성 기준은 `DIRECTION.md`에 기록합니다.

최종 로컬 Lighthouse 모바일 측정: 성능 100, 접근성 100, 권장사항 100, SEO 100.
LCP 1.2초, TBT 0ms, CLS 0. 실제 배포 환경의 수치는 달라질 수 있습니다.
