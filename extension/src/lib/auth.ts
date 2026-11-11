// The passwordpie.com session, as a Better Auth bearer token and never cookies (`credentials: 'omit'`). Signing in
// happens on the site, which hands the token over (site-connect.ts); this only asks who it belongs to and ends it
// (docs/ACCOUNTS.md, "Signing in (extension)").
import type { AccountStore, AccountUser } from './account';

export type { AccountUser };

export type SessionAnswer = { kind: 'user'; user: AccountUser } | { kind: 'none' } | { kind: 'error'; message: string };

function bearer(token: string): Headers {
  return new Headers({ Authorization: `Bearer ${token}`, Accept: 'application/json' });
}

function userOf(body: unknown): AccountUser | undefined {
  if (typeof body !== 'object' || body === null) return undefined;
  const user = (body as Record<string, unknown>).user;
  if (typeof user !== 'object' || user === null) return undefined;
  const { email, name } = user as Record<string, unknown>;
  if (typeof email !== 'string' || !email) return undefined;
  return { email, ...(typeof name === 'string' && name ? { name } : {}) };
}

/**
 * `GET /api/auth/get-session` with this token. Better Auth answers 200 with `null` for an unknown session, and a 401 is
 * no session too; anything else that is not a user is "unknown", not a sign-out. A renewed token in `set-auth-token`
 * is passed back.
 */
export async function sessionUser(
  fetcher: typeof fetch,
  siteUrl: string,
  token: string,
): Promise<SessionAnswer & { renewedToken?: string }> {
  let response: Response;
  try {
    response = await fetcher(`${siteUrl}/api/auth/get-session`, { headers: bearer(token), credentials: 'omit' });
  } catch (cause) {
    return { kind: 'error', message: cause instanceof Error ? cause.message : 'passwordpie.com did not answer' };
  }
  if (response.status === 401 || response.status === 403) return { kind: 'none' };
  if (!response.ok) return { kind: 'error', message: `passwordpie.com answered ${response.status}` };
  const body: unknown = await response.json().catch(() => undefined);
  const user = userOf(body);
  if (!user) return { kind: 'none' };
  const renewed = response.headers.get('set-auth-token');
  return { kind: 'user', user, ...(renewed && renewed !== token ? { renewedToken: renewed } : {}) };
}

/** The signed-in user, or null. A network failure is not a sign-out: it returns the last user seen (throws if none). */
export async function currentUser(store: AccountStore, fetcher: typeof fetch, siteUrl: string): Promise<AccountUser | null> {
  const token = await store.sessionToken();
  if (!token) return null;
  const answer = await sessionUser(fetcher, siteUrl, token);
  if (answer.kind === 'error') {
    const saved = await store.user();
    if (saved) return saved;
    throw new Error(answer.message);
  }
  if (answer.kind === 'none') {
    await store.clear();
    return null;
  }
  if (answer.renewedToken) await store.setSessionToken(answer.renewedToken);
  await store.setUser(answer.user);
  return answer.user;
}

/** `POST /api/auth/sign-out` for this token, giving up after `timeoutMs`. Never throws. */
export async function endSession(fetcher: typeof fetch, siteUrl: string, token: string, timeoutMs = 5_000): Promise<void> {
  let timer: ReturnType<typeof setTimeout> | undefined;
  const headers = bearer(token);
  headers.set('Content-Type', 'application/json');
  try {
    await Promise.race([
      fetcher(`${siteUrl}/api/auth/sign-out`, { method: 'POST', headers, body: '{}', credentials: 'omit' }).catch(() => undefined),
      new Promise((resolve) => (timer = setTimeout(resolve, timeoutMs))),
    ]);
  } finally {
    clearTimeout(timer);
  }
}

/** Signs out on the site if it answers within 5 s, and locally in any case. Only this browser: the site stays signed in. */
export async function signOut(store: AccountStore, fetcher: typeof fetch, siteUrl: string): Promise<void> {
  const token = await store.sessionToken();
  try {
    if (token) await endSession(fetcher, siteUrl, token);
  } finally {
    await store.clear();
  }
}
