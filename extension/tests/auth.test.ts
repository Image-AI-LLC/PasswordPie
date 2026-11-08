import { describe, expect, it } from 'vitest';
import { AccountStore, type KeyValue } from '../src/lib/account';
import { currentUser, type AuthClient } from '../src/lib/auth';

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

function clientWith(getSession: () => Promise<unknown>): AuthClient {
  return { getSession } as unknown as AuthClient;
}

describe('currentUser', () => {
  it('returns the saved user when the site cannot be reached, and clears on a 401', async () => {
    const store = new AccountStore(new MemoryKV());
    await store.setSessionToken('t');
    const ok = clientWith(async () => ({ data: { user: { email: 'a@b.c', name: 'A' } }, error: null }));
    expect(await currentUser(ok, store)).toEqual({ email: 'a@b.c', name: 'A' });

    const offline = clientWith(async () => {
      throw new TypeError('Failed to fetch');
    });
    expect(await currentUser(offline, store)).toEqual({ email: 'a@b.c', name: 'A' });

    const denied = clientWith(async () => ({ data: null, error: { status: 401, message: 'no' } }));
    expect(await currentUser(denied, store)).toBeNull();
    expect(await store.sessionToken()).toBeUndefined();
    expect(await store.user()).toBeUndefined();
  });

  it('throws when offline with nothing saved', async () => {
    const store = new AccountStore(new MemoryKV());
    await store.setSessionToken('t');
    const offline = clientWith(async () => {
      throw new TypeError('Failed to fetch');
    });
    await expect(currentUser(offline, store)).rejects.toThrow('Failed to fetch');
  });
});
