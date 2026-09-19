// 첫 방문의 기본 언어를 정한다. 명시적인 링크와 저장한 선택은 브라우저 언어보다 우선한다.
(() => {
  const url = new URL(location.href);
  const explicit = url.searchParams.get('lang');
  let preferred;
  try {
    if (explicit === 'ko' || explicit === 'en') localStorage.setItem('codexswitch-language', explicit);
    preferred = localStorage.getItem('codexswitch-language');
  } catch { /* 저장소가 차단되어도 언어 링크의 lang 값은 적용한다. */ }
  const browserLanguage = navigator.languages?.[0] || navigator.language || 'en';
  const language = explicit === 'ko' || explicit === 'en' ? explicit
    : url.pathname.startsWith('/en') ? 'en'
    : preferred === 'ko' || preferred === 'en' ? preferred
    : /^ko(?:-|$)/i.test(browserLanguage) ? 'ko' : 'en';
  const path = language === 'ko' ? '/' : '/en/';
  if (url.pathname !== path) {
    url.pathname = path;
    location.replace(url.href);
  }
})();
