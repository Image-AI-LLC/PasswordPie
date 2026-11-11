import { beforeEach, describe, expect, it } from 'vitest';
import {
  EXTENSION_SOURCE,
  SITE_SOURCE,
  connectUrl,
  isConnectPath,
  parseSiteSessionMessage,
  startSiteConnect,
  type ConnectEvent,
  type ConnectResult,
  type ConnectWindow,
} from '../src/lib/site-connect';

const SITE = 'https://passwordpie.com';

/** The page's window as the content script sees it: what it posted, and a way to deliver a message event. */
class FakeWindow implements ConnectWindow {
  top: unknown = this;
  location: { origin: string; pathname: string };
  posted: Array<{ msg: unknown; targetOrigin: string }> = [];
  private listeners: Array<(event: ConnectEvent) => void> = [];

  constructor(url = `${SITE}/extension/connect`) {
    const u = new URL(url);
    this.location = { origin: u.origin, pathname: u.pathname };
  }

  addEventListener(_type: 'message', listener: (event: ConnectEvent) => void): void {
    this.listeners.push(listener);
  }

  postMessage(msg: unknown, targetOrigin: string): void {
    this.posted.push({ msg, targetOrigin });
  }

  /** A message from the page itself, unless `from` says otherwise. */
  receive(data: unknown, from: { origin?: string; source?: unknown } = {}): void {
    const event: ConnectEvent = { data, origin: from.origin ?? SITE, source: 'source' in from ? from.source : this };
    for (const listener of this.listeners) listener(event);
  }

  get listening(): boolean {
    return this.listeners.length > 0;
  }

  sent(type: string): unknown[] {
    return this.posted.map((p) => p.msg).filter((m) => (m as { type?: string }).type === type);
  }
}

const flush = () => new Promise((resolve) => setTimeout(resolve, 0));

let delivered: string[];
let answer: ConnectResult;
const deliver = async (token: string): Promise<ConnectResult> => {
  delivered.push(token);
  return answer;
};

beforeEach(() => {
  delivered = [];
  answer = { ok: true, email: 'ada@example.com' };
});

describe('isConnectPath', () => {
  it('takes /extension/connect, with or without a language prefix', () => {
    expect(isConnectPath('/extension/connect')).toBe(true);
    expect(isConnectPath('/extension/connect/')).toBe(true);
    expect(isConnectPath('/zh/extension/connect')).toBe(true);
    expect(isConnectPath('/pt-BR/extension/connect')).toBe(true);
  });

  it('takes no other page', () => {
    for (const path of ['/', '/sign-in', '/extension', '/extension/connect/x', '/a/b/extension/connect', '/evil/extension/connect', '/extension/connected']) {
      expect(isConnectPath(path), path).toBe(false);
    }
  });
});

describe('connectUrl', () => {
  it('is the site connect page', () => {
    expect(connectUrl(SITE)).toBe('https://passwordpie.com/extension/connect');
  });
});

describe('startSiteConnect', () => {
  it('says ready at start, and again to each hello, always to the site origin only', () => {
    const win = new FakeWindow();
    expect(startSiteConnect(win, SITE, deliver)).toBe(true);
    expect(win.posted).toEqual([{ msg: { source: EXTENSION_SOURCE, type: 'ready' }, targetOrigin: SITE }]);
    win.receive({ source: SITE_SOURCE, type: 'hello' });
    win.receive({ source: SITE_SOURCE, type: 'hello' });
    expect(win.sent('ready')).toHaveLength(3);
    expect(win.posted.every((p) => p.targetOrigin === SITE)).toBe(true);
  });

  it('hands the session token to the background and tells the page who is signed in', async () => {
    const win = new FakeWindow();
    startSiteConnect(win, SITE, deliver);
    win.receive({ source: SITE_SOURCE, type: 'session', token: 'tok-1' });
    await flush();
    expect(delivered).toEqual(['tok-1']);
    expect(win.sent('connected')).toEqual([{ source: EXTENSION_SOURCE, type: 'connected', email: 'ada@example.com' }]);
  });

  it('tells the page when the background did not take it', async () => {
    answer = { ok: false };
    const win = new FakeWindow();
    startSiteConnect(win, SITE, deliver);
    win.receive({ source: SITE_SOURCE, type: 'session', token: 'bad' });
    await flush();
    expect(win.sent('failed')).toEqual([{ source: EXTENSION_SOURCE, type: 'failed' }]);
    expect(win.sent('connected')).toHaveLength(0);
  });

  it('says failed when the background cannot be reached', async () => {
    const win = new FakeWindow();
    startSiteConnect(win, SITE, async () => {
      throw new Error('Extension context invalidated.');
    });
    win.receive({ source: SITE_SOURCE, type: 'session', token: 'tok-1' });
    await flush();
    expect(win.sent('failed')).toHaveLength(1);
  });

  it('ignores a message from another origin', async () => {
    const win = new FakeWindow();
    startSiteConnect(win, SITE, deliver);
    win.receive({ source: SITE_SOURCE, type: 'session', token: 'tok-1' }, { origin: 'https://evil.example' });
    win.receive({ source: SITE_SOURCE, type: 'hello' }, { origin: 'https://evil.example' });
    await flush();
    expect(delivered).toEqual([]);
    expect(win.sent('ready')).toHaveLength(1);
  });

  it('ignores a message from another window, such as a frame on the page', async () => {
    const win = new FakeWindow();
    startSiteConnect(win, SITE, deliver);
    win.receive({ source: SITE_SOURCE, type: 'session', token: 'tok-1' }, { source: {} });
    win.receive({ source: SITE_SOURCE, type: 'session', token: 'tok-1' }, { source: null });
    await flush();
    expect(delivered).toEqual([]);
  });

  it('ignores its own messages and anything not from the site page', async () => {
    const win = new FakeWindow();
    startSiteConnect(win, SITE, deliver);
    for (const data of [
      { source: EXTENSION_SOURCE, type: 'session', token: 'tok-1' },
      { type: 'session', token: 'tok-1' },
      { source: SITE_SOURCE, type: 'session' },
      { source: SITE_SOURCE, type: 'session', token: '' },
      { source: SITE_SOURCE, type: 'session', token: 42 },
      'session',
      null,
    ]) {
      win.receive(data);
    }
    await flush();
    expect(delivered).toEqual([]);
    expect(win.sent('ready')).toHaveLength(1);
  });

  it('hands over one session at a time', async () => {
    const win = new FakeWindow();
    let release: (r: ConnectResult) => void = () => undefined;
    startSiteConnect(win, SITE, (token) => {
      delivered.push(token);
      return new Promise((resolve) => (release = resolve));
    });
    win.receive({ source: SITE_SOURCE, type: 'session', token: 'tok-1' });
    win.receive({ source: SITE_SOURCE, type: 'session', token: 'tok-2' });
    expect(delivered).toEqual(['tok-1']);
    release({ ok: true, email: 'ada@example.com' });
    await flush();
    win.receive({ source: SITE_SOURCE, type: 'session', token: 'tok-3' });
    expect(delivered).toEqual(['tok-1', 'tok-3']);
  });

  it('does not listen on another page of the site', () => {
    for (const url of [`${SITE}/`, `${SITE}/sign-in`, `${SITE}/account`, `${SITE}/extension/connect/other`]) {
      const win = new FakeWindow(url);
      expect(startSiteConnect(win, SITE, deliver), url).toBe(false);
      expect(win.listening).toBe(false);
      expect(win.posted).toEqual([]);
    }
  });

  it('listens on the connect page with a language prefix', () => {
    const win = new FakeWindow(`${SITE}/zh/extension/connect`);
    expect(startSiteConnect(win, SITE, deliver)).toBe(true);
  });

  it('does not listen on another site, even on the same path', () => {
    for (const url of ['https://evil.example/extension/connect', 'http://passwordpie.com/extension/connect', 'https://www.passwordpie.com/extension/connect']) {
      const win = new FakeWindow(url);
      expect(startSiteConnect(win, SITE, deliver), url).toBe(false);
      expect(win.listening).toBe(false);
    }
  });

  it('does not listen in a frame', () => {
    const win = new FakeWindow();
    win.top = {};
    expect(startSiteConnect(win, SITE, deliver)).toBe(false);
    expect(win.listening).toBe(false);
    expect(win.posted).toEqual([]);
  });
});

describe('parseSiteSessionMessage', () => {
  it('reads the content script message to the background', () => {
    expect(parseSiteSessionMessage({ type: 'site-session', token: 'tok-1' })).toEqual({ type: 'site-session', token: 'tok-1' });
    expect(parseSiteSessionMessage({ type: 'site-session', token: '' })).toBeUndefined();
    expect(parseSiteSessionMessage({ type: 'site-session' })).toBeUndefined();
    expect(parseSiteSessionMessage({ type: 'ready' })).toBeUndefined();
    expect(parseSiteSessionMessage(null)).toBeUndefined();
  });
});
