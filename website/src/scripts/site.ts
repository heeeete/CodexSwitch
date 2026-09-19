import { demoAccounts, demoCopy } from '../data/demo';

// 테마를 즉시 전환하고, 저장할 수 없는 환경에서도 UI는 계속 동작한다.
const root = document.documentElement;
const lang = root.lang === 'ko' ? 'ko' : 'en';
const d = demoCopy[lang];
const themeToggle = document.querySelector<HTMLButtonElement>('.theme-toggle')!;
const updateTheme = () => {
  const dark = root.dataset.theme !== 'light';
  themeToggle.setAttribute('aria-label', (dark ? themeToggle.dataset.lightLabel : themeToggle.dataset.darkLabel)!);
  document.querySelector('meta[name="theme-color"]')!.setAttribute('content', dark ? '#0b0c0e' : '#fafafa');
};
themeToggle.addEventListener('click', () => {
  root.dataset.theme = root.dataset.theme === 'light' ? 'dark' : 'light';
  try { localStorage.setItem('codexswitch-theme', root.dataset.theme); } catch { /* 테마 저장은 선택 사항이다. */ }
  updateTheme();
});
updateTheme();

// 웹 데모의 계정과 환경 설정은 이 페이지 안에서만 변경한다.
const app = document.querySelector<HTMLElement>('[data-app-menu]')!;
const menubar = document.querySelector<HTMLButtonElement>('[data-menubar-toggle]')!;
const switchButton = document.querySelector<HTMLButtonElement>('[data-switch-menu]')!;
const submenu = document.querySelector<HTMLElement>('#account-submenu')!;
const accountButtons = [...submenu.querySelectorAll<HTMLButtonElement>('[data-account]')];
const feedback = document.querySelector<HTMLElement>('[data-demo-feedback]')!;
const result = document.querySelector<HTMLElement>('[data-demo-result]')!;
const chatWindow = document.querySelector<HTMLElement>('[data-chatgpt-window]')!;
const chatClosed = document.querySelector<HTMLElement>('[data-chatgpt-closed]')!;
const chatProfile = document.querySelector<HTMLElement>('[data-chatgpt-profile]')!;
const reopenChatGPT = document.querySelector<HTMLInputElement>('[data-reopen-chatgpt]')!;
let selectedAccount = 0;
let chatTransition = 0;
const setFeedback = (message: string, state = 'idle') => {
  feedback.textContent = message;
  result.dataset.state = state;
};

// 새 조작이 들어오면 현재 프레임부터 이어간다. 닫히는 메뉴는 즉시 포커스 대상에서 제외한다.
const reducedMotion = window.matchMedia('(prefers-reduced-motion: reduce)');
const easeOut = 'cubic-bezier(0.16, 1, 0.3, 1)';
const animatePanel = (panel: HTMLElement, visible: boolean, intro = false) => {
  const fromHidden = panel.hidden || intro;
  const current = getComputedStyle(panel);
  const opacity = fromHidden ? 0 : Number(current.opacity);
  const transform = fromHidden ? 'translateY(-6px) scale(0.985)' : current.transform;
  panel.getAnimations().forEach((animation) => { animation.onfinish = null; animation.cancel(); });
  panel.inert = !visible;
  if (panel.hidden && !visible) return;
  panel.hidden = false;
  const frames: Keyframe[] = reducedMotion.matches
    ? [{ opacity }, { opacity: visible ? 1 : 0 }]
    : [{ opacity, transform }, { opacity: visible ? 1 : 0, transform: visible ? 'none' : 'translateY(-3px) scale(0.99)' }];
  const animation = panel.animate(frames, {
    duration: reducedMotion.matches ? 80 : visible ? (intro ? 420 : 220) : 110,
    easing: easeOut,
    fill: 'both',
  });
  animation.onfinish = () => { panel.hidden = !visible; animation.cancel(); };
};
const closeSubmenu = () => {
  if (switchButton.getAttribute('aria-expanded') === 'false') return;
  switchButton.setAttribute('aria-expanded', 'false');
  animatePanel(submenu, false);
};
const setAppVisible = (visible: boolean) => {
  if (menubar.getAttribute('aria-expanded') === String(visible)) return;
  menubar.setAttribute('aria-expanded', String(visible));
  closeSubmenu();
  animatePanel(app, visible);
};
const openSubmenu = (suggestNext = false) => {
  setAppVisible(true);
  switchButton.removeAttribute('data-invite');
  switchButton.setAttribute('aria-expanded', 'true');
  animatePanel(submenu, true);
  accountButtons[suggestNext ? (selectedAccount + 1) % accountButtons.length : selectedAccount].focus({ preventScroll: true });
};
menubar.addEventListener('click', () => setAppVisible(menubar.getAttribute('aria-expanded') === 'false'));
switchButton.addEventListener('click', () => switchButton.getAttribute('aria-expanded') === 'false' ? openSubmenu() : closeSubmenu());
document.querySelector('[data-demo-close]')!.addEventListener('click', () => { setAppVisible(false); menubar.focus({ preventScroll: true }); });
document.querySelectorAll('[data-try-switch]').forEach((button) => button.addEventListener('click', () => {
  openSubmenu(true);
  setFeedback('');
  const bounds = submenu.getBoundingClientRect();
  if (bounds.top < 0 || bounds.bottom > innerHeight) {
    switchButton.scrollIntoView({ block: 'center', behavior: reducedMotion.matches ? 'instant' : 'smooth' });
  }
}));

// 처음 보이는 메뉴만 한 번 펼친다. 본문이나 화면 밖의 섹션을 숨기지 않는다.
animatePanel(app, true, true);

// 실제 값은 즉시 반영하고 바뀐 데이터 영역만 짧게 강조한다.
const acknowledge = (element: HTMLElement) => {
  element.getAnimations().forEach((animation) => animation.cancel());
  element.animate([{ opacity: 0.4 }, { opacity: 1 }], {
    duration: reducedMotion.matches ? 80 : 240, easing: easeOut,
  });
};

// 실제 앱처럼 ChatGPT를 닫고 새 계정으로 연다. 연속 선택 시 마지막 조작만 완료한다.
const changeChatGPT = async (reopen: boolean) => {
  const transition = ++chatTransition;
  const index = selectedAccount;
  const opacity = Number(getComputedStyle(chatWindow).opacity);
  chatWindow.getAnimations().forEach((animation) => animation.cancel());
  if (reopen) setFeedback(d.reopening, 'reopening');
  if (!chatWindow.hidden) {
    const exit = chatWindow.animate(reducedMotion.matches
      ? [{ opacity }, { opacity: 0 }]
      : [{ opacity, transform: 'none' }, { opacity: 0, transform: 'scale(0.985)' }],
    { duration: reducedMotion.matches ? 80 : 160, easing: easeOut, fill: 'both' });
    await exit.finished.catch(() => {});
    if (transition !== chatTransition) return;
    chatWindow.hidden = true;
    exit.cancel();
  }
  chatProfile.querySelector('[data-chatgpt-email]')!.textContent = demoAccounts[index].email;
  chatProfile.querySelector('[data-chatgpt-name]')!.textContent = d.accountNames[index];
  chatProfile.querySelector('[data-chatgpt-avatar]')!.textContent = ['D', 'W', 'P'][index];
  chatClosed.hidden = reopen;
  if (reopen) {
    chatWindow.hidden = false;
    const enter = chatWindow.animate(reducedMotion.matches
      ? [{ opacity: 0 }, { opacity: 1 }]
      : [{ opacity: 0, transform: 'scale(0.985)' }, { opacity: 1, transform: 'none' }],
    { duration: reducedMotion.matches ? 80 : 420, delay: reducedMotion.matches ? 0 : 150, easing: easeOut, fill: 'both' });
    await enter.finished.catch(() => {});
    if (transition !== chatTransition) return;
    enter.cancel();
    setFeedback(d.switched.replace('{name}', d.accountNames[index]), 'success');
    acknowledge(chatProfile);
  } else {
    setFeedback(d.manualOpen, 'closed');
  }
  // 좁은 화면에서는 메뉴 아래에 배치한 전환 결과로 시선을 이어준다.
  const outcome = reopen ? chatProfile : chatClosed;
  const bounds = outcome.getBoundingClientRect();
  if (window.matchMedia('(max-width: 900px)').matches && (bounds.bottom > innerHeight || bounds.top < 0)) {
    outcome.scrollIntoView({ block: 'center', behavior: reducedMotion.matches ? 'instant' : 'smooth' });
  }
};
document.querySelector('[data-open-chatgpt]')!.addEventListener('click', () => {
  switchButton.focus({ preventScroll: true });
  void changeChatGPT(true);
});

// 선택한 계정의 상태, 사용량, 쿠폰을 같은 예시 데이터로 갱신한다.
accountButtons.forEach((button, index) => button.addEventListener('click', () => {
  const changed = selectedAccount !== index;
  selectedAccount = index;
  const account = demoAccounts[index];
  app.querySelector('[data-current-email]')!.textContent = account.email;
  app.querySelector('[data-remaining]')!.textContent = `${account.remaining}%`;
  app.querySelector('[data-reset]')!.textContent = account.reset;
  app.querySelector('[data-used]')!.textContent = `${100 - account.remaining}${d.used}`;
  app.querySelector('[data-daily]')!.textContent = d.daily.replace('{value}', String(account.daily));
  app.querySelector<HTMLElement>('[data-usage-fill]')!.style.setProperty('--remaining', `${account.remaining}%`);
  app.querySelector('[data-credit-count]')!.textContent = String(account.credits.length);
  app.querySelectorAll<HTMLElement>('[data-credit-row]').forEach((row, i) => { row.hidden = !account.credits[i]; row.querySelector('[data-credit-time]')!.textContent = account.credits[i] || ''; });
  app.querySelector<HTMLElement>('[data-credit-empty]')!.hidden = account.credits.length > 0;
  document.querySelector('[data-menubar-remaining]')!.textContent = `${account.remaining}%`;
  menubar.setAttribute('aria-label', `${d.menu}: ${account.remaining}%`);
  accountButtons.forEach((item, i) => { item.setAttribute('aria-checked', String(i === index)); item.tabIndex = i === index ? 0 : -1; });
  closeSubmenu();
  switchButton.focus({ preventScroll: true });
  if (changed) {
    app.querySelectorAll<HTMLElement>('.current-account, .meter-numbers, .meter-foot, .credit-list').forEach(acknowledge);
    void changeChatGPT(reopenChatGPT.checked);
  } else if (result.dataset.state !== 'reopening') {
    setFeedback(chatWindow.hidden ? d.manualOpen : d.alreadyActive);
  }
}));

// 네이티브 메뉴처럼 화살표 탐색, Escape, 바깥 클릭을 지원한다.
submenu.addEventListener('keydown', (event) => {
  const index = accountButtons.indexOf(document.activeElement as HTMLButtonElement);
  let next = index;
  if (event.key === 'ArrowDown') next = (index + 1) % accountButtons.length;
  else if (event.key === 'ArrowUp') next = (index - 1 + accountButtons.length) % accountButtons.length;
  else if (event.key === 'Home') next = 0;
  else if (event.key === 'End') next = accountButtons.length - 1;
  else return;
  event.preventDefault(); accountButtons[next].focus();
});
switchButton.addEventListener('keydown', (event) => { if (event.key === 'ArrowDown' || event.key === 'ArrowUp') { event.preventDefault(); openSubmenu(); } });
document.addEventListener('keydown', (event) => { if (event.key === 'Escape' && !submenu.hidden) { closeSubmenu(); switchButton.focus({ preventScroll: true }); } });
document.addEventListener('click', (event) => { if (!(event.target as HTMLElement).closest('.account-submenu-anchor, [data-try-switch]')) closeSubmenu(); });
submenu.addEventListener('focusout', (event) => { if (!submenu.contains(event.relatedTarget as Node)) closeSubmenu(); });

// 실제 서버를 호출하지 않는 예시 갱신이며, 설치가 필요한 동작은 안내한다.
const refresh = document.querySelector<HTMLButtonElement>('[data-refresh]')!;
refresh.addEventListener('click', () => {
  refresh.disabled = true; app.querySelector('[data-refresh-status]')!.textContent = d.refreshing;
  window.setTimeout(() => { app.querySelector('[data-refresh-status]')!.textContent = d.refreshed; refresh.disabled = false; }, 450);
});
document.querySelectorAll('[data-demo-hint]').forEach((button) => button.addEventListener('click', () => { setFeedback(d.hint); }));

// 동작 줄이기를 켜면 진행 중인 이동도 끝내고, 갱신·펼침 피드백은 계속 제공한다.
reducedMotion.addEventListener('change', () => {
  if (reducedMotion.matches) [...app.getAnimations({ subtree: true }), ...chatWindow.getAnimations({ subtree: true })].forEach((animation) => {
    if (animation.effect?.getComputedTiming().iterations !== Infinity) animation.finish();
  });
});
document.querySelectorAll<HTMLDetailsElement>('.faq-list details').forEach((details) => {
  details.addEventListener('toggle', () => {
    if (details.open) acknowledge(details.querySelector<HTMLElement>('p')!);
  });
});

// 데이터 처리 링크로 이동하면 해당 FAQ를 바로 펼친다.
const openLinkedAnswer = () => { if (location.hash === '#privacy-answer') document.querySelector<HTMLDetailsElement>('#privacy-answer')!.open = true; };
window.addEventListener('hashchange', openLinkedAnswer);
openLinkedAnswer();
