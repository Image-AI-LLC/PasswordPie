// Message shapes shared by the background, the content script and the native side.
// The native protocol is in docs/BROWSER_EXTENSION.md, "Messages".

export const EXTENSION_VERSION = '0.1.0';
export const PROTOCOL_VERSION = 1;
export const NATIVE_APP = 'com.oldcai.passwordpie';
/** Where the toolbar button goes when PasswordPie is not installed or cannot be started. */
export const WEBSITE_URL = 'https://passwordpie.com/';
/** The host's error for a `show` when PasswordPie runs but did not answer. */
export const APP_NOT_RESPONDING = 'app-not-responding';
/** The longest the background keeps a fill: the app's pending fill lasts 30 s from the pick. */
export const FILL_LIFETIME_MS = 30_000;
/** How long after a fill the page may show its two-step code field: the app's pending code lasts 30 s from the fill. */
export const CODE_LIFETIME_MS = 30_000;

export type TabReason = 'activated' | 'updated' | 'focus' | 'poke' | 'startup';

export interface Credentials {
  origin: string;
  username: string;
  password: string;
}

/** background → content script */
export interface FillMessage extends Credentials {
  type: 'fill';
  /** How long the frame may wait for fields to appear: what is left of the fill's lifetime. */
  waitMs?: number;
}

/** content script → background, the answer to a FillMessage */
export interface FillResult {
  username: boolean;
  password: boolean;
}

/** background → content script: look for a two-step code field for a while. Carries no secret. */
export interface WatchCodeMessage {
  type: 'watch-code';
  origin: string;
  waitMs: number;
}

/** background → content script: the code for the field found. */
export interface CodeMessage {
  type: 'code';
  origin: string;
  code: string;
}

/** background → content script: no Premium, so say so quietly next to the field. */
export interface CodeHintMessage {
  type: 'code-hint';
  origin: string;
  /** Where "Upgrade" goes; none in the App Store build. */
  upgradeUrl?: string;
}

export type FrameMessage = WatchCodeMessage | CodeMessage | CodeHintMessage;

/** content script → background */
export type ContentMessage =
  | { type: 'focus' }
  | { type: 'ready' }
  | { type: 'filled'; password: true }
  /** An empty code field appeared while the frame was watching. */
  | { type: 'code-field' };

/** popup → background */
export type PopupMessage = { type: 'open-panel' } | { type: 'popup-status' };

/** The background's answer to `popup-status`. */
export interface PopupStatus {
  /** The site whose code was not filled for lack of Premium, in the last few minutes. */
  codeSkippedOn?: string;
}

export function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null;
}

/** The `id` of an answer, or undefined for a push. */
export function messageId(value: unknown): number | undefined {
  if (!isRecord(value)) return undefined;
  const id = value.id;
  return typeof id === 'number' && Number.isInteger(id) ? id : undefined;
}

/** A fill from the app, and how long it may be kept: what is left of the 30 s since the pick (`expiresIn`, seconds). */
export interface TabFill extends Credentials {
  lifetimeMs: number;
  /** The account has a two-step code: watch for its field. */
  otp: boolean;
}

/** The credentials in a `tab` answer, if it carries a well-formed fill. */
export function fillOfTabAnswer(value: unknown): TabFill | undefined {
  if (!isRecord(value) || value.type !== 'tab') return undefined;
  const fill = value.fill;
  if (!isRecord(fill)) return undefined;
  const { origin, username, password, expiresIn, otp } = fill;
  if (typeof origin !== 'string' || typeof username !== 'string' || typeof password !== 'string') return undefined;
  const lifetimeMs =
    typeof expiresIn === 'number' && Number.isFinite(expiresIn) && expiresIn > 0
      ? Math.min(expiresIn * 1000, FILL_LIFETIME_MS)
      : FILL_LIFETIME_MS;
  return { origin, username, password, lifetimeMs, otp: otp === true };
}

export type CodeAnswer = { kind: 'code'; origin: string; code: string } | { kind: 'no-premium' } | { kind: 'none' };

/** What a `code` answer says. Anything malformed, an error or no answer is `none`. */
export function codeOfAnswer(value: unknown): CodeAnswer {
  if (!isRecord(value) || value.type !== 'code') return { kind: 'none' };
  const otp = value.otp;
  if (isRecord(otp) && typeof otp.origin === 'string' && typeof otp.code === 'string' && /^\d{4,10}$/.test(otp.code)) {
    return { kind: 'code', origin: otp.origin, code: otp.code };
  }
  if (value.premium === false) return { kind: 'no-premium' };
  return { kind: 'none' };
}

export function parseFrameMessage(value: unknown): FrameMessage | undefined {
  if (!isRecord(value) || typeof value.origin !== 'string') return undefined;
  const origin = value.origin;
  if (value.type === 'watch-code' && typeof value.waitMs === 'number' && Number.isFinite(value.waitMs) && value.waitMs >= 0) {
    return { type: 'watch-code', origin, waitMs: value.waitMs };
  }
  if (value.type === 'code' && typeof value.code === 'string') return { type: 'code', origin, code: value.code };
  if (value.type === 'code-hint') {
    const msg: CodeHintMessage = { type: 'code-hint', origin };
    if (typeof value.upgradeUrl === 'string' && isUpgradeUrl(value.upgradeUrl)) msg.upgradeUrl = value.upgradeUrl;
    return msg;
  }
  return undefined;
}

/** A link the page note may show: https, or this Mac's own mock site. */
function isUpgradeUrl(url: string): boolean {
  try {
    const { protocol, hostname } = new URL(url);
    return protocol === 'https:' || (protocol === 'http:' && (hostname === 'localhost' || hostname === '127.0.0.1'));
  } catch {
    return false;
  }
}

export function parsePopupMessage(value: unknown): PopupMessage | undefined {
  if (!isRecord(value)) return undefined;
  if (value.type === 'open-panel') return { type: 'open-panel' };
  if (value.type === 'popup-status') return { type: 'popup-status' };
  return undefined;
}

export function parseFillMessage(value: unknown): FillMessage | undefined {
  if (!isRecord(value) || value.type !== 'fill') return undefined;
  const { origin, username, password, waitMs } = value;
  if (typeof origin !== 'string' || typeof username !== 'string' || typeof password !== 'string') return undefined;
  const msg: FillMessage = { type: 'fill', origin, username, password };
  if (typeof waitMs === 'number' && Number.isFinite(waitMs) && waitMs >= 0) msg.waitMs = waitMs;
  return msg;
}

export function parseFillResult(value: unknown): FillResult | undefined {
  if (!isRecord(value) || typeof value.username !== 'boolean' || typeof value.password !== 'boolean') return undefined;
  return { username: value.username, password: value.password };
}

export function parseContentMessage(value: unknown): ContentMessage | undefined {
  if (!isRecord(value)) return undefined;
  if (value.type === 'focus') return { type: 'focus' };
  if (value.type === 'ready') return { type: 'ready' };
  if (value.type === 'filled' && value.password === true) return { type: 'filled', password: true };
  if (value.type === 'code-field') return { type: 'code-field' };
  return undefined;
}

/**
 * The URL sent in a `tab` report: the origin of an http(s) page, as `https://example.com/`, and "" for anything else.
 * Matching needs only scheme, host and port, so a path, query or fragment (reset links, OAuth codes) never leaves the browser.
 */
export function reportableUrl(url: string | undefined): string {
  if (!url) return '';
  try {
    const { protocol, origin } = new URL(url);
    return protocol === 'http:' || protocol === 'https:' ? `${origin}/` : '';
  } catch {
    return '';
  }
}

export function originOf(url: string): string | undefined {
  try {
    const { origin } = new URL(url);
    return origin === 'null' ? undefined : origin;
  } catch {
    return undefined;
  }
}
