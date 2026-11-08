// Signing in to passwordpie.com from the popup, the mkext way: Better Auth with the bearer plugin, never cookies. The
// session token comes back in `set-auth-token` and is kept by `AccountStore`. Google uses `identity.getAuthToken` and the
// site's `POST /api/auth/extension/google` (docs/ACCOUNTS.md, "Signing in").
// Adapted from mkext's src/lib/auth.ts and src/lib/oauth.ts (https://github.com/MkThingsHQ/mkext, Apache-2.0).
import { createAuthClient } from 'better-auth/client';
import type { AccountStore, AccountUser } from './account';

export type { AccountUser };

export type SignInResult = { ok: true } | { ok: false; message: string };

export function makeAuthClient(store: AccountStore, siteUrl: string) {
  return createAuthClient({
    baseURL: siteUrl,
    fetchOptions: {
      credentials: 'omit',
      auth: { type: 'Bearer', token: async () => (await store.sessionToken()) ?? '' },
      onSuccess: async (ctx) => {
        const token = ctx.response.headers.get('set-auth-token');
        if (token) await store.setSessionToken(token);
      },
    },
  });
}

export type AuthClient = ReturnType<typeof makeAuthClient>;

function message(error: { message?: string; status?: number } | null | undefined, fallback: string): string {
  if (!error) return fallback;
  if (error.status === 401 || error.status === 403) return 'The email or password is not right.';
  if (error.status === 429) return 'Too many tries. Wait a minute and try again.';
  return error.message || fallback;
}

/** The signed-in user, or null. A network failure is not a sign-out: it returns the last user seen (throws if none). */
export async function currentUser(client: AuthClient, store: AccountStore): Promise<AccountUser | null> {
  if (!(await store.sessionToken())) return null;
  let result: Awaited<ReturnType<AuthClient['getSession']>>;
  try {
    result = await client.getSession();
  } catch (cause) {
    return (await store.user()) ?? fail(cause instanceof Error ? cause.message : undefined);
  }
  const { data, error } = result;
  if (error) {
    if (error.status === 401 || error.status === 403) {
      await store.clear();
      return null;
    }
    return (await store.user()) ?? fail(error.message);
  }
  const user = data?.user;
  if (!user) {
    await store.clear();
    return null;
  }
  const known: AccountUser = { email: user.email, ...(user.name ? { name: user.name } : {}) };
  await store.setUser(known);
  return known;
}

function fail(message: string | undefined): never {
  throw new Error(message || 'passwordpie.com did not answer');
}

export async function signInWithEmail(client: AuthClient, email: string, password: string): Promise<SignInResult> {
  try {
    const { error } = await client.signIn.email({ email, password });
    return error ? { ok: false, message: message(error, 'Could not sign in.') } : { ok: true };
  } catch {
    return { ok: false, message: 'Could not reach passwordpie.com.' };
  }
}

export async function signUpWithEmail(client: AuthClient, name: string, email: string, password: string): Promise<SignInResult> {
  try {
    const { error } = await client.signUp.email({ name, email, password });
    return error ? { ok: false, message: message(error, 'Could not create the account.') } : { ok: true };
  } catch {
    return { ok: false, message: 'Could not reach passwordpie.com.' };
  }
}

/** Signs out on the site if it answers within 5 s, and locally in any case. */
export async function signOut(client: AuthClient, store: AccountStore): Promise<void> {
  let timer: ReturnType<typeof setTimeout> | undefined;
  try {
    await Promise.race([client.signOut().catch(() => null), new Promise((resolve) => (timer = setTimeout(resolve, 5_000)))]);
  } finally {
    clearTimeout(timer);
    await store.clear();
  }
}

/** The part of `browser.identity` Google sign-in uses (Chromium only). */
export interface IdentityLike {
  getAuthToken?: (details: { interactive: boolean }) => Promise<string | { token?: string } | undefined>;
  removeCachedAuthToken?: (details: { token: string }) => Promise<void>;
}

export function googleAvailable(identity: IdentityLike | undefined, clientId: string): boolean {
  return Boolean(clientId) && typeof identity?.getAuthToken === 'function';
}

export async function signInWithGoogle(
  identity: IdentityLike | undefined,
  store: AccountStore,
  fetcher: typeof fetch,
  siteUrl: string,
): Promise<SignInResult> {
  if (typeof identity?.getAuthToken !== 'function') return { ok: false, message: 'Google sign-in is not available here.' };
  let accessToken: string | undefined;
  try {
    const result = await identity.getAuthToken({ interactive: true });
    accessToken = typeof result === 'string' ? result : result?.token;
  } catch (cause) {
    const text = cause instanceof Error ? cause.message : '';
    return { ok: false, message: /did not approve|cancel|closed/i.test(text) ? 'Google sign-in was cancelled.' : 'Google sign-in failed.' };
  }
  if (!accessToken) return { ok: false, message: 'Google sign-in was cancelled.' };
  let token: unknown;
  try {
    const response = await fetcher(`${siteUrl}/api/auth/extension/google`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ accessToken }),
      credentials: 'omit',
    });
    const body: unknown = await response.json().catch(() => null);
    token = response.ok && typeof body === 'object' && body !== null ? (body as Record<string, unknown>).token : undefined;
  } catch {
    return { ok: false, message: 'Could not reach passwordpie.com.' };
  }
  if (typeof token !== 'string' || !token) {
    // A rejected Google token stays cached per profile; drop it so the next try gets a fresh one.
    await identity.removeCachedAuthToken?.({ token: accessToken }).catch(() => undefined);
    return { ok: false, message: 'passwordpie.com did not accept this Google account.' };
  }
  await store.setSessionToken(token);
  return { ok: true };
}
