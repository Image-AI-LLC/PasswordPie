import { describe, expect, it } from 'vitest';
import { AccountStore, type KeyValue } from '../src/lib/account';
import { currentUser, sessionUser, signOut } from '../src/lib/auth';

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

const json = (body: unknown, status = 200, headers: Record<string, string> = {}) =>
  new Response(JSON.stringify(body), { status, headers: { 'content-type': 'application/json', ...headers } });

function fetching(respond: () => Response | Promise<Response>) {
  const calls: Array<{ url: string; init: RequestInit | undefined }> = [];
  const fetcher = (async (input: RequestInfo | URL, init?: RequestInit) => {
    calls.push({ url: String(input), init });
    return respond();
  }) as typeof fetch;
  return { fetcher, calls };
}

const offline = () => {
  throw new TypeError('Failed to fetch');
};

describe('sessionUser', () => {
  it('asks get-session with the bearer token and no cookies', async () => {
    const { fetcher, calls } = fetching(() => json({ session: {}, user: { email: 'a@b.c', name: 'A' } }));
    expect(await sessionUser(fetcher, SITE, 'tok')).toEqual({ kind: 'user', user: { email: 'a@b.c', name: 'A' } });
    expect(calls[0]?.url).toBe(`${SITE}/api/auth/get-session`);
    expect(new Headers(calls[0]?.init?.headers).get('Authorization')).toBe('Bearer tok');
    expect(calls[0]?.init?.credentials).toBe('omit');
  });

  it('reads null, a 401 and a user without an email as no session', async () => {
    for (const response of [json(null), json({ message: 'no' }, 401), json({ session: {}, user: { name: 'A' } }), json({})]) {
      expect(await sessionUser(fetching(() => response.clone()).fetcher, SITE, 'tok')).toEqual({ kind: 'none' });
    }
  });

  it('reads a network failure, a 500, a 403 or a 200 that is not JSON as unknown, not as signed out', async () => {
    expect((await sessionUser(fetching(offline).fetcher, SITE, 'tok')).kind).toBe('error');
    expect((await sessionUser(fetching(() => json({}, 500)).fetcher, SITE, 'tok')).kind).toBe('error');
    // A challenge or captive-portal page is not the site saying the session ended.
    expect((await sessionUser(fetching(() => new Response('<html>Just a moment…</html>', { status: 403 })).fetcher, SITE, 'tok')).kind).toBe('error');
    expect((await sessionUser(fetching(() => new Response('<html>Wi-Fi sign-in</html>', { status: 200 })).fetcher, SITE, 'tok')).kind).toBe('error');
  });

  it('gives up on a site that does not answer', async () => {
    let signal: AbortSignal | undefined;
    const fetcher = ((_input: RequestInfo | URL, init?: RequestInit) => {
      signal = init?.signal ?? undefined;
      return new Promise<Response>((_resolve, reject) => signal?.addEventListener('abort', () => reject(signal?.reason)));
    }) as typeof fetch;
    expect((await sessionUser(fetcher, SITE, 'tok', 20)).kind).toBe('error');
    expect(signal?.aborted).toBe(true);
  });
});

describe('currentUser', () => {
  it('returns the saved user when the site cannot be reached, and clears on a 401', async () => {
    const store = new AccountStore(new MemoryKV());
    await store.setSessionToken('t');
    expect(await currentUser(store, fetching(() => json({ user: { email: 'a@b.c', name: 'A' } })).fetcher, SITE)).toEqual({
      email: 'a@b.c',
      name: 'A',
    });
    expect(await currentUser(store, fetching(offline).fetcher, SITE)).toEqual({ email: 'a@b.c', name: 'A' });
    expect(await currentUser(store, fetching(() => json({ message: 'no' }, 401)).fetcher, SITE)).toBeNull();
    expect(await store.sessionToken()).toBeUndefined();
    expect(await store.user()).toBeUndefined();
  });

  it('asks nothing when signed out', async () => {
    const store = new AccountStore(new MemoryKV());
    const { fetcher, calls } = fetching(() => json(null));
    expect(await currentUser(store, fetcher, SITE)).toBeNull();
    expect(calls).toHaveLength(0);
  });

  it('keeps a renewed token the site sends back', async () => {
    const store = new AccountStore(new MemoryKV());
    await store.setSessionToken('t');
    await currentUser(store, fetching(() => json({ user: { email: 'a@b.c' } }, 200, { 'set-auth-token': 't2' })).fetcher, SITE);
    expect(await store.sessionToken()).toBe('t2');
  });

  it('throws when offline with nothing saved', async () => {
    const store = new AccountStore(new MemoryKV());
    await store.setSessionToken('t');
    await expect(currentUser(store, fetching(offline).fetcher, SITE)).rejects.toThrow('Failed to fetch');
  });
});

describe('signOut', () => {
  it('ends the session on the site and forgets it here', async () => {
    const store = new AccountStore(new MemoryKV());
    await store.setSessionToken('t');
    await store.setUser({ email: 'a@b.c' });
    const { fetcher, calls } = fetching(() => json({ success: true }));
    await signOut(store, fetcher, SITE);
    expect(calls[0]?.url).toBe(`${SITE}/api/auth/sign-out`);
    expect(calls[0]?.init?.method).toBe('POST');
    expect(new Headers(calls[0]?.init?.headers).get('Authorization')).toBe('Bearer t');
    expect(calls[0]?.init?.credentials).toBe('omit');
    expect(await store.sessionToken()).toBeUndefined();
    expect(await store.user()).toBeUndefined();
  });

  it('forgets it here even offline', async () => {
    const store = new AccountStore(new MemoryKV());
    await store.setSessionToken('t');
    await signOut(store, fetching(offline).fetcher, SITE);
    expect(await store.sessionToken()).toBeUndefined();
  });
});
