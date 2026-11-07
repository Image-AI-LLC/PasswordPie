// Message shapes shared by the background, the content script and the native side.
// The native protocol is in docs/BROWSER_EXTENSION.md, "Messages".

export const EXTENSION_VERSION = '0.1.0';
export const PROTOCOL_VERSION = 1;
export const NATIVE_APP = 'com.oldcai.passwordpie';
/** The longest the background keeps a fill: the app's pending fill lasts 30 s from the pick. */
export const FILL_LIFETIME_MS = 30_000;

export type TabReason = 'activated' | 'updated' | 'focus' | 'poke' | 'startup';

export interface Credentials {
  origin: string;
  username: string;
  password: string;
}

/** background → content script */
export interface FillMessage extends Credentials {
  type: 'fill';
}

/** content script → background, the answer to a FillMessage */
export interface FillResult {
  username: boolean;
  password: boolean;
}

/** content script → background */
export type ContentMessage = { type: 'focus' } | { type: 'ready' } | { type: 'filled'; password: true };

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
}

/** The credentials in a `tab` answer, if it carries a well-formed fill. */
export function fillOfTabAnswer(value: unknown): TabFill | undefined {
  if (!isRecord(value) || value.type !== 'tab') return undefined;
  const fill = value.fill;
  if (!isRecord(fill)) return undefined;
  const { origin, username, password, expiresIn } = fill;
  if (typeof origin !== 'string' || typeof username !== 'string' || typeof password !== 'string') return undefined;
  const lifetimeMs =
    typeof expiresIn === 'number' && Number.isFinite(expiresIn) && expiresIn > 0
      ? Math.min(expiresIn * 1000, FILL_LIFETIME_MS)
      : FILL_LIFETIME_MS;
  return { origin, username, password, lifetimeMs };
}

export function parseFillMessage(value: unknown): FillMessage | undefined {
  if (!isRecord(value) || value.type !== 'fill') return undefined;
  const { origin, username, password } = value;
  if (typeof origin !== 'string' || typeof username !== 'string' || typeof password !== 'string') return undefined;
  return { type: 'fill', origin, username, password };
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
  return undefined;
}

/** The URL sent in a `tab` report: http(s) only, anything else is "". */
export function reportableUrl(url: string | undefined): string {
  if (!url) return '';
  try {
    const { protocol } = new URL(url);
    return protocol === 'http:' || protocol === 'https:' ? url : '';
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
