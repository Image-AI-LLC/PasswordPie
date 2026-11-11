// "Scan QR code on this page", the page's side: the pictures on screen that could be a QR code, read as PNG data URLs.
// Runs in the top frame's content script only when the background asks, which it does only after Scan was chosen in a
// right-click menu. Kept apart from the decoder so the content script on every page stays small.

import { isRecord } from './protocol';

/** The most page images read in one scan. */
export const MAX_PAGE_IMAGES = 8;
/** Smaller than this on screen, a QR code is not one a site expects to be scanned. */
export const MIN_QR_SIDE = 48;
/** Pictures are scaled down to this before decoding. */
export const MAX_DECODE_SIDE = 2048;

export function scaled(width: number, height: number): { width: number; height: number } {
  const scale = Math.min(1, MAX_DECODE_SIDE / Math.max(width, height, 1));
  return { width: Math.max(1, Math.round(width * scale)), height: Math.max(1, Math.round(height * scale)) };
}

export interface Box {
  top: number;
  left: number;
  width: number;
  height: number;
}

/**
 * The page's `<img>`, `<canvas>` and `<svg>` elements that are on screen and could be a QR code: at least 48 px, about
 * square, inside the viewport. The squarest first, at most eight.
 */
export function pageQrCandidates(
  doc: Document,
  viewport: { width: number; height: number },
  boxOf: (element: Element) => Box = (element) => element.getBoundingClientRect(),
): Element[] {
  const found: { element: Element; squareness: number }[] = [];
  for (const element of Array.from(doc.querySelectorAll('img, canvas, svg'))) {
    // An <svg> inside another one is part of a picture already listed.
    if (element.tagName.toLowerCase() === 'svg' && element.parentElement?.closest('svg')) continue;
    const box = boxOf(element);
    if (box.width < MIN_QR_SIDE || box.height < MIN_QR_SIDE) continue;
    const ratio = box.width / box.height;
    if (ratio < 0.6 || ratio > 1.6) continue;
    const visibleWidth = Math.min(box.left + box.width, viewport.width) - Math.max(box.left, 0);
    const visibleHeight = Math.min(box.top + box.height, viewport.height) - Math.max(box.top, 0);
    if (visibleWidth < box.width / 2 || visibleHeight < box.height / 2) continue;
    found.push({ element, squareness: Math.abs(Math.log(ratio)) });
  }
  return found
    .sort((a, b) => a.squareness - b.squareness)
    .slice(0, MAX_PAGE_IMAGES)
    .map((entry) => entry.element);
}

/** The pictures a content script can read: PNG data URLs. Images from another site the page did not allow are skipped. */
export async function pageQrImages(doc: Document, win: Window): Promise<string[]> {
  const images: string[] = [];
  for (const element of pageQrCandidates(doc, { width: win.innerWidth, height: win.innerHeight })) {
    const png = await rasterize(element, doc).catch(() => undefined);
    if (png) images.push(png);
  }
  return images;
}

async function rasterize(element: Element, doc: Document): Promise<string | undefined> {
  const tag = element.tagName.toLowerCase();
  if (tag === 'canvas') return (element as HTMLCanvasElement).toDataURL('image/png');
  let source: HTMLImageElement;
  if (tag === 'img') {
    source = element as HTMLImageElement;
    if (!source.complete || source.naturalWidth === 0) return undefined;
  } else {
    // An inline <svg>: drawn from its own markup, with a white backdrop (QR readers need contrast).
    const box = element.getBoundingClientRect();
    const markup = new XMLSerializer().serializeToString(element);
    source = new Image(Math.round(box.width), Math.round(box.height));
    source.src = `data:image/svg+xml;charset=utf-8,${encodeURIComponent(markup)}`;
    await source.decode();
  }
  const natural = source.naturalWidth > 0 ? { width: source.naturalWidth, height: source.naturalHeight } : { width: source.width, height: source.height };
  const size = scaled(natural.width, natural.height);
  const canvas = doc.createElement('canvas');
  canvas.width = size.width;
  canvas.height = size.height;
  const context = canvas.getContext('2d');
  if (!context) return undefined;
  context.fillStyle = '#fff';
  context.fillRect(0, 0, size.width, size.height);
  context.drawImage(source, 0, 0, size.width, size.height);
  // Throws for an image from another site that did not allow it: the screenshot covers that one.
  return canvas.toDataURL('image/png');
}

/** background → content script of the top frame: the readable pictures on screen. */
export interface QrImagesMessage {
  type: 'qr-images';
}

export function isQrImagesMessage(value: unknown): value is QrImagesMessage {
  return isRecord(value) && value.type === 'qr-images';
}
