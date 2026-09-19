import type { APIRoute } from 'astro';

// 정적 빌드에서 배포 주소를 사용해 크롤러에게 사이트맵을 안내한다.
export const GET: APIRoute = ({ site }) => new Response(
  `User-agent: *\nAllow: /\n\nSitemap: ${new URL('/sitemap.xml', site).href}\n`,
  { headers: { 'Content-Type': 'text/plain; charset=utf-8' } },
);
