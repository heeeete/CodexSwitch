// 웹 데모용 예시 데이터. 실제 계정, 인증정보, 네트워크 요청과 연결하지 않는다.
export const demoAccounts = [
  { email: 'demo@example.com', remaining: 62, reset: '4d 9h', daily: 14, credits: ['4d 9h', '17d 12h', '18d 13h'] },
  { email: 'work@example.com', remaining: 84, reset: '6d 14h', daily: 13, credits: ['12d 6h'] },
  { email: 'personal@example.com', remaining: 35, reset: '2d 8h', daily: 15, credits: [] },
];

export const demoCopy = {
  ko: {
    accounts: '계정 3개', refresh: '사용량 새로 고침', refreshed: '방금 갱신', refreshing: '갱신 중…',
    weekly: '주간 잔여량', left: '남음', resets: '초기화까지', used: '% 사용', daily: '하루 약 {value}%씩 사용 가능',
    credits: '초기화 쿠폰', count: '장', credit: '쿠폰', noCredits: '사용 가능한 쿠폰 없음',
    auto: '자동 새로고침', minute: '1분마다', reopen: '변경 후 ChatGPT 열기',
    switch: '계정 변경', add: '계정 추가', remove: '계정 제거', settings: '설정…', quit: '종료',
    menu: 'CodexSwitch 웹 데모 열기 또는 닫기',
    hint: '계정 추가·제거와 앱 설정은 CodexSwitch를 설치한 뒤 사용할 수 있습니다.',
    switched: 'ChatGPT가 {name}으로 다시 열렸습니다.',
    trySwitch: 'ChatGPT 계정 전환 체험하기',
    clickHint: '눌러보기', reopening: 'ChatGPT를 선택한 계정으로 다시 여는 중…',
    closed: 'ChatGPT가 닫혀 있습니다.', openChatGPT: 'ChatGPT 열기',
    manualOpen: '계정 전환 완료. ChatGPT를 열어주세요.',
    alreadyActive: '현재 사용 중인 계정입니다.',
    chatgptPreview: 'ChatGPT 계정 전환 예시 창',
    accountNames: ['기본 계정', '업무 계정', '개인 계정'],
  },
  en: {
    accounts: '3 accounts', refresh: 'Refresh usage', refreshed: 'Just updated', refreshing: 'Refreshing…',
    weekly: 'Weekly remaining', left: 'left', resets: 'Resets in', used: '% used', daily: 'About {value}% available per day',
    credits: 'Reset credits', count: 'available', credit: 'Credit', noCredits: 'No reset credits available',
    auto: 'Auto refresh', minute: 'Every minute', reopen: 'Open ChatGPT after switching',
    switch: 'Switch account', add: 'Add account', remove: 'Remove account', settings: 'Settings…', quit: 'Quit',
    menu: 'Open or close the CodexSwitch web demo',
    hint: 'Install CodexSwitch to add or remove accounts and change app settings.',
    switched: 'ChatGPT reopened with your {name}.',
    trySwitch: 'Try switching ChatGPT accounts',
    clickHint: 'Try it', reopening: 'Reopening ChatGPT with the selected account…',
    closed: 'ChatGPT is closed.', openChatGPT: 'Open ChatGPT',
    manualOpen: 'Account switched. Open ChatGPT to continue.',
    alreadyActive: 'This account is already active.',
    chatgptPreview: 'ChatGPT account-switching demo window',
    accountNames: ['default account', 'work account', 'personal account'],
  },
};
