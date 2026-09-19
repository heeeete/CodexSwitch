import { defineConfig } from 'astro/config';

// 정적 출력만 사용해 앱의 빌드와 웹사이트 배포를 독립적으로 유지한다.
export default defineConfig({
  site: 'https://codexswitch.mkoiui98.workers.dev',
  output: 'static',
  trailingSlash: 'always',
  devToolbar: { enabled: false },
});
