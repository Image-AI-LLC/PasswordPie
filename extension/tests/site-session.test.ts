import { beforeEach, describe, expect, it } from 'vitest';
import { AccountStore, ENTITLEMENT_KEY, SESSION_TOKEN_KEY, USER_KEY, type KeyValue } from '../src/lib/account';
import { ACCEPT_WAITS, acceptSiteSession, fromConnectPage } from '../src/lib/site-session';

const SITE = 'https://passwordpie.com';
const EXT = 'ebgkjnfglbkeckkknmeakpkbdpjndjhk';

class MemoryKV implements KeyValue {
  data = new Map<string, unknown>();
  async get(key: string): Promise<unknown> {
    return this.data.get(key);
  }
  async set(key: string, value: unknown): Promise<void> {
    this.data.set(key, value);
  }
  async remove(key: string): Promise<void> {
    this.data.delete(key);
  }
}

const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { 'content-type': 'application/json' } });

interface Call {
  url: string;
  method: string;
  authorization: string | null;
  credentials: RequestCredentials | undefined;
}

/** passwordpie.com with these sessions: token → email. */
function site(sessions: Record<string, string>, premium: Record<string, boolean> = {}) {
  const calls: Call[] = [];
  const fetcher = (async (input: RequestInfo | URL, init?: RequestInit) => {
    const url = String(input);
    const authorization = new Headers(init?.headers).get('Authorization');
    calls.push({ url, method: init?.method ?? 'GET', authorization, credentials: init?.credentials });
    const token = /^Bearer (.+)$/.exec(authorization ?? '')?.[1];
    const email = token ? sessions[token] : undefined;
    if (url === `${SITE}/api/auth/get-session`) {
      return email ? json({ session: { id: 's' }, user: { email, name: email.split('@')[0] } }) : json(null);
    }
    if (url === `${SITE}/api/premium/entitlement`) {
      if (!email) return json({ error: 'unauthorized' }, 401);
      return json(premium[email] ? { premium: true, plan: 'lifetime', expiresAt: null, token: `pass-${email}` } : { premium: false });
    }
    if (url === `${SITE}/api/auth/sign-out`) return json({ success: true });
    return json({ error: 'not-found' }, 404);
  }) as typeof fetch;
  return { fetcher, calls };
}

let kv: MemoryKV;
let store: AccountStore;

beforeEach(() => {
  kv = new MemoryKV();
  store = new AccountStore(kv, () => 5);
});

describe('acceptSiteSession', () => {
  it('checks the token with the site, keeps it, refreshes the entitlement, and names the account', async () => {
    const { fetcher, calls } = site({ 'tok-1': 'ada@example.com' }, { 'ada@example.com': true });
    expect(await acceptSiteSession('tok-1', store, fetcher, SITE)).toEqual({ ok: true, email: 'ada@example.com' });
    expect(await store.sessionToken()).toBe('tok-1');
    expect(await store.user()).toEqual({ email: 'ada@example.com', name: 'ada' });
    expect(await store.entitlement()).toMatchObject({ premium: true, plan: 'lifetime', token: 'pass-ada@example.com' });
    expect(calls.map((c) => c.url)).toEqual([`${SITE}/api/auth/get-session`, `${SITE}/api/premium/entitlement`]);
    expect(calls.every((c) => c.authorization === 'Bearer tok-1' && c.credentials === 'omit')).toBe(true);
  });

  it('keeps nothing and fails when the site does not know the token', async () => {
    const { fetcher, calls } = site({});
    expect(await acceptSiteSession('forged', store, fetcher, SITE)).toEqual({ ok: false });
    expect(kv.data.size).toBe(0);
    expect(calls.map((c) => c.url)).toEqual([`${SITE}/api/auth/get-session`]);
  });

  it('keeps nothing when the site answers 401', async () => {
    const fetcher = (async () => json({ message: 'Unauthorized' }, 401)) as typeof fetch;
    expect(await acceptSiteSession('tok-1', store, fetcher, SITE)).toEqual({ ok: false });
    expect(kv.data.size).toBe(0);
  });

  it('keeps nothing when the site cannot be reached', async () => {
    const fetcher = (async () => {
      throw new TypeError('Failed to fetch');
    }) as typeof fetch;
    expect(await acceptSiteSession('tok-1', store, fetcher, SITE)).toEqual({ ok: false });
    expect(kv.data.size).toBe(0);
  });

  it('leaves the account it had when a new token is refused', async () => {
    await store.setSessionToken('old');
    await store.setUser({ email: 'old@example.com' });
    const { fetcher } = site({ old: 'old@example.com' });
    expect(await acceptSiteSession('forged', store, fetcher, SITE)).toEqual({ ok: false });
    expect(await store.sessionToken()).toBe('old');
    expect(await store.user()).toEqual({ email: 'old@example.com' });
  });

  it('replaces another account, and forgets its Premium', async () => {
    await store.setSessionToken('old');
    await store.setUser({ email: 'old@example.com' });
    await store.setEntitlement({ premium: true, plan: 'lifetime', expiresAt: null, token: 'old-pass', checkedAt: 1 });
    // The entitlement call fails, so whatever is kept afterwards was not refreshed.
    const sessions = { 'tok-2': 'ada@example.com', old: 'old@example.com' };
    const { fetcher: base } = site(sessions);
    const fetcher = (async (input: RequestInfo | URL, init?: RequestInit) => {
      if (String(input).endsWith('/api/premium/entitlement')) throw new TypeError('Failed to fetch');
      return base(input, init);
    }) as typeof fetch;
    expect(await acceptSiteSession('tok-2', store, fetcher, SITE)).toEqual({ ok: true, email: 'ada@example.com' });
    expect(await store.sessionToken()).toBe('tok-2');
    expect(await store.user()).toEqual({ email: 'ada@example.com', name: 'ada' });
    expect(kv.data.has(ENTITLEMENT_KEY)).toBe(false);
  });

  it('lets the app give back the other account\'s pass before the new account is kept', async () => {
    await store.setSessionToken('old');
    await store.setUser({ email: 'old@example.com' });
    await store.setEntitlement({ premium: true, plan: 'lifetime', expiresAt: null, token: 'old-pass', checkedAt: 1 });
    const { fetcher } = site({ 'tok-2': 'ada@example.com' });
    const seen: Array<string | undefined> = [];
    await acceptSiteSession('tok-2', store, fetcher, SITE, { accountChanged: async () => void seen.push(await store.sessionToken()) });
    // The relay ran while nothing was signed in, so it took the old pass back.
    expect(seen).toEqual([undefined]);
    expect(await store.sessionToken()).toBe('tok-2');
  });

  it('does not take the pass back when the same account connects again', async () => {
    await store.setSessionToken('old');
    await store.setUser({ email: 'ada@example.com' });
    const { fetcher } = site({ 'tok-2': 'ada@example.com' });
    let changed = 0;
    await acceptSiteSession('tok-2', store, fetcher, SITE, { accountChanged: async () => void (changed += 1) });
    expect(changed).toBe(0);
  });

  it('ends the session it replaces on the site, without waiting for it', async () => {
    await store.setSessionToken('old');
    await store.setUser({ email: 'ada@example.com' });
    const { fetcher, calls } = site({ 'tok-2': 'ada@example.com', old: 'ada@example.com' });
    expect(await acceptSiteSession('tok-2', store, fetcher, SITE)).toEqual({ ok: true, email: 'ada@example.com' });
    await new Promise((resolve) => setTimeout(resolve, 0));
    const signOut = calls.find((c) => c.url === `${SITE}/api/auth/sign-out`);
    expect(signOut).toMatchObject({ method: 'POST', authorization: 'Bearer old', credentials: 'omit' });
    expect(calls.filter((c) => c.authorization === 'Bearer old')).toHaveLength(1);
  });

  it('still connects when only the entitlement could not be read', async () => {
    const { fetcher: base } = site({ 'tok-1': 'ada@example.com' });
    const fetcher = (async (input: RequestInfo | URL, init?: RequestInit) => {
      if (String(input).endsWith('/api/premium/entitlement')) return json({ error: 'boom' }, 500);
      return base(input, init);
    }) as typeof fetch;
    expect(await acceptSiteSession('tok-1', store, fetcher, SITE)).toEqual({ ok: true, email: 'ada@example.com' });
    expect(kv.data.get(SESSION_TOKEN_KEY)).toBe('tok-1');
    expect(kv.data.get(USER_KEY)).toEqual({ email: 'ada@example.com', name: 'ada' });
  });
});

describe('acceptSiteSession answers in time for the page, which gives up 15 s after ready', () => {
  const never = () => new Promise<never>(() => undefined);
  const waits = { sessionMs: 30, relayMs: 30, entitlementMs: 30 };

  it('answers connected, with the session kept, when the entitlement call hangs', async () => {
    const { fetcher: base } = site({ 'tok-1': 'ada@example.com' });
    const fetcher = ((input: RequestInfo | URL, init?: RequestInit) =>
      String(input).endsWith('/api/premium/entitlement') ? never() : base(input, init)) as typeof fetch;
    expect(await acceptSiteSession('tok-1', store, fetcher, SITE, { waits })).toEqual({ ok: true, email: 'ada@example.com' });
    expect(await store.sessionToken()).toBe('tok-1');
  });

  it('keeps the new account when the app does not answer about the old pass', async () => {
    await store.setSessionToken('old');
    await store.setUser({ email: 'old@example.com' });
    const { fetcher } = site({ 'tok-2': 'ada@example.com' });
    expect(await acceptSiteSession('tok-2', store, fetcher, SITE, { waits, accountChanged: never })).toEqual({
      ok: true,
      email: 'ada@example.com',
    });
    expect(await store.sessionToken()).toBe('tok-2');
  });

  it('fails, keeping nothing, when the token check hangs', async () => {
    const fetcher = ((_input: RequestInfo | URL, init?: RequestInit) =>
      new Promise<Response>((_resolve, reject) => init?.signal?.addEventListener('abort', () => reject(init.signal?.reason)))) as typeof fetch;
    expect(await acceptSiteSession('tok-1', store, fetcher, SITE, { waits })).toEqual({ ok: false });
    expect(kv.data.size).toBe(0);
  });

  it('fails when the site ends the session between the token check and the entitlement', async () => {
    const { fetcher: base } = site({ 'tok-1': 'ada@example.com' });
    const fetcher = (async (input: RequestInfo | URL, init?: RequestInit) =>
      String(input).endsWith('/api/premium/entitlement') ? json({ error: 'unauthorized' }, 401) : base(input, init)) as typeof fetch;
    // The 401 cleared the account, so the page must not be told it is connected.
    expect(await acceptSiteSession('tok-1', store, fetcher, SITE, { waits })).toEqual({ ok: false });
    expect(await store.sessionToken()).toBeUndefined();
  });

  it('by default answers within 12 s in the worst case', () => {
    const { sessionMs, relayMs, entitlementMs } = ACCEPT_WAITS;
    expect(sessionMs + relayMs + entitlementMs).toBeLessThanOrEqual(12_000);
  });
});

describe('fromConnectPage', () => {
  const page = { id: EXT, url: `${SITE}/extension/connect`, frameId: 0 };

  it('takes the content script in the top frame of the connect page', () => {
    expect(fromConnectPage(page, EXT, SITE)).toBe(true);
    expect(fromConnectPage({ ...page, url: `${SITE}/zh/extension/connect?x=1#y` }, EXT, SITE)).toBe(true);
  });

  it('refuses any other sender', () => {
    expect(fromConnectPage({ ...page, id: 'other' }, EXT, SITE)).toBe(false);
    expect(fromConnectPage({ ...page, frameId: 3 }, EXT, SITE)).toBe(false);
    expect(fromConnectPage({ ...page, url: 'https://evil.example/extension/connect' }, EXT, SITE)).toBe(false);
    expect(fromConnectPage({ ...page, url: `${SITE}/sign-in` }, EXT, SITE)).toBe(false);
    expect(fromConnectPage({ ...page, url: 'not a url' }, EXT, SITE)).toBe(false);
    expect(fromConnectPage({ id: EXT, frameId: 0 }, EXT, SITE)).toBe(false);
  });
});
