// Hands this browser's Premium pass to the PasswordPie app, which has no sign-in of its own (docs/BROWSER_EXTENSION.md,
// "`premium`"). The pass is the token passwordpie.com issued for the app; the app checks its signature and keeps it in the
// keychain. Not in the App Store build, whose extension has no account.
import { ENTITLEMENT_KEY, SESSION_TOKEN_KEY, type Entitlement, type KeyValue } from './account';
import type { NativeChannel } from './native-channel';
import { APP_UNAVAILABLE, isRecord } from './protocol';

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

/** An answer from the app itself: not silence, and not the Chrome host saying the app is not running. */
function fromApp(answer: unknown): answer is Record<string, unknown> {
  return isRecord(answer) && !(answer.type === 'error' && answer.code === APP_UNAVAILABLE);
}

export class PassRelay {
  private queue: Promise<AppPremium> = Promise.resolve('none');
  /** What the last sync found. */
  private last: AppPremium | undefined;

  constructor(private readonly deps: { channel: NativeChannel; account: RelayAccount; kv: KeyValue }) {}

  /** Tells the app what this browser has now. One at a time, in order, so a sign-out never overtakes the pass before it. */
  sync(): Promise<AppPremium> {
    const run = async () => {
      this.last = await this.syncNow();
      return this.last;
    };
    this.queue = this.queue.then(run, run);
    return this.queue;
  }

  /**
   * The app poked: try again if the last try found no app. Chrome's host keeps the port open while PasswordPie is not
   * running, so the app starting shows up as its poke, not as a new connection.
   */
  catchUp(): void {
    if (this.last === 'unreachable') void this.sync();
  }

  private async syncNow(): Promise<AppPremium> {
    const { channel, account, kv } = this.deps;
    const session = await account.sessionToken();
    const entitlement = session ? await account.entitlement() : undefined;
    if (session && entitlement?.premium && entitlement.token) {
      const answer = await channel.request({ type: 'premium', pass: entitlement.token });
      if (!fromApp(answer)) return 'unreachable';
      if (answer.type !== 'premium' || answer.accepted !== true) return 'refused';
      await kv.set(RELAYED_KEY, true);
      return 'delivered';
    }
    // Only a sign-out, a 401 or `premium: false` takes the pass back. Signed in with no answer yet says nothing.
    const drop = !session ? 'signed-out' : entitlement && !entitlement.premium ? 'no-premium' : undefined;
    if (drop && (await kv.get(RELAYED_KEY)) === true) {
      const answer = await channel.request({ type: 'premium', drop });
      // Kept for later only when no app answered. An app that does not know the message never held a pass from here.
      if (!fromApp(answer)) return 'unreachable';
      await kv.remove(RELAYED_KEY);
    }
    return 'none';
  }
}
