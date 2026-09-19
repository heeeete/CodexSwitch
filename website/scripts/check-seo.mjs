import assert from 'node:assert/strict';
import { readFileSync, existsSync } from 'node:fs';
import config from '../astro.config.mjs';

const dist = new URL('../dist/', import.meta.url);
const read = (path) => readFileSync(new URL(path, dist), 'utf8');
const absolute = (path) => new URL(path, config.site).href;
const routes = [['/', 'index.html', 'en'], ['/ko/', 'ko/index.html', 'ko'], ['/en/', 'en/index.html', 'en']];
const sitemap = read('sitemap.xml');
const robots = read('robots.txt');

// 배포될 HTML을 검사해 언어 관계, 대표 주소, 공유 이미지가 함께 유지되는지 확인한다.
for (const [path, file, lang] of routes) {
  const html = read(file);
  const head = html.match(/<head>([\s\S]*?)<\/head>/)?.[1];
  assert.ok(head, `${path}: missing head`);
  assert.ok(html.includes(`<html lang="${lang}">`), `${path}: incorrect language`);
  assert.equal((html.match(/<h1\b/g) || []).length, 1, `${path}: expected one main heading`);
  assert.equal((head.match(/<link rel="canonical"/g) || []).length, 1, `${path}: expected one canonical`);
  assert.ok(head.includes(`<link rel="canonical" href="${absolute(path)}"`), `${path}: incorrect canonical`);
  for (const [language, target] of [['ko', '/ko/'], ['en', '/en/'], ['x-default', '/']]) {
    assert.ok(head.includes(`<link rel="alternate" hreflang="${language}" href="${absolute(target)}"`), `${path}: missing ${language} alternate`);
  }
  assert.ok(!/<meta[^>]+(?:name="(?:robots|googlebot)"|http-equiv="refresh")/i.test(head), `${path}: unexpected crawl directive`);
  for (const name of ['description', 'twitter:title', 'twitter:description', 'twitter:image']) {
    assert.ok(new RegExp(`<meta name="${name}" content="[^"]+"`).test(head), `${path}: missing ${name}`);
  }
  assert.ok(head.includes('content="summary_large_image"'), `${path}: missing large share card`);
  assert.ok(head.includes(`<meta property="og:url" content="${absolute(path)}"`), `${path}: incorrect share URL`);
  const image = head.match(/<meta property="og:image" content="([^"]+)"/)?.[1];
  assert.ok(image?.startsWith(config.site), `${path}: share image must use the production origin`);
  assert.ok(existsSync(new URL(`.${new URL(image).pathname}`, dist)), `${path}: missing share image file`);
  const json = JSON.parse(head.match(/<script[^>]+type="application\/ld\+json"[^>]*>([\s\S]*?)<\/script>/)?.[1]);
  assert.equal(json['@graph'].find((item) => item['@type'] === 'WebPage').inLanguage, lang);
  assert.ok(sitemap.includes(`<loc>${absolute(path)}</loc>`), `${path}: missing sitemap entry`);
  assert.ok(html.includes(`href="/${lang === 'ko' ? 'en' : 'ko'}/"`), `${path}: missing language switch link`);
}

// 사이트맵 접근을 막지 않고, 공유 카드가 선언한 1200×630 PNG인지 확인한다.
assert.ok(robots.includes(`Sitemap: ${absolute('/sitemap.xml')}`));
assert.ok(!/^Disallow:\s*\S/m.test(robots));
const png = readFileSync(new URL('images/social-card.png', dist));
assert.equal(png.subarray(1, 4).toString(), 'PNG');
assert.equal(png.readUInt32BE(16), 1200);
assert.equal(png.readUInt32BE(20), 630);
console.log('SEO checks passed: 3 routes, hreflang, canonical, sitemap, robots, structured data, share card.');
