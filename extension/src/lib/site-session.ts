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
 * Asks the site whose `token` is. An unknown token, or no answer, keeps nothing and fails. A good one replaces whatever
 * account was kept (another account's Premium is forgotten, and the replaced session is ended on the site without
 * waiting), then the entitlement is refreshed. Connected even when only the entitlement could not be read: the popup
 * and the daily alarm ask again.
 */
export async function acceptSiteSession(token: string, store: AccountStore, fetcher: typeof fetch, siteUrl: string): Promise<ConnectResult> {
  const answer = await sessionUser(fetcher, siteUrl, token);
  if (answer.kind !== 'user') return { ok: false };
  const kept = answer.renewedToken ?? token;

  const [previousToken, previousUser] = await Promise.all([store.sessionToken(), store.user()]);
  if (previousUser?.email !== answer.user.email) await store.clear();
  await store.setSessionToken(kept);
  await store.setUser(answer.user);
  if (previousToken && previousToken !== kept) void endSession(fetcher, siteUrl, previousToken);

  await refreshEntitlement(store, fetcher, siteUrl).catch(() => undefined);
  return { ok: true, email: answer.user.email };
}
