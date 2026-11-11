import { QueryClient } from '@tanstack/react-query';
import { act } from 'react';
import { createRoot, type Root } from 'react-dom/client';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { Entitlement } from '../src/lib/account';
import type { AccountUser } from '../src/lib/auth';
import { Popup, planLine, type PopupApi } from '../src/components/popup';

declare global {
  var IS_REACT_ACT_ENVIRONMENT: boolean;
}
globalThis.IS_REACT_ACT_ENVIRONMENT = true;

const PREMIUM: Entitlement = { premium: true, plan: 'lifetime', expiresAt: null, token: 'jwt', checkedAt: 1 };
const FREE: Entitlement = { premium: false, plan: null, expiresAt: null, token: null, checkedAt: 1 };

let root: Root | undefined;
let container: HTMLDivElement;
let log: string[];
let user: AccountUser | null;
let entitlement: Entitlement;

function api(overrides: Partial<PopupApi> = {}): PopupApi {
  return {
    sellsPremium: true,
    accountEnabled: true,
    upgradeUrl: 'https://passwordpie.com/pricing',
    signInUrl: 'https://passwordpie.com/extension/connect',
    siteName: 'passwordpie.com',
    openPanel: async () => void log.push('open-panel'),
    panelShortcut: async () => '⌥⇧P',
    status: async () => ({}),
    appPremium: async () => {
      log.push('app-premium');
      return 'delivered';
    },
    user: async () => user,
    cachedEntitlement: async () => entitlement,
    refreshEntitlement: async () => {
      log.push('refresh');
      return { ok: true, entitlement };
    },
    signOut: async () => {
      log.push('sign-out');
      user = null;
    },
    redeem: async (code) => {
      log.push(`redeem ${code}`);
      if (code === 'PPIE-USED-USED-USED') return { ok: false, reason: 'used' };
      entitlement = { ...PREMIUM, plan: 'key' };
      return { ok: true, entitlement };
    },
    openUrl: (url) => void log.push(`open ${url}`),
    scanPage: async () => {
      log.push('scan-page');
      return { kind: 'sent', issuer: 'Demo', account: 'ada' };
    },
    ...overrides,
  };
}

async function render(a: PopupApi): Promise<void> {
  root = createRoot(container);
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } });
  await act(async () => root?.render(<Popup api={a} client={client} />));
  for (let i = 0; i < 3; i += 1) {
    await act(async () => {
      await new Promise((resolve) => setTimeout(resolve, 0));
    });
  }
}

function button(name: string): HTMLButtonElement {
  const found = Array.from(container.querySelectorAll('button')).find((b) => b.textContent === name);
  if (!found) throw new Error(`no button ${name}: ${container.textContent}`);
  return found;
}

function hasButton(name: string): boolean {
  return Array.from(container.querySelectorAll('button')).some((b) => b.textContent === name);
}

function hasField(): boolean {
  return container.querySelector('input') !== null;
}

async function type(label: string, value: string): Promise<void> {
  const input = Array.from(container.querySelectorAll('label')).find((l) => l.textContent?.startsWith(label))?.querySelector('input');
  if (!input) throw new Error(`no field ${label}`);
  const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value')?.set;
  await act(async () => {
    setter?.call(input, value);
    input.dispatchEvent(new Event('input', { bubbles: true }));
  });
}

async function click(name: string): Promise<void> {
  await act(async () => {
    button(name).click();
    await new Promise((resolve) => setTimeout(resolve, 0));
  });
  await act(async () => {
    await new Promise((resolve) => setTimeout(resolve, 0));
  });
}

beforeEach(() => {
  container = document.createElement('div');
  document.body.append(container);
  log = [];
  user = null;
  entitlement = FREE;
});

afterEach(async () => {
  await act(async () => root?.unmount());
  root = undefined;
  container.remove();
});

describe('Popup', () => {
  it('opens PasswordPie from the big button, signed in or not', async () => {
    await render(api());
    await click('Open PasswordPie');
    expect(log).toContain('open-panel');
  });

  it('scans the page only when the button is clicked, and says what happened', async () => {
    await render(api());
    expect(log).not.toContain('scan-page');
    expect(container.querySelector('[data-testid="scan-result"]')).toBeNull();
    await click('Scan QR code on this page');
    expect(log).toContain('scan-page');
    expect(container.querySelector('[data-testid="scan-result"]')?.textContent).toBe(
      'Demo · ada. Sent to PasswordPie. Choose the item there and press Add.',
    );
  });

  it('says why a scan found nothing to send', async () => {
    await render(api({ scanPage: async () => ({ kind: 'hotp' }) }));
    await click('Scan QR code on this page');
    expect(container.querySelector('[data-testid="scan-result"]')?.textContent).toContain('counter-based (HOTP)');
  });

  it('the App Store build scans too', async () => {
    await render(api({ accountEnabled: false, sellsPremium: false }));
    expect(hasButton('Scan QR code on this page')).toBe(true);
  });

  it('names the shortcut Chrome gave, and the app shortcut when it gave none', async () => {
    await render(api());
    expect(container.textContent).toContain('or press ⌥⇧P in the browser');
    await act(async () => root?.unmount());
    await render(api({ panelShortcut: async () => '' }));
    expect(container.textContent).toContain('⌘\\ by default');
  });

  it('signed out, says why to sign in and offers one button to the site, with no field to type in', async () => {
    await render(api());
    const account = container.querySelector('[aria-label="Account"]');
    expect(account?.textContent).toContain('Sign in with your PasswordPie account to fill two-step codes in the browser with Premium.');
    expect(hasButton('Sign in on passwordpie.com')).toBe(true);
    expect(hasField()).toBe(false);
    expect(account?.querySelectorAll('button')).toHaveLength(1);
    expect(container.textContent).not.toMatch(/Password\b|Create an account|Forgot password|Google/);
  });

  it('signing in opens the connect page on the site', async () => {
    await render(api());
    await click('Sign in on passwordpie.com');
    expect(log).toEqual(['open https://passwordpie.com/extension/connect']);
  });

  it('names the site the build signs in on', async () => {
    await render(api({ signInUrl: 'http://localhost:8787/extension/connect', siteName: 'localhost:8787' }));
    await click('Sign in on localhost:8787');
    expect(log).toContain('open http://localhost:8787/extension/connect');
  });

  it('refreshes the entitlement each time it opens', async () => {
    user = { email: 'ada@example.com' };
    entitlement = PREMIUM;
    await render(api());
    expect(log).toContain('refresh');
    expect(container.querySelector('[data-testid="plan"]')?.textContent).toBe('Premium · Lifetime');
    expect(hasButton('Upgrade')).toBe(false);
    expect(hasButton('Redeem')).toBe(false);
  });

  it('says nothing more about the Mac app when it has Premium from here', async () => {
    user = { email: 'ada@example.com' };
    entitlement = PREMIUM;
    await render(api());
    expect(log).toContain('app-premium');
    expect(container.querySelector('[data-testid="app-premium"]')).toBeNull();
  });

  it('does not claim the Mac app has Premium when the app is not reachable', async () => {
    user = { email: 'ada@example.com' };
    entitlement = PREMIUM;
    await render(api({ appPremium: async () => 'unreachable' }));
    const line = container.querySelector('[data-testid="app-premium"]');
    expect(line?.textContent).toBe('Open PasswordPie on this Mac to bring Premium to it.');
    expect(container.querySelectorAll('[data-testid="app-premium"]')).toHaveLength(1);
  });

  it('asks an app that did not take it to be updated', async () => {
    user = { email: 'ada@example.com' };
    entitlement = PREMIUM;
    await render(api({ appPremium: async () => 'refused' }));
    expect(container.querySelector('[data-testid="app-premium"]')?.textContent).toBe('Update PasswordPie on this Mac to bring Premium to it.');
  });

  it('shows no line when the app understood and did not take the pass', async () => {
    user = { email: 'ada@example.com' };
    entitlement = PREMIUM;
    await render(api({ appPremium: async () => 'invalid' }));
    expect(container.querySelector('[data-testid="app-premium"]')).toBeNull();
  });

  it('a free account asks the app nothing', async () => {
    user = { email: 'ada@example.com' };
    await render(api({ appPremium: async () => 'unreachable' }));
    expect(log).not.toContain('app-premium');
    expect(container.querySelector('[data-testid="app-premium"]')).toBeNull();
  });

  it('a free account sees Upgrade, which opens the pricing page, and a key field', async () => {
    user = { email: 'ada@example.com' };
    await render(api());
    await click('Upgrade');
    expect(log).toContain('open https://passwordpie.com/pricing');
    expect(hasButton('Redeem')).toBe(true);
  });

  it('redeems a key and turns Premium on', async () => {
    user = { email: 'ada@example.com' };
    await render(api());
    await type('Have a key?', 'ppie-test-test-test');
    await click('Redeem');
    expect(log).toContain('redeem ppie-test-test-test');
    expect(container.querySelector('[data-testid="plan"]')?.textContent).toBe('Premium · Key');
  });

  it('says a used key was used', async () => {
    user = { email: 'ada@example.com' };
    await render(api());
    await type('Have a key?', 'PPIE-USED-USED-USED');
    await click('Redeem');
    expect(container.querySelector('[role="alert"]')?.textContent).toBe('That key was already used.');
  });

  it('the App Store build has no Upgrade and no key field', async () => {
    user = { email: 'ada@example.com' };
    await render(api({ sellsPremium: false, upgradeUrl: undefined }));
    expect(hasButton('Upgrade')).toBe(false);
    expect(hasButton('Redeem')).toBe(false);
    expect(container.textContent).not.toMatch(/pricing|\$/);
  });

  it('the App Store build has no account and asks passwordpie.com nothing', async () => {
    const userCalls = vi.fn(async () => null);
    const refresh = vi.fn();
    await render(api({ accountEnabled: false, sellsPremium: false, upgradeUrl: undefined, user: userCalls, refreshEntitlement: refresh }));
    expect(container.querySelector('[aria-label="Account"]')).toBeNull();
    expect(container.textContent).not.toMatch(/Sign [Ii]n|Create an account|passwordpie\.com/);
    expect(hasButton('Open PasswordPie')).toBe(true);
    expect(userCalls).not.toHaveBeenCalled();
    expect(refresh).not.toHaveBeenCalled();
  });

  it('mentions a code that was not filled', async () => {
    await render(api({ status: async () => ({ codeSkippedOn: 'github.com' }) }));
    expect(container.textContent).toContain('The two-step code on github.com was not filled: it needs Premium.');
  });

  it('signs out', async () => {
    user = { email: 'ada@example.com' };
    await render(api());
    await click('Sign Out');
    expect(log).toContain('sign-out');
    expect(hasButton('Sign in on passwordpie.com')).toBe(true);
  });
});

describe('planLine', () => {
  it('names the plan and the end date', () => {
    expect(planLine(FREE)).toBe('Free');
    expect(planLine(null)).toBe('Free');
    expect(planLine({ ...PREMIUM, plan: 'yearly', expiresAt: '2027-11-08T12:00:00Z' })).toMatch(/^Premium · Yearly · until /);
  });
});
