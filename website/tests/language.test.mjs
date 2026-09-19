import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import { runInNewContext } from 'node:vm';

const script = readFileSync(new URL('../src/scripts/language.js', import.meta.url), 'utf8');

// 실제 head 스크립트를 방문 환경별로 실행해 이동 경로와 저장된 선택을 확인한다.
function visit({ path = '/', languages = ['en-US'], language = 'en-US', saved, blocked = false } = {}) {
  let destination;
  const localStorage = {
    getItem() { if (blocked) throw new Error('Storage blocked'); return saved; },
    setItem(key, value) { if (blocked) throw new Error('Storage blocked'); saved = value; },
  };
  runInNewContext(script, {
    URL, navigator: { languages, language }, localStorage,
    location: { href: `https://example.com${path}`, replace(url) { destination = url; } },
  });
  return { destination: destination && new URL(destination).pathname + new URL(destination).search + new URL(destination).hash, saved };
}

test('first visits follow the primary browser language, not secondary languages', () => {
  assert.equal(visit({ languages: ['en-US', 'ko-KR'] }).destination, '/en/');
  assert.equal(visit({ languages: ['ko-KR', 'en-US'] }).destination, '/ko/');
  assert.equal(visit({ languages: ['KO'] }).destination, '/ko/');
  assert.equal(visit({ languages: ['ja-JP'] }).destination, '/en/');
});

test('navigator.language is the fallback when the language list is unavailable', () => {
  assert.equal(visit({ languages: [], language: 'ko-KR' }).destination, '/ko/');
  assert.equal(visit({ languages: [], language: 'en-GB' }).destination, '/en/');
});

test('manual language choice overrides browser preference on a later root visit', () => {
  assert.equal(visit({ saved: 'ko' }).destination, '/ko/');
  assert.equal(visit({ saved: 'en', languages: ['ko-KR'] }).destination, '/en/');
});

test('legacy language links override an old choice and normalize to clean URLs', () => {
  assert.deepEqual(visit({ path: '/?lang=ko', saved: 'en' }), { destination: '/ko/', saved: 'ko' });
  assert.deepEqual(visit({ path: '/en/?lang=en', saved: 'ko' }), { destination: '/en/', saved: 'en' });
  assert.equal(visit({ path: '/en/?lang=ko', saved: 'en' }).destination, '/ko/');
});

test('shared locale routes stay in their own language and remember the choice', () => {
  assert.deepEqual(visit({ path: '/en/', saved: 'ko', languages: ['ko-KR'] }), { destination: undefined, saved: 'en' });
  assert.deepEqual(visit({ path: '/ko/', saved: 'en', languages: ['en-US'] }), { destination: undefined, saved: 'ko' });
  assert.equal(visit({ path: '/en' }).destination, '/en/');
  assert.equal(visit({ path: '/ko' }).destination, '/ko/');
});

test('blocked storage preserves language detection and explicit choice', () => {
  assert.equal(visit({ blocked: true }).destination, '/en/');
  assert.equal(visit({ blocked: true, path: '/?lang=ko' }).destination, '/ko/');
  assert.equal(visit({ blocked: true, path: '/en/?lang=ko' }).destination, '/ko/');
  assert.equal(visit({ blocked: true, path: '/ko/' }).destination, undefined);
});

test('invalid choices fall back safely and redirects preserve query and hash', () => {
  assert.equal(visit({ saved: 'invalid', path: '/?ref=release#setup' }).destination, '/en/?ref=release#setup');
  assert.equal(visit({ path: '/?lang=invalid', languages: ['ko'] }).destination, '/ko/?lang=invalid');
  assert.equal(visit({ path: '/?lang=ko&ref=release#setup' }).destination, '/ko/?ref=release#setup');
});

test('redirected URLs settle without a redirect loop', () => {
  const first = visit({ path: '/?ref=release#faq' });
  assert.equal(visit({ path: first.destination }).destination, undefined);
  const korean = visit({ path: '/en/?lang=ko' });
  assert.equal(visit({ path: korean.destination, saved: korean.saved }).destination, undefined);
});

test('unrelated paths are not redirected into a landing page', () => {
  assert.equal(visit({ path: '/missing/?lang=ko' }).destination, undefined);
  assert.equal(visit({ path: '/enough/' }).destination, undefined);
});
