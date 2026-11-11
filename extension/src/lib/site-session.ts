// The background's half of signing in on passwordpie.com: a token from the connect page is kept only after the site
// says whose it is (docs/ACCOUNTS.md, "Signing in (extension)"). Not in the App Store build.
import { AccountStore, refreshEntitlement } from './account';
import { endSession, sessionUser } from './auth';
import { isConnectPath, type ConnectResult } from './site-connect';

/** The part of `runtime.MessageSender` this checks. */
export interface SenderLike {
  id?: string;
  url?: string;
  frameId?: number;
}

/** Our content script, in the top frame of the site's connect page. */
export function fromConnectPage(sender: SenderLike, extensionId: string, siteUrl: string): boolean {
  if (sender.id !== extensionId) return false;
  // Safari may leave frameId out; the content script already listens only in the top frame.
  if (sender.frameId !== undefined && sender.frameId !== 0) return false;
  let url: URL;
  try {
    url = new URL(sender.url ?? '');
  } catch {
    return false;
  }
  return url.origin === siteUrl && isConnectPath(url.pathname);
}

/**
 * How long each step may hold the answer. The site's page gives up 15 s after `ready`, and that covers its own token
 * request too, so the answer must go out well inside it: otherwise the page says "failed" over a session that was kept.
 */
export const ACCEPT_WAITS = { sessionMs: 6_000, relayMs: 2_000, entitlementMs: 4_000 } as const;

/** The promise's result, or undefined once `ms` passed or it failed. The work itself goes on. */
function within<T>(work: Promise<T>, ms: number): Promise<T | undefined> {
  let timer: ReturnType<typeof setTimeout> | undefined;
  const late = new Promise<undefined>((resolve) => {
    timer = setTimeout(() => resolve(undefined), ms);
  });
  return Promise.race([work.catch(() => undefined), late]).finally(() => clearTimeout(timer));
}

/**
 * Asks the site whose `token` is. An unknown token, or no answer, keeps nothing and fails. A good one replaces whatever
 * account was kept (another account's Premium is forgotten, and the replaced session is ended on the site without
 * waiting), then the entitlement is refreshed. Connected even when only the entitlement could not be read, or was not
 * read in time: the popup and the daily alarm ask again.
 */
export async function acceptSiteSession(
  token: string,
  store: AccountStore,
  fetcher: typeof fetch,
  siteUrl: string,
  hooks: {
    /**
     * Runs while nothing is kept, when another account is replaced: the background syncs `PassRelay` here, so the app
     * gives back that account's pass even if the new account's entitlement then cannot be read.
     */
    accountChanged?: () => Promise<unknown>;
    waits?: { sessionMs: number; relayMs: number; entitlementMs: number };
  } = {},
): Promise<ConnectResult> {
  const waits = hooks.waits ?? ACCEPT_WAITS;
  const answer = await sessionUser(fetcher, siteUrl, token, waits.sessionMs);
  if (answer.kind !== 'user') return { ok: false };
  const kept = answer.renewedToken ?? token;

  const [previousToken, previousUser] = await Promise.all([store.sessionToken(), store.user()]);
  if (previousUser?.email !== answer.user.email) {
    await store.clear();
    if (previousToken && hooks.accountChanged) await within(hooks.accountChanged(), waits.relayMs);
  }
  await store.setSessionToken(kept);
  await store.setUser(answer.user);
  if (previousToken && previousToken !== kept) void endSession(fetcher, siteUrl, previousToken);

  const refreshed = await within(refreshEntitlement(store, fetcher, siteUrl), waits.entitlementMs);
  // The site ended the session in between: the refresh cleared the account, so this is not connected.
  if (refreshed && !refreshed.ok && refreshed.reason === 'signed-out') return { ok: false };
  return { ok: true, email: answer.user.email };
}
