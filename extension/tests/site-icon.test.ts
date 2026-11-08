import { describe, expect, it } from 'vitest';
import {
  ICON_DOWNLOAD_LIMIT,
  ICON_MAX_BYTES,
  declaredSize,
  encodeIcon,
  fetchIcon,
  fitIcon,
  iconCandidates,
  pageIconLinks,
  parseIconLinks,
  parseIconLinksMessage,
  tabIconPng,
  wantsIcon,
  type DecodedIcon,
  type FetchLike,
  type IconGraphics,
  type IconLayout,
  type IconLink,
} from '../src/lib/site-icon';

const ORIGIN = 'https://news.example.com';

function link(href: string, sizes = '', rel = 'icon', type = ''): IconLink {
  return { href, rel, sizes, type };
}

describe('choosing the icon', () => {
  it('prefers the largest declared icon, then the browser favicon, then small ones, then /favicon.ico', () => {
    const links = [
      link('https://news.example.com/16.png', '16x16'),
      link('https://news.example.com/192.png', '192x192'),
      link('https://news.example.com/touch.png', '180x180', 'apple-touch-icon'),
      link('https://news.example.com/plain.png'),
    ];
    expect(iconCandidates(ORIGIN, 'https://cdn.example.com/fav.ico', links)).toEqual([
      'https://news.example.com/192.png',
      'https://news.example.com/touch.png',
      'https://cdn.example.com/fav.ico',
      'https://news.example.com/16.png',
      'https://news.example.com/plain.png',
      'https://news.example.com/favicon.ico',
    ]);
  });

  it('puts icon before apple-touch-icon at the same size', () => {
    const links = [link('https://a.example/touch.png', '128x128', 'apple-touch-icon'), link('https://a.example/icon.png', '128x128')];
    expect(iconCandidates('https://a.example', undefined, links).slice(0, 2)).toEqual([
      'https://a.example/icon.png',
      'https://a.example/touch.png',
    ]);
  });

  it('skips SVG, other schemes, and plain http from another origin', () => {
    const links = [
      link('https://news.example.com/logo.svg', 'any'),
      link('https://news.example.com/logo', '', 'icon', 'image/svg+xml'),
      link('data:image/svg+xml;base64,PHN2Zz4=', '64x64'),
      link('http://other.example.com/icon.png', '64x64'),
      link('ftp://news.example.com/icon.png', '64x64'),
      link('javascript:alert(1)', '64x64'),
      link('chrome://favicon/https://news.example.com', '64x64'),
    ];
    expect(iconCandidates(ORIGIN, 'chrome://favicon2/?size=16', links)).toEqual(['https://news.example.com/favicon.ico']);
  });

  it('keeps data: images and same-origin http', () => {
    const data = 'data:image/png;base64,iVBORw0KGgo=';
    expect(iconCandidates('http://intranet.example', data, [link('http://intranet.example/i.png', '64x64')])).toEqual([
      'http://intranet.example/i.png',
      data,
      'http://intranet.example/favicon.ico',
    ]);
  });

  it('reads the declared sizes', () => {
    expect(declaredSize('16x16 32x32 192x192')).toBe(192);
    expect(declaredSize('120X90')).toBe(90);
    expect(declaredSize('any')).toBe(0);
    expect(declaredSize('')).toBe(0);
  });

  it('collects the page icon links as absolute URLs', () => {
    document.head.innerHTML = `
      <link rel="stylesheet" href="/a.css">
      <link rel="shortcut icon" href="/favicon.ico">
      <link rel="icon" sizes="192x192" type="image/png" href="icons/192.png">
      <link rel="apple-touch-icon-precomposed" href="/touch.png">
      <link rel="icon">`;
    expect(pageIconLinks(document)).toEqual([
      { href: 'https://example.com/favicon.ico', rel: 'icon', sizes: '', type: '' },
      { href: 'https://example.com/icons/192.png', rel: 'icon', sizes: '192x192', type: 'image/png' },
      { href: 'https://example.com/touch.png', rel: 'apple-touch-icon', sizes: '', type: '' },
    ]);
    document.head.innerHTML = '';
  });

  it('keeps only well-formed links from the content script', () => {
    expect(parseIconLinks([link('https://a.example/i.png'), { href: 1 }, null, 'x'])).toEqual([link('https://a.example/i.png')]);
    expect(parseIconLinks(undefined)).toEqual([]);
  });

  it('reads wantIcon and the content script ask', () => {
    expect(wantsIcon({ type: 'tab', id: 1, wantIcon: true })).toBe(true);
    expect(wantsIcon({ type: 'tab', id: 1 })).toBe(false);
    expect(wantsIcon({ type: 'tab', id: 1, wantIcon: 'yes' })).toBe(false);
    expect(wantsIcon({ type: 'hello', wantIcon: true })).toBe(false);
    expect(parseIconLinksMessage({ type: 'icon-links', origin: ORIGIN })).toEqual({ type: 'icon-links', origin: ORIGIN });
    expect(parseIconLinksMessage({ type: 'icon-links' })).toBeUndefined();
  });
});

describe('scaling', () => {
  it('scales a large icon down to 128', () => {
    expect(fitIcon(512, 512)).toEqual({ side: 128, dx: 0, dy: 0, width: 128, height: 128 });
  });

  it('centers a wide icon in a square', () => {
    expect(fitIcon(256, 128)).toEqual({ side: 128, dx: 0, dy: 32, width: 128, height: 64 });
  });

  it('keeps a small icon at its size', () => {
    expect(fitIcon(32, 32)).toEqual({ side: 32, dx: 0, dy: 0, width: 32, height: 32 });
    expect(fitIcon(16, 8, 64)).toEqual({ side: 16, dx: 0, dy: 4, width: 16, height: 8 });
  });

  it('honors a smaller limit', () => {
    expect(fitIcon(300, 300, 64).side).toBe(64);
  });
});

class FakeGraphics implements IconGraphics {
  layouts: IconLayout[] = [];
  closed = 0;
  constructor(
    private readonly size: { width: number; height: number } | undefined,
    private readonly bytesForSide: (side: number) => number = () => 1000,
  ) {}

  async decode(): Promise<DecodedIcon | undefined> {
    if (!this.size) return undefined;
    return { ...this.size, close: () => void (this.closed += 1) };
  }

  async toPng(_icon: DecodedIcon, layout: IconLayout): Promise<Blob> {
    this.layouts.push(layout);
    return new Blob([new Uint8Array(this.bytesForSide(layout.side))], { type: 'image/png' });
  }
}

describe('encoding', () => {
  it('encodes at most 128 × 128 as base64', async () => {
    const graphics = new FakeGraphics({ width: 256, height: 256 }, () => 3);
    expect(await encodeIcon(new Blob(['x']), graphics)).toBe('AAAA');
    expect(graphics.layouts.map((l) => l.side)).toEqual([128]);
    expect(graphics.closed).toBe(1);
  });

  it('steps down when the PNG is over 64 KB, and gives up below 32', async () => {
    const shrinks = new FakeGraphics({ width: 512, height: 512 }, (side) => (side > 64 ? ICON_MAX_BYTES + 1 : 10));
    expect(await encodeIcon(new Blob(['x']), shrinks)).toBeDefined();
    expect(shrinks.layouts.map((l) => l.side)).toEqual([128, 64]);

    const never = new FakeGraphics({ width: 512, height: 512 }, () => ICON_MAX_BYTES + 1);
    expect(await encodeIcon(new Blob(['x']), never)).toBeUndefined();
    expect(never.layouts.map((l) => l.side)).toEqual([128, 64, 32]);
  });

  it('gives nothing for what does not decode', async () => {
    expect(await encodeIcon(new Blob(['<html>']), new FakeGraphics(undefined))).toBeUndefined();
  });
});

function response(body: BodyInit | null, init: ResponseInit = {}): Response {
  return new Response(body, init);
}

describe('fetching', () => {
  it('fetches without cookies', async () => {
    const seen: RequestInit[] = [];
    const fetchFn: FetchLike = async (_url, init) => {
      seen.push(init);
      return response(new Uint8Array([1, 2, 3]), { headers: { 'content-type': 'image/png' } });
    };
    const blob = await fetchIcon('https://a.example/i.png', fetchFn);
    expect(blob?.size).toBe(3);
    expect(seen[0]?.credentials).toBe('omit');
  });

  it('refuses errors, SVG, text and files over 1 MB', async () => {
    expect(await fetchIcon('https://a.example/i.png', async () => response('no', { status: 404 }))).toBeUndefined();
    expect(
      await fetchIcon('https://a.example/i', async () => response('<svg/>', { headers: { 'content-type': 'image/svg+xml' } })),
    ).toBeUndefined();
    expect(
      await fetchIcon('https://a.example/i', async () => response('<html>', { headers: { 'content-type': 'text/html' } })),
    ).toBeUndefined();
    const huge = new Uint8Array(ICON_DOWNLOAD_LIMIT + 1);
    expect(await fetchIcon('https://a.example/i.png', async () => response(huge))).toBeUndefined();
    expect(await fetchIcon('https://a.example/i.png', async () => Promise.reject(new TypeError('offline')))).toBeUndefined();
  });

  it('gives up after the timeout', async () => {
    const hang: FetchLike = (_url, init) =>
      new Promise((_resolve, reject) => init.signal?.addEventListener('abort', () => reject(new DOMException('aborted', 'AbortError'))));
    expect(await fetchIcon('https://a.example/i.png', hang, 10)).toBeUndefined();
  });

  it('tries candidates in order until one encodes', async () => {
    const tried: string[] = [];
    const fetchFn: FetchLike = async (url) => {
      tried.push(url);
      return url.endsWith('/bad.png') ? response('x', { status: 500 }) : response(new Uint8Array([1]));
    };
    const png = await tabIconPng(['https://a.example/bad.png', 'https://a.example/good.png', 'https://a.example/favicon.ico'], {
      fetch: fetchFn,
      graphics: new FakeGraphics({ width: 64, height: 64 }),
    });
    expect(png).toBeDefined();
    expect(tried).toEqual(['https://a.example/bad.png', 'https://a.example/good.png']);
  });
});
