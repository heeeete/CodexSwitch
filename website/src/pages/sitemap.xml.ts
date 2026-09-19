import type { APIRoute } from 'astro';

// 언어 관계는 HTML의 hreflang으로 제공하고 사이트맵에는 대표 URL만 담는다.
export const GET: APIRoute = ({ site }) => new Response(
  `<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n${
    ['/', '/ko/', '/en/'].map((path) => `  <url><loc>${new URL(path, site).href}</loc></url>`).join('\n')
  }\n</urlset>\n`,
  { headers: { 'Content-Type': 'application/xml; charset=utf-8' } },
);
