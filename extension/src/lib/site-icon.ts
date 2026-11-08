// The tab's icon, for PasswordPie's account list. The app never fetches icons; when a `tab` answer says `wantIcon`, the
// extension sends the icon the browser already shows for that tab. docs/BROWSER_EXTENSION.md, "icon".

import { isRecord } from './protocol';

/** The app refuses anything larger. */
export const ICON_MAX_SIDE = 128;
export const ICON_MAX_BYTES = 65_536;
export const ICON_FETCH_TIMEOUT_MS = 5_000;
/** Larger icon files are not read to the end. */
export const ICON_DOWNLOAD_LIMIT = 1_048_576;
/** Tried in turn until the PNG fits in ICON_MAX_BYTES. */
const SIDES = [ICON_MAX_SIDE, 64, 32];

export interface IconLink {
  href: string;
  rel: string;
  sizes: string;
  type: string;
}

/** background → content script of the top frame: the page's icon links, if it is still on `origin`. */
export interface IconLinksMessage {
  type: 'icon-links';
  origin: string;
}

/** A `tab` answer that asks for the tab's icon. */
export function wantsIcon(answer: unknown): boolean {
  return isRecord(answer) && answer.type === 'tab' && answer.wantIcon === true;
}

export function parseIconLinksMessage(value: unknown): IconLinksMessage | undefined {
  if (!isRecord(value) || value.type !== 'icon-links' || typeof value.origin !== 'string') return undefined;
  return { type: 'icon-links', origin: value.origin };
}

/** Content script: the icons the page declares, as absolute URLs. */
export function pageIconLinks(doc: Document): IconLink[] {
  const links: IconLink[] = [];
  for (const element of Array.from(doc.querySelectorAll('link[rel][href]'))) {
    const rel = (element.getAttribute('rel') ?? '').toLowerCase().split(/\s+/);
    const kind = rel.includes('icon') ? 'icon' : rel.some((r) => r.startsWith('apple-touch-icon')) ? 'apple-touch-icon' : '';
    if (!kind) continue;
    const href = (element as HTMLLinkElement).href;
    if (!href) continue;
    links.push({ href, rel: kind, sizes: element.getAttribute('sizes') ?? '', type: element.getAttribute('type') ?? '' });
  }
  return links.slice(0, 32);
}

/** Background: the links a content script answered with, keeping only well-formed ones. */
export function parseIconLinks(value: unknown): IconLink[] {
  if (!Array.isArray(value)) return [];
  return value
    .filter(isRecord)
    .filter((link) => ['href', 'rel', 'sizes', 'type'].every((key) => typeof link[key] === 'string'))
    .map((link) => ({ href: link.href as string, rel: link.rel as string, sizes: link.sizes as string, type: link.type as string }))
    .slice(0, 32);
}

/** The largest square side a `sizes` attribute declares, 0 when it declares none. */
export function declaredSize(sizes: string): number {
  let best = 0;
  for (const match of sizes.toLowerCase().matchAll(/(\d+)x(\d+)/g)) {
    best = Math.max(best, Math.min(Number(match[1]), Number(match[2])));
  }
  return best;
}

function isSvg(url: string, type = ''): boolean {
  return /svg/i.test(type) || /^data:image\/svg/i.test(url) || /\.svgz?(?:[?#]|$)/i.test(url);
}

/** https anywhere, a `data:` image, or plain http only on the page's own origin. Never another scheme. */
function allowed(url: string, pageOrigin: string): boolean {
  if (/^data:image\//i.test(url)) return true;
  try {
    const parsed = new URL(url);
    if (parsed.protocol === 'https:') return true;
    return parsed.protocol === 'http:' && parsed.origin === pageOrigin;
  } catch {
    return false;
  }
}

/**
 * Where to look for the tab's icon, best first: a declared icon of at least 64 px (largest first, `icon` before
 * `apple-touch-icon` at the same size), then the browser's own `favIconUrl`, then the other declared ones, then
 * `/favicon.ico`. SVG is skipped: a service worker cannot draw it.
 */
export function iconCandidates(pageOrigin: string, favIconUrl: string | undefined, links: IconLink[]): string[] {
  const usable = links
    .filter((link) => allowed(link.href, pageOrigin) && !isSvg(link.href, link.type))
    .map((link) => ({ url: link.href, size: declaredSize(link.sizes), touch: link.rel !== 'icon' }))
    .sort((a, b) => b.size - a.size || Number(a.touch) - Number(b.touch));
  const ordered = [
    ...usable.filter((link) => link.size >= 64).map((link) => link.url),
    ...(favIconUrl && allowed(favIconUrl, pageOrigin) && !isSvg(favIconUrl) ? [favIconUrl] : []),
    ...usable.filter((link) => link.size < 64).map((link) => link.url),
    `${pageOrigin}/favicon.ico`,
  ];
  return [...new Set(ordered)].filter((url) => allowed(url, pageOrigin));
}

export interface IconLayout {
  side: number;
  dx: number;
  dy: number;
  width: number;
  height: number;
}

/** Fits a `width` × `height` image, centered, into a square of at most `maxSide`. Small icons keep their size. */
export function fitIcon(width: number, height: number, maxSide = ICON_MAX_SIDE): IconLayout {
  const longest = Math.max(width, height, 1);
  const side = Math.max(1, Math.min(maxSide, longest));
  const scale = side / longest;
  const w = Math.max(1, Math.round(width * scale));
  const h = Math.max(1, Math.round(height * scale));
  return { side, dx: Math.floor((side - w) / 2), dy: Math.floor((side - h) / 2), width: w, height: h };
}

export interface DecodedIcon {
  width: number;
  height: number;
  close?(): void;
}

/** Drawing, injectable for tests. The browser's is `offscreenGraphics`. */
export interface IconGraphics {
  decode(blob: Blob): Promise<DecodedIcon | undefined>;
  toPng(icon: DecodedIcon, layout: IconLayout): Promise<Blob>;
}

export const offscreenGraphics: IconGraphics = {
  async decode(blob) {
    try {
      return await createImageBitmap(blob);
    } catch {
      return undefined;
    }
  },
  async toPng(icon, layout) {
    const canvas = new OffscreenCanvas(layout.side, layout.side);
    const context = canvas.getContext('2d');
    if (!context) throw new Error('no 2d context');
    context.imageSmoothingQuality = 'high';
    context.drawImage(icon as ImageBitmap, layout.dx, layout.dy, layout.width, layout.height);
    return canvas.convertToBlob({ type: 'image/png' });
  },
};

export async function base64(blob: Blob): Promise<string> {
  const bytes = new Uint8Array(await blob.arrayBuffer());
  let binary = '';
  for (let i = 0; i < bytes.length; i += 0x8000) {
    binary += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  }
  return btoa(binary);
}

/** Base64 PNG of at most 128 × 128 and 64 KB, or undefined when the image cannot be read or never gets that small. */
export async function encodeIcon(blob: Blob, graphics: IconGraphics): Promise<string | undefined> {
  const icon = await graphics.decode(blob);
  if (!icon || icon.width < 1 || icon.height < 1) return undefined;
  try {
    for (const side of SIDES) {
      const png = await graphics.toPng(icon, fitIcon(icon.width, icon.height, side));
      if (png.size > 0 && png.size <= ICON_MAX_BYTES) return await base64(png);
    }
    return undefined;
  } catch {
    return undefined;
  } finally {
    icon.close?.();
  }
}

export type FetchLike = (url: string, init: RequestInit) => Promise<Response>;

/** The icon file, without cookies, within 5 s and 1 MB. Undefined for an error, an SVG or anything that is not an image. */
export async function fetchIcon(url: string, fetchFn: FetchLike, timeoutMs = ICON_FETCH_TIMEOUT_MS): Promise<Blob | undefined> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const response = await fetchFn(url, { credentials: 'omit', cache: 'force-cache', signal: controller.signal });
    if (!response.ok) return undefined;
    const type = response.headers.get('content-type') ?? '';
    if (isSvg(url, type) || /^text\//i.test(type)) return undefined;
    const reader = response.body?.getReader();
    if (!reader) return undefined;
    const chunks: Uint8Array[] = [];
    let total = 0;
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      total += value.byteLength;
      if (total > ICON_DOWNLOAD_LIMIT) {
        await reader.cancel();
        return undefined;
      }
      chunks.push(value);
    }
    return total > 0 ? new Blob(chunks as BlobPart[], { type }) : undefined;
  } catch {
    return undefined;
  } finally {
    clearTimeout(timer);
  }
}

/** The first candidate that downloads and encodes, as base64 PNG. */
export async function tabIconPng(
  candidates: string[],
  deps: { fetch: FetchLike; graphics: IconGraphics },
): Promise<string | undefined> {
  for (const url of candidates) {
    const blob = await fetchIcon(url, deps.fetch);
    if (!blob) continue;
    const png = await encodeIcon(blob, deps.graphics);
    if (png) return png;
  }
  return undefined;
}
