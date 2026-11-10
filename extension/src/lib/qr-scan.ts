// "Scan QR code on this page": read the two-step QR code a site shows and hand its otpauth:// link to the app, which asks
// the person where to add it. docs/BROWSER_EXTENSION.md, "`scan`". Runs only when the popup's button is clicked.
// Pictures and the link stay in this extension's memory: nothing is stored, logged, or sent anywhere but the app.

import jsQR from 'jsqr';
import { APP_NOT_RESPONDING, APP_UNAVAILABLE, isRecord, originOf } from './protocol';
import { MAX_PAGE_IMAGES, scaled } from './qr-page';
import type { ScanOutcome } from './scan-outcome';

export type { ScanOutcome } from './scan-outcome';


/** The app refuses longer text; a real otpauth:// link is a few hundred bytes. */
export const MAX_OTPAUTH_LENGTH = 4096;

export type QrKind = 'totp' | 'hotp' | 'migration' | 'other';

/** What a QR code's text is, for the popup's message. The app checks a `totp` link again before using it. */
export function classifyQrText(text: string): QrKind {
  const lower = text.trim().toLowerCase();
  if (lower.startsWith('otpauth-migration:')) return 'migration';
  if (lower.startsWith('otpauth://totp/') || lower.startsWith('otpauth://totp?')) return 'totp';
  if (lower.startsWith('otpauth://hotp')) return 'hotp';
  return 'other';
}

/** The issuer and account a link names, for the popup only. */
export function otpauthLabel(text: string): { issuer: string; account: string } {
  try {
    const url = new URL(text.trim());
    const label = decodeURIComponent(url.pathname.replace(/^\/+/, ''));
    const colon = label.indexOf(':');
    const issuer = url.searchParams.get('issuer') ?? (colon >= 0 ? label.slice(0, colon) : '');
    const account = colon >= 0 ? label.slice(colon + 1) : label;
    return { issuer: issuer.trim(), account: account.trim() };
  } catch {
    return { issuer: '', account: '' };
  }
}

// MARK: Decoding (background)

/** RGBA pixels → the QR code's text, with the bundled jsQR. */
export function decodeRgba(data: Uint8ClampedArray, width: number, height: number): string | undefined {
  return jsQR(data, width, height, { inversionAttempts: 'attemptBoth' })?.data || undefined;
}

interface DetectedBarcode {
  rawValue: string;
}
interface BarcodeDetectorLike {
  detect(image: ImageBitmap): Promise<DetectedBarcode[]>;
}
type BarcodeDetectorConstructor = new (options: { formats: string[] }) => BarcodeDetectorLike;

function barcodeDetector(): BarcodeDetectorLike | undefined {
  const ctor = (globalThis as { BarcodeDetector?: BarcodeDetectorConstructor }).BarcodeDetector;
  if (!ctor) return undefined;
  try {
    return new ctor({ formats: ['qr_code'] });
  } catch {
    return undefined;
  }
}

function blobOfDataUrl(dataUrl: string): Blob | undefined {
  const match = /^data:([^;,]+)(;base64)?,(.*)$/s.exec(dataUrl);
  if (!match) return undefined;
  const [, type, base64, payload = ''] = match;
  if (!base64) return new Blob([decodeURIComponent(payload)], { type });
  const binary = atob(payload);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i += 1) bytes[i] = binary.charCodeAt(i);
  return new Blob([bytes], { type });
}

/** A picture (a data URL, never fetched) → the texts of its QR codes. The browser's BarcodeDetector when it has one. */
export async function decodeQrDataUrl(dataUrl: string): Promise<string[]> {
  const blob = blobOfDataUrl(dataUrl);
  if (!blob) return [];
  let bitmap: ImageBitmap;
  try {
    bitmap = await createImageBitmap(blob);
  } catch {
    return [];
  }
  try {
    const detector = barcodeDetector();
    if (detector) {
      const found = await detector.detect(bitmap).catch(() => []);
      const texts = found.map((code) => code.rawValue).filter((text) => text !== '');
      if (texts.length > 0) return texts;
    }
    const size = scaled(bitmap.width, bitmap.height);
    const canvas = new OffscreenCanvas(size.width, size.height);
    const context = canvas.getContext('2d');
    if (!context) return [];
    context.drawImage(bitmap, 0, 0, size.width, size.height);
    const text = decodeRgba(context.getImageData(0, 0, size.width, size.height).data, size.width, size.height);
    return text ? [text] : [];
  } finally {
    bitmap.close();
  }
}

// MARK: The scan

export interface ScanTab {
  id?: number;
  windowId?: number;
  url?: string;
}

/** The browser and the app, injectable for tests. */
export interface ScanDeps {
  activeTab(): Promise<ScanTab | undefined>;
  /** The top frame's readable pictures (`qr-images`), as the content script answered. */
  pageImages(tabId: number): Promise<unknown>;
  /** A PNG data URL of the visible part of the tab, or undefined when the browser does not allow it. */
  captureVisibleTab(windowId: number | undefined): Promise<string | undefined>;
  decode(dataUrl: string): Promise<string[]>;
  /** The app's answer to a `scan`, or undefined for none. */
  sendScan(otpauth: string, url: string): Promise<unknown>;
  /** `show`: starts the app if it is installed but not running. True when it answered. */
  startApp(): Promise<boolean>;
}

async function payloadsOf(images: string[], decode: (dataUrl: string) => Promise<string[]>): Promise<string[]> {
  const texts: string[] = [];
  for (const image of images) {
    texts.push(...(await decode(image).catch(() => [])));
  }
  return texts;
}

function best(texts: string[]): { kind: QrKind; text?: string } | undefined {
  if (texts.length === 0) return undefined;
  const order: QrKind[] = ['totp', 'migration', 'hotp', 'other'];
  for (const kind of order) {
    const text = texts.find((t) => classifyQrText(t) === kind);
    if (text !== undefined) return { kind, text };
  }
  return undefined;
}

function answerKind(answer: unknown): 'sent' | 'refused' | 'unreachable' | 'old-app' {
  if (!isRecord(answer)) return 'unreachable';
  if (answer.type === 'scan') return 'sent';
  if (answer.type === 'error') {
    if (answer.code === 'bad-otp') return 'refused';
    if (answer.code === 'bad-request') return 'old-app';
    if (answer.code === APP_UNAVAILABLE || answer.code === APP_NOT_RESPONDING) return 'unreachable';
  }
  return 'unreachable';
}

/** Looks in the page, then at a picture of the visible tab, and hands the first two-step link to the app. */
export async function scanActiveTab(deps: ScanDeps): Promise<ScanOutcome> {
  const tab = await deps.activeTab().catch(() => undefined);
  const origin = tab?.url ? originOf(tab.url) : undefined;
  if (!tab || tab.id === undefined || !origin || !/^https?:/.test(origin)) return { kind: 'no-page' };

  const images = await deps.pageImages(tab.id).catch(() => []);
  const pagePictures = Array.isArray(images) ? images.filter((i): i is string => typeof i === 'string' && i.startsWith('data:image/')) : [];
  let found = best(await payloadsOf(pagePictures.slice(0, MAX_PAGE_IMAGES), deps.decode));
  if (found?.kind !== 'totp') {
    const shot = await deps.captureVisibleTab(tab.windowId).catch(() => undefined);
    const fromShot = shot ? best(await payloadsOf([shot], deps.decode)) : undefined;
    if (fromShot && (!found || fromShot.kind === 'totp')) found = fromShot;
  }
  if (!found) return { kind: 'none' };
  if (found.kind === 'hotp') return { kind: 'hotp' };
  if (found.kind === 'migration') return { kind: 'migration' };
  if (found.kind !== 'totp' || !found.text || found.text.length > MAX_OTPAUTH_LENGTH) return { kind: 'not-otp' };

  const otpauth = found.text.trim();
  let kind = answerKind(await deps.sendScan(otpauth, `${origin}/`));
  if (kind === 'unreachable' && (await deps.startApp())) kind = answerKind(await deps.sendScan(otpauth, `${origin}/`));
  if (kind === 'sent') return { kind: 'sent', ...otpauthLabel(otpauth) };
  return { kind };
}
