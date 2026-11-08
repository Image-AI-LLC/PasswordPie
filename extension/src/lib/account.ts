// The passwordpie.com account: the Better Auth bearer session and the Premium entitlement (docs/ACCOUNTS.md). Plain
// fetch and storage, no React, so the background can refresh it and read the token for the app.

export const SESSION_TOKEN_KEY = 'session-token';
export const ENTITLEMENT_KEY = 'entitlement';
export const USER_KEY = 'user';

export interface AccountUser {
  email: string;
  name?: string;
}

export type Plan = 'lifetime' | 'yearly' | 'key';

export interface Entitlement {
  premium: boolean;
  plan: Plan | null;
  expiresAt: string | null;
  /** The signed token for the app. Only while `premium`. */
  token: string | null;
  /** When the site last answered (ms). */
  checkedAt: number;
}

export type RedeemError = 'invalid' | 'used' | 'expired' | 'rate-limited';
export type Failure = 'signed-out' | 'network' | 'server';
export type EntitlementResult = { ok: true; entitlement: Entitlement } | { ok: false; reason: Failure };
export type RedeemResult = { ok: true; entitlement: Entitlement } | { ok: false; reason: Failure | RedeemError };

/** `browser.storage.local`, or a fake. */
export interface KeyValue {
  get(key: string): Promise<unknown>;
  set(key: string, value: unknown): Promise<void>;
  remove(key: string): Promise<void>;
}

const PLANS = new Set<string>(['lifetime', 'yearly', 'key']);
const REDEEM_ERRORS = new Set<string>(['invalid', 'used', 'expired', 'rate-limited']);
const KEY_ALPHABET = /^[23456789ABCDEFGHJKLMNPQRSTUVWXYZ]{12}$/;

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null;
}

export function parseEntitlement(value: unknown, checkedAt: number): Entitlement | undefined {
  if (!isRecord(value) || typeof value.premium !== 'boolean') return undefined;
  const { premium, plan, expiresAt, token } = value;
  if (plan !== null && plan !== undefined && (typeof plan !== 'string' || !PLANS.has(plan))) return undefined;
  if (expiresAt !== null && expiresAt !== undefined && typeof expiresAt !== 'string') return undefined;
  return {
    premium,
    plan: (plan as Plan | null | undefined) ?? null,
    expiresAt: (expiresAt as string | null | undefined) ?? null,
    token: premium && typeof token === 'string' && token.length > 0 ? token : null,
    checkedAt,
  };
}

/** `PPIE-` and 12 characters without 0, O, 1 or I, in groups of four. Case, spaces and dashes do not matter. */
export function normalizeKey(raw: string): string | undefined {
  let body = raw.toUpperCase().replace(/[\s-]/g, '');
  if (body.startsWith('PPIE')) body = body.slice(4);
  if (!KEY_ALPHABET.test(body)) return undefined;
  return `PPIE-${body.slice(0, 4)}-${body.slice(4, 8)}-${body.slice(8)}`;
}

export class AccountStore {
  constructor(
    private readonly kv: KeyValue,
    private readonly now: () => number = Date.now,
  ) {}

  async sessionToken(): Promise<string | undefined> {
    const value = await this.kv.get(SESSION_TOKEN_KEY);
    return typeof value === 'string' && value ? value : undefined;
  }

  setSessionToken(token: string): Promise<void> {
    return this.kv.set(SESSION_TOKEN_KEY, token);
  }

  async entitlement(): Promise<Entitlement | undefined> {
    const value = await this.kv.get(ENTITLEMENT_KEY);
    return isRecord(value) && typeof value.checkedAt === 'number' ? parseEntitlement(value, value.checkedAt) : undefined;
  }

  setEntitlement(entitlement: Entitlement): Promise<void> {
    return this.kv.set(ENTITLEMENT_KEY, entitlement);
  }

  /** The last user the site answered with, to show while it cannot be reached. */
  async user(): Promise<AccountUser | undefined> {
    const value = await this.kv.get(USER_KEY);
    if (!isRecord(value) || typeof value.email !== 'string') return undefined;
    return { email: value.email, ...(typeof value.name === 'string' && value.name ? { name: value.name } : {}) };
  }

  setUser(user: AccountUser): Promise<void> {
    return this.kv.set(USER_KEY, user);
  }

  /** The token to show the app, while the account has Premium. */
  async entitlementToken(): Promise<string | undefined> {
    const entitlement = await this.entitlement();
    return entitlement?.premium ? (entitlement.token ?? undefined) : undefined;
  }

  timestamp(): number {
    return this.now();
  }

  /** Signed out: forget the session, the entitlement and the user. */
  async clear(): Promise<void> {
    await Promise.all([this.kv.remove(SESSION_TOKEN_KEY), this.kv.remove(ENTITLEMENT_KEY), this.kv.remove(USER_KEY)]);
  }
}

function headers(token: string, body: boolean): Headers {
  const h = new Headers({ Authorization: `Bearer ${token}`, Accept: 'application/json' });
  if (body) h.set('Content-Type', 'application/json');
  return h;
}

async function readJSON(response: Response): Promise<unknown> {
  try {
    return await response.json();
  } catch {
    return undefined;
  }
}

/** Asks the site for the account's Premium and keeps the answer. A 401 signs out; a network failure keeps the last one. */
export async function refreshEntitlement(store: AccountStore, fetcher: typeof fetch, siteUrl: string): Promise<EntitlementResult> {
  const token = await store.sessionToken();
  if (!token) {
    await store.clear();
    return { ok: false, reason: 'signed-out' };
  }
  let response: Response;
  try {
    response = await fetcher(`${siteUrl}/api/premium/entitlement`, { headers: headers(token, false), credentials: 'omit' });
  } catch {
    return { ok: false, reason: 'network' };
  }
  if (response.status === 401) {
    await store.clear();
    return { ok: false, reason: 'signed-out' };
  }
  const entitlement = response.ok ? parseEntitlement(await readJSON(response), store.timestamp()) : undefined;
  if (!entitlement) return { ok: false, reason: 'server' };
  await store.setEntitlement(entitlement);
  return { ok: true, entitlement };
}

export async function redeemKey(store: AccountStore, fetcher: typeof fetch, siteUrl: string, raw: string): Promise<RedeemResult> {
  const code = normalizeKey(raw);
  if (!code) return { ok: false, reason: 'invalid' };
  const token = await store.sessionToken();
  if (!token) return { ok: false, reason: 'signed-out' };
  let response: Response;
  try {
    response = await fetcher(`${siteUrl}/api/premium/redeem`, {
      method: 'POST',
      headers: headers(token, true),
      body: JSON.stringify({ code }),
      credentials: 'omit',
    });
  } catch {
    return { ok: false, reason: 'network' };
  }
  if (response.status === 401) {
    await store.clear();
    return { ok: false, reason: 'signed-out' };
  }
  const body = await readJSON(response);
  if (!response.ok) {
    const error = isRecord(body) ? body.error : undefined;
    return { ok: false, reason: typeof error === 'string' && REDEEM_ERRORS.has(error) ? (error as RedeemError) : 'server' };
  }
  const entitlement = parseEntitlement(body, store.timestamp());
  if (!entitlement) return { ok: false, reason: 'server' };
  await store.setEntitlement(entitlement);
  return { ok: true, entitlement };
}
