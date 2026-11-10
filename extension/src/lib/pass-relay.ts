// Hands this browser's Premium pass to the PasswordPie app, which has no sign-in of its own (docs/BROWSER_EXTENSION.md,
// "`premium`"). The pass is the token passwordpie.com issued for the app; the app checks its signature and keeps it in the
// keychain. Not in the App Store build, whose extension has no account.
import { ENTITLEMENT_KEY, SESSION_TOKEN_KEY, type Entitlement, type KeyValue } from './account';
import type { NativeChannel } from './native-channel';
import { isRecord } from './protocol';

/** Set while the app holds a pass from this browser, so taking it back reaches the app even after a restart. */
export const RELAYED_KEY = 'app-has-pass';

/**
 * What the app has from this browser:
 * - `delivered`: it took the pass;
 * - `unreachable`: nothing answered (PasswordPie is not running);
 * - `refused`: it answered but did not take it (an app from before this message, or a pass that did not check);
 * - `none`: there was nothing to hand over.
 */
export type AppPremium = 'delivered' | 'unreachable' | 'refused' | 'none';

/** Where the relay reads the account: `AccountStore`. */
export interface RelayAccount {
  sessionToken(): Promise<string | undefined>;
  entitlement(): Promise<Entitlement | undefined>;
}

/** A storage change that can change what the app should hold: sign-in, sign-out, a renewal, a 401. */
export function relayKeysChanged(changes: Record<string, unknown>, area: string): boolean {
  return area === 'local' && (SESSION_TOKEN_KEY in changes || ENTITLEMENT_KEY in changes);
}

export class PassRelay {
  private queue: Promise<AppPremium> = Promise.resolve('none');

  constructor(private readonly deps: { channel: NativeChannel; account: RelayAccount; kv: KeyValue }) {}

  /** Tells the app what this browser has now. One at a time, in order, so a sign-out never overtakes the pass before it. */
  sync(): Promise<AppPremium> {
    const run = () => this.syncNow();
    this.queue = this.queue.then(run, run);
    return this.queue;
  }

  private async syncNow(): Promise<AppPremium> {
    const { channel, account, kv } = this.deps;
    const session = await account.sessionToken();
    const entitlement = session ? await account.entitlement() : undefined;
    if (session && entitlement?.premium && entitlement.token) {
      const answer = await channel.request({ type: 'premium', pass: entitlement.token });
      if (!isRecord(answer)) return 'unreachable';
      if (answer.type !== 'premium' || answer.accepted !== true) return 'refused';
      await kv.set(RELAYED_KEY, true);
      return 'delivered';
    }
    // Only a sign-out, a 401 or `premium: false` takes the pass back. Signed in with no answer yet says nothing.
    const drop = !session ? 'signed-out' : entitlement && !entitlement.premium ? 'no-premium' : undefined;
    if (drop && (await kv.get(RELAYED_KEY)) === true) {
      const answer = await channel.request({ type: 'premium', drop });
      if (isRecord(answer) && answer.type === 'premium') await kv.remove(RELAYED_KEY);
    }
    return 'none';
  }
}
