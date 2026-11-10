import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { AccountStore, ENTITLEMENT_KEY, SESSION_TOKEN_KEY, refreshEntitlement, type Entitlement, type KeyValue } from '../src/lib/account';
import { FillController } from '../src/lib/controller';
import type { Request } from '../src/lib/native-channel';
import { PassRelay, RELAYED_KEY, relayKeysChanged } from '../src/lib/pass-relay';
import { FakeChannel, FakeTabs } from './fakes';

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

const PREMIUM: Entitlement = { premium: true, plan: 'lifetime', expiresAt: null, token: 'jwt-1', checkedAt: 1 };

let kv: MemoryKV;
let store: AccountStore;
let channel: FakeChannel;
let relay: PassRelay;

/** What the app answers: the new app takes a pass, an app from before this message answers an error. */
function newApp(msg: Request): unknown {
  if (msg.type !== 'premium') return { type: msg.type, id: 1 };
  return 'pass' in msg ? { type: 'premium', id: 1, accepted: true } : { type: 'premium', id: 1 };
}

function premiumRequests(): Request[] {
  return channel.sent.filter((m) => m.type === 'premium');
}

/** Signed in; `null` when the site has not answered yet. */
async function signedIn(entitlement: Entitlement | null = PREMIUM): Promise<void> {
  await store.setSessionToken('session-1');
  if (entitlement) await store.setEntitlement(entitlement);
}

beforeEach(() => {
  kv = new MemoryKV();
  store = new AccountStore(kv);
  channel = new FakeChannel();
  channel.answer = newApp;
  relay = new PassRelay({ channel, account: store, kv });
});

describe('PassRelay', () => {
  it('hands a signed-in Premium account’s pass to the app and remembers the app has it', async () => {
    await signedIn();
    expect(await relay.sync()).toBe('delivered');
    expect(premiumRequests()).toEqual([{ type: 'premium', pass: 'jwt-1' }]);
    expect(kv.data.get(RELAYED_KEY)).toBe(true);
  });

  it('sends nothing when signed out and the app never had a pass from here', async () => {
    expect(await relay.sync()).toBe('none');
    expect(channel.sent).toEqual([]);
  });

  it('sends nothing while signed in but the site has not answered yet', async () => {
    await signedIn(null);
    expect(await relay.sync()).toBe('none');
    expect(channel.sent).toEqual([]);
  });

  it('takes the pass back on sign-out, once', async () => {
    await signedIn();
    await relay.sync();
    await store.clear();
    expect(await relay.sync()).toBe('none');
    expect(await relay.sync()).toBe('none');
    expect(premiumRequests()).toEqual([
      { type: 'premium', pass: 'jwt-1' },
      { type: 'premium', drop: 'signed-out' },
    ]);
    expect(kv.data.has(RELAYED_KEY)).toBe(false);
  });

  it('takes the pass back when the site answers 401', async () => {
    await signedIn();
    await relay.sync();
    const unauthorized = (async () => new Response('', { status: 401 })) as typeof fetch;
    await refreshEntitlement(store, unauthorized, 'https://passwordpie.com');
    await relay.sync();
    expect(premiumRequests().at(-1)).toEqual({ type: 'premium', drop: 'signed-out' });
  });

  it('takes the pass back when the site answers premium: false', async () => {
    await signedIn();
    await relay.sync();
    const free = (async () => Response.json({ premium: false, plan: null, expiresAt: null, token: null })) as typeof fetch;
    await refreshEntitlement(store, free, 'https://passwordpie.com');
    await relay.sync();
    expect(premiumRequests().at(-1)).toEqual({ type: 'premium', drop: 'no-premium' });
  });

  it('says unreachable when taking the pass back finds no app', async () => {
    await signedIn();
    await relay.sync();
    await store.clear();
    channel.answer = () => undefined;
    expect(await relay.sync()).toBe('unreachable');
  });

  it('stops taking it back from an app that does not know the message: it never held one', async () => {
    await signedIn();
    await relay.sync();
    await store.clear();
    channel.answer = () => ({ type: 'error', id: 1, code: 'bad-request' });
    expect(await relay.sync()).toBe('none');
    expect(kv.data.has(RELAYED_KEY)).toBe(false);
  });

  it('keeps trying to take it back until the app answers', async () => {
    await signedIn();
    await relay.sync();
    await store.clear();
    channel.answer = () => undefined;
    await relay.sync();
    expect(kv.data.get(RELAYED_KEY)).toBe(true);
    channel.answer = newApp;
    await relay.sync();
    expect(kv.data.has(RELAYED_KEY)).toBe(false);
    expect(premiumRequests().filter((m) => 'drop' in m)).toHaveLength(2);
  });

  it('says the app is unreachable when nothing answers, and does not count the pass as delivered', async () => {
    await signedIn();
    channel.answer = () => undefined;
    expect(await relay.sync()).toBe('unreachable');
    expect(kv.data.has(RELAYED_KEY)).toBe(false);
  });

  it('says unreachable when the Chrome host answers that the app is not running', async () => {
    await signedIn();
    channel.answer = () => ({ type: 'error', id: 1, code: 'app-unavailable' });
    expect(await relay.sync()).toBe('unreachable');
    expect(kv.data.has(RELAYED_KEY)).toBe(false);
  });

  it('treats an older app’s error as not taken, and does not hang', async () => {
    await signedIn();
    channel.answer = (msg) => (msg.type === 'premium' ? { type: 'error', id: 1, code: 'bad-request' } : undefined);
    expect(await relay.sync()).toBe('refused');
  });

  it('treats a pass the app did not accept as invalid, not as an old app', async () => {
    await signedIn();
    channel.answer = () => ({ type: 'premium', id: 1, accepted: false });
    expect(await relay.sync()).toBe('invalid');
    expect(kv.data.has(RELAYED_KEY)).toBe(false);
  });

  it('runs one sync at a time, in order', async () => {
    await signedIn();
    const order: string[] = [];
    let release: () => void = () => {};
    channel.answer = (msg) => {
      order.push('pass' in msg ? 'pass' : 'drop');
      return new Promise((resolve) => {
        release = () => resolve(newApp(msg));
      });
    };
    const first = relay.sync();
    await vi.waitFor(() => expect(order).toEqual(['pass']));
    await store.clear();
    const second = relay.sync();
    await new Promise((resolve) => setTimeout(resolve, 20));
    expect(order, 'the sign-out waits for the pass before it').toEqual(['pass']);
    release();
    await first;
    await vi.waitFor(() => expect(order).toEqual(['pass', 'drop']));
    release();
    await second;
    expect(kv.data.has(RELAYED_KEY)).toBe(false);
  });
});

describe('relayKeysChanged', () => {
  it('reacts to the session and the entitlement in local storage only', () => {
    expect(relayKeysChanged({ [SESSION_TOKEN_KEY]: {} }, 'local')).toBe(true);
    expect(relayKeysChanged({ [ENTITLEMENT_KEY]: {} }, 'local')).toBe(true);
    expect(relayKeysChanged({ user: {} }, 'local')).toBe(false);
    expect(relayKeysChanged({ [RELAYED_KEY]: {} }, 'local')).toBe(false);
    expect(relayKeysChanged({ [ENTITLEMENT_KEY]: {} }, 'sync')).toBe(false);
  });
});

describe('FillController and the relay', () => {
  let tabs: FakeTabs;

  beforeEach(() => {
    vi.useFakeTimers({ toFake: ['setTimeout', 'clearTimeout', 'Date'] });
    tabs = new FakeTabs();
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  it('hands the pass over when the connection to the app comes up', async () => {
    await signedIn();
    const controller = new FillController({ channel, tabs, relay });
    controller.start();
    await vi.advanceTimersByTimeAsync(100);
    expect(premiumRequests()).toEqual([{ type: 'premium', pass: 'jwt-1' }]);
  });

  /** The App Store build's Safari extension has no account, so it has no relay and sends nothing. */
  /** The host keeps Chrome's port open while the app is not running, so the app starting is a poke, not a new connect. */
  it('hands the pass over on a poke when the app could not be reached before, and only then', async () => {
    await signedIn();
    channel.answer = () => ({ type: 'error', id: 1, code: 'app-unavailable' });
    const controller = new FillController({ channel, tabs, relay });
    controller.start();
    await vi.advanceTimersByTimeAsync(100);
    expect(premiumRequests()).toHaveLength(1);
    channel.answer = newApp;
    channel.events?.onPoke();
    await vi.advanceTimersByTimeAsync(100);
    expect(premiumRequests()).toHaveLength(2);
    channel.events?.onPoke();
    await vi.advanceTimersByTimeAsync(100);
    expect(premiumRequests()).toHaveLength(2);
  });

  it('sends no premium request without a relay, as in the App Store build', async () => {
    await signedIn();
    const controller = new FillController({ channel, tabs });
    controller.start();
    await vi.advanceTimersByTimeAsync(100);
    expect(premiumRequests()).toEqual([]);
    expect(channel.sent.map((m) => m.type)).toEqual(['hello', 'tab']);
  });

  it('tells the popup whether the app has the pass', async () => {
    await signedIn();
    const controller = new FillController({ channel, tabs, relay });
    expect(await controller.appPremium()).toBe('delivered');
    channel.answer = () => undefined;
    expect(await controller.appPremium()).toBe('unreachable');
    expect(await new FillController({ channel, tabs }).appPremium()).toBe('none');
  });
});
