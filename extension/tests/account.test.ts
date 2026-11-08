import { beforeEach, describe, expect, it } from 'vitest';
import {
  AccountStore,
  ENTITLEMENT_KEY,
  SESSION_TOKEN_KEY,
  normalizeKey,
  parseEntitlement,
  redeemKey,
  refreshEntitlement,
  type KeyValue,
} from '../src/lib/account';

const SITE = 'https://passwordpie.com';

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

interface Call {
  url: string;
  init: RequestInit | undefined;
}

function fakeFetch(respond: (url: string, init?: RequestInit) => Response | Promise<Response>): { fetch: typeof fetch; calls: Call[] } {
  const calls: Call[] = [];
  const f = (async (input: RequestInfo | URL, init?: RequestInit) => {
    const url = String(input);
    calls.push({ url, init });
    return respond(url, init);
  }) as typeof fetch;
  return { fetch: f, calls };
}

const PREMIUM = { premium: true, plan: 'lifetime' as const, expiresAt: null, token: 'jwt-1' };
const FREE = { premium: false, plan: null, expiresAt: null, token: null };
const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { 'content-type': 'application/json' } });

let kv: MemoryKV;
let store: AccountStore;

beforeEach(async () => {
  kv = new MemoryKV();
  store = new AccountStore(kv, () => 1_000);
  await store.setSessionToken('session-1');
});

describe('normalizeKey', () => {
  it('accepts lowercase, spaces and missing dashes', () => {
    expect(normalizeKey('ppie-abcd-efgh-jkmn')).toBe('PPIE-ABCD-EFGH-JKMN');
    expect(normalizeKey(' PPIEABCDEFGHJKMN ')).toBe('PPIE-ABCD-EFGH-JKMN');
    expect(normalizeKey('abcd efgh jkmn')).toBe('PPIE-ABCD-EFGH-JKMN');
  });

  it('refuses 0, O, 1, I and the wrong length', () => {
    for (const bad of ['PPIE-ABCD-EFGH-JKM0', 'PPIE-OBCD-EFGH-JKMN', 'PPIE-1BCD-EFGH-JKMN', 'PPIE-IBCD-EFGH-JKMN', 'PPIE-ABCD-EFGH', '']) {
      expect(normalizeKey(bad)).toBeUndefined();
    }
  });
});

describe('parseEntitlement', () => {
  it('reads the site answer', () => {
    expect(parseEntitlement({ premium: true, plan: 'yearly', expiresAt: '2027-11-08T00:00:00Z', token: 'jwt' }, 5)).toEqual({
      premium: true,
      plan: 'yearly',
      expiresAt: '2027-11-08T00:00:00Z',
      token: 'jwt',
      checkedAt: 5,
    });
  });

  it('refuses anything else, and drops a token that is not for Premium', () => {
    expect(parseEntitlement({ premium: 'yes' }, 5)).toBeUndefined();
    expect(parseEntitlement({ premium: true, plan: 'forever', expiresAt: null, token: null }, 5)).toBeUndefined();
    expect(parseEntitlement({ ...FREE, token: 'jwt' }, 5)?.token).toBeNull();
  });
});

describe('refreshEntitlement', () => {
  it('asks with the bearer token and keeps the answer', async () => {
    const { fetch, calls } = fakeFetch(() => json(PREMIUM));
    expect(await refreshEntitlement(store, fetch, SITE)).toEqual({ ok: true, entitlement: { ...PREMIUM, checkedAt: 1_000 } });
    expect(calls[0]?.url).toBe(`${SITE}/api/premium/entitlement`);
    expect(new Headers(calls[0]?.init?.headers).get('authorization')).toBe('Bearer session-1');
    expect(calls[0]?.init?.credentials).toBe('omit');
    expect(await store.entitlementToken()).toBe('jwt-1');
  });

  it('a 401 signs out', async () => {
    await store.setEntitlement({ ...PREMIUM, checkedAt: 0 });
    const { fetch } = fakeFetch(() => json({ error: 'unauthorized' }, 401));
    expect(await refreshEntitlement(store, fetch, SITE)).toEqual({ ok: false, reason: 'signed-out' });
    expect(kv.data.has(SESSION_TOKEN_KEY)).toBe(false);
    expect(kv.data.has(ENTITLEMENT_KEY)).toBe(false);
  });

  it('a network failure keeps what it had', async () => {
    await store.setEntitlement({ ...PREMIUM, checkedAt: 0 });
    const { fetch } = fakeFetch(() => {
      throw new TypeError('Failed to fetch');
    });
    expect(await refreshEntitlement(store, fetch, SITE)).toEqual({ ok: false, reason: 'network' });
    expect(await store.entitlementToken()).toBe('jwt-1');
  });

  it('signed out, it asks nothing and clears the entitlement', async () => {
    await store.setEntitlement({ ...PREMIUM, checkedAt: 0 });
    await store.clear();
    const { fetch, calls } = fakeFetch(() => json(PREMIUM));
    expect(await refreshEntitlement(store, fetch, SITE)).toEqual({ ok: false, reason: 'signed-out' });
    expect(calls).toEqual([]);
    expect(await store.entitlementToken()).toBeUndefined();
  });

  it('a free account has no token to give', async () => {
    const { fetch } = fakeFetch(() => json(FREE));
    await refreshEntitlement(store, fetch, SITE);
    expect(await store.entitlementToken()).toBeUndefined();
  });
});

describe('redeemKey', () => {
  it('sends the normalized key and keeps the new entitlement', async () => {
    const { fetch, calls } = fakeFetch(() => json({ ...PREMIUM, plan: 'key' }));
    const result = await redeemKey(store, fetch, SITE, 'ppie abcd efgh jkmn');
    expect(result).toEqual({ ok: true, entitlement: { ...PREMIUM, plan: 'key', checkedAt: 1_000 } });
    expect(calls[0]?.url).toBe(`${SITE}/api/premium/redeem`);
    expect(calls[0]?.init?.method).toBe('POST');
    expect(JSON.parse(String(calls[0]?.init?.body))).toEqual({ code: 'PPIE-ABCD-EFGH-JKMN' });
  });

  it('reports the site errors', async () => {
    for (const error of ['invalid', 'used', 'expired', 'rate-limited'] as const) {
      const { fetch } = fakeFetch(() => json({ error }, error === 'rate-limited' ? 429 : 400));
      expect(await redeemKey(store, fetch, SITE, 'PPIE-ABCD-EFGH-JKMN')).toEqual({ ok: false, reason: error });
    }
  });

  it('a malformed key never leaves the browser', async () => {
    const { fetch, calls } = fakeFetch(() => json(PREMIUM));
    expect(await redeemKey(store, fetch, SITE, 'PPIE-0000')).toEqual({ ok: false, reason: 'invalid' });
    expect(calls).toEqual([]);
  });

  it('needs to be signed in', async () => {
    await store.clear();
    const { fetch } = fakeFetch(() => json(PREMIUM));
    expect(await redeemKey(store, fetch, SITE, 'PPIE-ABCD-EFGH-JKMN')).toEqual({ ok: false, reason: 'signed-out' });
  });
});
