// 언어별 주소는 고정하고, 기본 주소에 들어온 방문자에게만 언어를 자동 선택한다.
(() => {
  const url = new URL(location.href);
  const route = /^\/(ko|en)\/?$/.exec(url.pathname)?.[1];
  if (url.pathname !== '/' && !route) return;
  const query = url.searchParams.get('lang');
  const explicit = query === 'ko' || query === 'en' ? query : undefined;
  let preferred;
  try {
    preferred = localStorage.getItem('codexswitch-language');
  } catch { /* 저장소 없이도 언어 감지와 직접 링크는 동작한다. */ }

  const browserLanguage = navigator.languages?.[0] || navigator.language || 'en';
  const language = explicit || route
    || (preferred === 'ko' || preferred === 'en' ? preferred : undefined)
    || (/^ko(?:-|$)/i.test(browserLanguage) ? 'ko' : 'en');
  try {
    localStorage.setItem('codexswitch-language', language);
  } catch { /* 언어를 저장하지 못해도 페이지를 열 수 있다. */ }

  // 기존 ?lang 링크도 유지하되, 이동 후에는 검색·공유용 주소로 정리한다.
  url.pathname = `/${language}/`;
  if (explicit) url.searchParams.delete('lang');
  if (url.href !== location.href) location.replace(url.href);
})();
