// Signing in on passwordpie.com: the site's /extension/connect page hands this browser's extension a bearer session over
// window.postMessage (docs/ACCOUNTS.md, "Signing in (extension)"). This is the content script's half; the background
// checks the token (site-session.ts). Not in the App Store build, whose content script never calls it.

export const SITE_SOURCE = 'passwordpie-site';
export const EXTENSION_SOURCE = 'passwordpie-extension';

/** `/extension/connect`, after an optional language prefix such as `/zh` or `/pt-BR`. */
const CONNECT_PATH = /^\/(?:[a-z]{2}(?:-[A-Za-z]{2,4})?\/)?extension\/connect\/?$/;

export function isConnectPath(pathname: string): boolean {
  return CONNECT_PATH.test(pathname);
}

/** Where the popup's "Sign in on passwordpie.com" goes. */
export function connectUrl(siteUrl: string): string {
  return `${siteUrl}/extension/connect`;
}

/** The content script's message to the background. */
export interface SiteSessionMessage {
  type: 'site-session';
  token: string;
}

export function parseSiteSessionMessage(raw: unknown): SiteSessionMessage | undefined {
  if (typeof raw !== 'object' || raw === null) return undefined;
  const { type, token } = raw as Record<string, unknown>;
  return type === 'site-session' && typeof token === 'string' && token.length > 0 ? { type, token } : undefined;
}

export type ConnectResult = { ok: true; email: string } | { ok: false };

/** The part of a message event the listener reads. */
export interface ConnectEvent {
  data: unknown;
  origin: string;
  source: unknown;
}

/** The page's window, as far as this needs it. */
export interface ConnectWindow {
  top: unknown;
  location: { origin: string; pathname: string };
  addEventListener(type: 'message', listener: (event: ConnectEvent) => void): void;
  postMessage(message: unknown, targetOrigin: string): void;
}

/**
 * Listens only in the top frame of the site, only to that page's own window, and acts only while the page is the
 * connect page. The path is read for each message, not once: the site's sign-in returns to the connect page by in-page
 * navigation, after this script started on /sign-in. Says `ready` at once (on the connect page) and to each `hello`;
 * hands a `session` token to `deliver` (the background) and tells the page `connected` or `failed`. Returns whether it
 * listens.
 */
export function startSiteConnect(win: ConnectWindow, siteUrl: string, deliver: (token: string) => Promise<ConnectResult>): boolean {
  if (win.top !== win) return false;
  if (!siteUrl || win.location.origin !== siteUrl) return false;
  const onConnectPage = () => isConnectPath(win.location.pathname);

  const post = (message: Record<string, unknown>) => win.postMessage({ source: EXTENSION_SOURCE, ...message }, siteUrl);
  let busy = false;

  win.addEventListener('message', (event) => {
    if (event.source !== win || event.origin !== siteUrl || !onConnectPage()) return;
    const data = event.data;
    if (typeof data !== 'object' || data === null) return;
    const { source, type, token } = data as Record<string, unknown>;
    if (source !== SITE_SOURCE) return;
    if (type === 'hello') {
      post({ type: 'ready' });
    } else if (type === 'session' && typeof token === 'string' && token.length > 0 && !busy) {
      busy = true;
      deliver(token)
        .catch((): ConnectResult => ({ ok: false }))
        .then((result) => post(result.ok ? { type: 'connected', email: result.email } : { type: 'failed' }))
        .finally(() => {
          busy = false;
        });
    }
  });

  if (onConnectPage()) post({ type: 'ready' });
  return true;
}
