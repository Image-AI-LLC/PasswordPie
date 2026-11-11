import { SHOW_TIMEOUT_MS, type NativeChannel } from './native-channel';
import {
  EXTENSION_VERSION,
  PROTOCOL_VERSION,
  WEBSITE_URL,
  APP_NOT_RESPONDING,
  CODE_LIFETIME_MS,
  codeOfAnswer,
  expectCodeOfTabAnswer,
  fillOfTabAnswer,
  originOf,
  parseContentMessage,
  parseFillResult,
  reportableUrl,
  type Credentials,
  type FillMessage,
  type FrameMessage,
  type TabFill,
  type TabReason,
} from './protocol';
import { systemTimers, type TimerHandle, type Timers } from './timers';
import { wantsIcon } from './site-icon';

export const REPORT_DEBOUNCE_MS = 100;
/** How long after the note about Premium a click on its Upgrade counts: the note shows for 8 s. */
export const UPGRADE_WINDOW_MS = 10_000;
const WINDOW_ID_NONE = -1;

export interface TabInfo {
  id?: number;
  url?: string;
  active?: boolean;
  /** The icon the browser shows for the tab (Chrome; Safari leaves it out). */
  favIconUrl?: string;
}

export interface FrameInfo {
  frameId: number;
  url: string;
}

export interface MessageSender {
  tab?: TabInfo;
  frameId?: number;
  /** The URL of the frame that sent the message. */
  url?: string;
}

/** The browser APIs the controller uses, injectable for tests. */
export interface TabsAdapter {
  /** The active tab of the last focused window. */
  activeTab(): Promise<TabInfo | undefined>;
  frames(tabId: number): Promise<FrameInfo[]>;
  /** Resolves with the frame's answer; rejects or resolves undefined when no content script answered. */
  sendFill(tabId: number, frameId: number, msg: FillMessage): Promise<unknown>;
  /** The two-step code messages; resolves with the frame's answer. */
  sendToFrame(tabId: number, frameId: number, msg: FrameMessage): Promise<unknown>;
  /** Opens `url` in a new tab of the current window. */
  openTab(url: string): Promise<unknown>;
  /** The tab's icon as base64 PNG (at most 128 × 128 and 64 KB), if the tab is still on `origin`. */
  tabIcon?(tabId: number, favIconUrl: string | undefined, origin: string): Promise<string | undefined>;
}

/** A two-step code field to wait for, after a fill of an account that has one. Holds no secret. */
interface CodeWait {
  origin: string;
  expiresAt: number;
  expiry: TimerHandle;
  asking: boolean;
}

interface Entry extends Credentials {
  tabId: number;
  expiresAt: number;
  expiry: TimerHandle;
}

/**
 * The background's logic: reports the active tab to the app and fills the answer into the tab it was for.
 * Credentials live only in `entries` (memory) and are dropped once the password filled, on tab close, or when what was
 * left of the app's 30 s runs out.
 */
export class FillController {
  private readonly channel: NativeChannel;
  private readonly tabs: TabsAdapter;
  private readonly timers: Timers;
  private readonly entries = new Map<number, Entry>();
  private readonly codeWaits = new Map<number, CodeWait>();
  /** The frame of each tab that shows the note about Premium, and until when its Upgrade counts. */
  private readonly hints = new Map<number, { frameId: number; until: number }>();
  private reportTimer: TimerHandle | undefined;
  private pendingReason: TabReason = 'startup';

  constructor(deps: { channel: NativeChannel; tabs: TabsAdapter; timers?: Timers }) {
    this.channel = deps.channel;
    this.tabs = deps.tabs;
    this.timers = deps.timers ?? systemTimers;
  }

  start(): void {
    this.channel.start({
      onConnect: () => {
        void this.channel.request({ type: 'hello', version: PROTOCOL_VERSION, extension: EXTENSION_VERSION });
        this.report('startup');
      },
      onPoke: () => this.report('poke'),
    });
  }

  /**
   * The toolbar button and the shortcut: ask the app to open its panel, as its own shortcut does. Carries nothing. The host starts the app
   * when it is installed but not running; with no app to answer, the website opens instead, to download it.
   */
  async showPanel(): Promise<void> {
    const answer = await this.channel.request({ type: 'show' }, SHOW_TIMEOUT_MS);
    if (typeof answer === 'object' && answer !== null && 'type' in answer) {
      if (answer.type === 'show') return;
      // Installed and running, but not answering: the download page would not help.
      if (answer.type === 'error' && 'code' in answer && answer.code === APP_NOT_RESPONDING) return;
    }
    await this.tabs.openTab(WEBSITE_URL);
  }

  /** Report the active tab soon; bursts of events within 100 ms make one report. */
  report(reason: TabReason): void {
    this.pendingReason = reason;
    if (this.reportTimer !== undefined) this.timers.clearTimeout(this.reportTimer);
    this.reportTimer = this.timers.setTimeout(() => {
      this.reportTimer = undefined;
      void this.reportNow(this.pendingReason);
    }, REPORT_DEBOUNCE_MS);
  }

  tabActivated(): void {
    this.report('activated');
  }

  tabUpdated(tabId: number, change: { status?: string; url?: string }, tab: TabInfo): void {
    if (change.status === 'complete') {
      void this.refill(tabId, tab.url);
      if (tab.url !== undefined && originOf(tab.url) === this.liveCodeWait(tabId)?.origin) void this.watchCode(tabId);
    }
    if (tab.active && (change.status === 'complete' || change.url !== undefined)) this.report('updated');
  }

  windowFocusChanged(windowId: number): void {
    if (windowId !== WINDOW_ID_NONE) this.report('focus');
  }

  tabRemoved(tabId: number): void {
    this.drop(tabId);
    this.dropCodeWait(tabId);
    this.hints.delete(tabId);
  }

  runtimeMessage(value: unknown, sender: MessageSender): void {
    const msg = parseContentMessage(value);
    const tabId = sender.tab?.id;
    if (!msg || tabId === undefined) return;
    if (msg.type === 'focus') {
      if (sender.frameId === 0 && sender.tab?.active) this.report('focus');
    } else if (msg.type === 'ready') {
      // A content script started after the answer arrived (document_idle can come after "complete").
      if (sender.frameId !== undefined) {
        void this.fillTab(tabId, sender.frameId);
        void this.watchCode(tabId, sender.frameId);
      }
    } else if (msg.type === 'code-field') {
      if (sender.frameId !== undefined && sender.url !== undefined) void this.requestCode(tabId, sender.frameId, sender.url);
    } else if (msg.type === 'upgrade') {
      this.upgrade(tabId, sender.frameId);
    } else {
      this.drop(tabId);
    }
  }

  /**
   * "Upgrade" in the note about Premium: the app opens its Premium window, where it sells or says where to buy. Only from
   * the frame the note was sent to, while it shows, so a page cannot ask for the window.
   */
  private upgrade(tabId: number, frameId: number | undefined): void {
    const hint = this.hints.get(tabId);
    if (!hint || hint.frameId !== frameId || this.timers.now() > hint.until) return;
    this.hints.delete(tabId);
    void this.channel.request({ type: 'upgrade' });
  }

  hasEntry(tabId: number): boolean {
    return this.entries.has(tabId);
  }

  private async reportNow(reason: TabReason): Promise<void> {
    let tab: TabInfo | undefined;
    try {
      tab = await this.tabs.activeTab();
    } catch {
      tab = undefined;
    }
    const url = reportableUrl(tab?.url);
    const tabId = tab?.id;
    const answer = await this.channel.request({ type: 'tab', url, reason });
    if (wantsIcon(answer) && tabId !== undefined) void this.sendIcon(tabId, tab?.favIconUrl, url);
    const fill = fillOfTabAnswer(answer);
    // A code just added from a scan of this page: watch for its field, as after a fill. Nothing secret in it.
    const expected = expectCodeOfTabAnswer(answer);
    if (!fill && expected && tabId !== undefined && url !== '' && expected.origin === originOf(url)) {
      this.expectCode(tabId, expected.origin, expected.lifetimeMs);
      await this.watchCode(tabId);
      return;
    }
    // The fill is for the tab this report named, and only for the origin of the URL reported.
    if (!fill || tabId === undefined || url === '' || fill.origin !== originOf(url)) return;
    this.keep(tabId, fill);
    if (fill.otp) this.expectCode(tabId, fill.origin);
    else this.dropCodeWait(tabId);
    await this.fillTab(tabId);
    await this.watchCode(tabId);
  }

  private expectCode(tabId: number, origin: string, lifetimeMs = CODE_LIFETIME_MS): void {
    this.dropCodeWait(tabId);
    const expiry = this.timers.setTimeout(() => this.dropCodeWait(tabId), lifetimeMs);
    this.codeWaits.set(tabId, { origin, expiresAt: this.timers.now() + lifetimeMs, expiry, asking: false });
  }

  private dropCodeWait(tabId: number): void {
    const wait = this.codeWaits.get(tabId);
    if (!wait) return;
    this.timers.clearTimeout(wait.expiry);
    this.codeWaits.delete(tabId);
  }

  private liveCodeWait(tabId: number): CodeWait | undefined {
    const wait = this.codeWaits.get(tabId);
    if (wait && this.timers.now() >= wait.expiresAt) {
      this.dropCodeWait(tabId);
      return undefined;
    }
    return wait;
  }

  /** Asks the tab's frames of the wait's origin (or just `onlyFrameId`) to look for a code field. */
  private async watchCode(tabId: number, onlyFrameId?: number): Promise<void> {
    const wait = this.liveCodeWait(tabId);
    if (!wait) return;
    let frames: FrameInfo[];
    try {
      frames = await this.tabs.frames(tabId);
    } catch {
      return;
    }
    const msg: FrameMessage = { type: 'watch-code', origin: wait.origin, waitMs: Math.max(0, wait.expiresAt - this.timers.now()) };
    const targets = frames.filter(
      (frame) => originOf(frame.url) === wait.origin && (onlyFrameId === undefined || frame.frameId === onlyFrameId),
    );
    await Promise.all(targets.map((frame) => this.tabs.sendToFrame(tabId, frame.frameId, msg).catch(() => undefined)));
  }

  /** A frame found an empty code field: ask the app, once per fill, and fill or hint in that frame. */
  private async requestCode(tabId: number, frameId: number, frameUrl: string): Promise<void> {
    const wait = this.liveCodeWait(tabId);
    if (!wait || wait.asking || originOf(frameUrl) !== wait.origin) return;
    wait.asking = true;
    // Whether there is Premium is the app's to say: it answers with the code, or that it has none to give.
    const answer = codeOfAnswer(await this.channel.request({ type: 'code', url: `${wait.origin}/` }));
    if (this.codeWaits.get(tabId) === wait) this.dropCodeWait(tabId);
    if (answer.kind === 'code' && answer.origin === wait.origin) {
      await this.tabs.sendToFrame(tabId, frameId, { type: 'code', origin: wait.origin, code: answer.code }).catch(() => undefined);
    } else if (answer.kind === 'no-premium') {
      this.hints.set(tabId, { frameId, until: this.timers.now() + UPGRADE_WINDOW_MS });
      const hint: FrameMessage = { type: 'code-hint', origin: wait.origin };
      await this.tabs.sendToFrame(tabId, frameId, hint).catch(() => undefined);
    }
  }

  /** The app has an account on this site but no icon for it: send the one the browser shows for the tab. */
  private async sendIcon(tabId: number, favIconUrl: string | undefined, url: string): Promise<void> {
    const origin = originOf(url);
    if (!origin || !this.tabs.tabIcon) return;
    let png: string | undefined;
    try {
      png = await this.tabs.tabIcon(tabId, favIconUrl, origin);
    } catch {
      return;
    }
    if (png) await this.channel.request({ type: 'icon', origin, png }).catch(() => undefined);
  }

  private keep(tabId: number, fill: TabFill): void {
    this.drop(tabId);
    const credentials: Credentials = { origin: fill.origin, username: fill.username, password: fill.password };
    const expiry = this.timers.setTimeout(() => this.drop(tabId), fill.lifetimeMs);
    this.entries.set(tabId, { ...credentials, tabId, expiresAt: this.timers.now() + fill.lifetimeMs, expiry });
  }

  private drop(tabId: number): void {
    const entry = this.entries.get(tabId);
    if (!entry) return;
    this.timers.clearTimeout(entry.expiry);
    this.entries.delete(tabId);
  }

  private liveEntry(tabId: number): Entry | undefined {
    const entry = this.entries.get(tabId);
    if (entry && this.timers.now() >= entry.expiresAt) {
      this.drop(tabId);
      return undefined;
    }
    return entry;
  }

  /** The tab finished loading: a page of the same origin gets the fill again (two-step sign-in). */
  private async refill(tabId: number, url: string | undefined): Promise<void> {
    const entry = this.liveEntry(tabId);
    if (!entry || url === undefined || originOf(url) !== entry.origin) return;
    await this.fillTab(tabId);
  }

  /** Sends the fill to the tab's frames of the entry's origin (or just `onlyFrameId`, if it is one of them). */
  private async fillTab(tabId: number, onlyFrameId?: number): Promise<void> {
    const entry = this.liveEntry(tabId);
    if (!entry) return;
    let frames: FrameInfo[];
    try {
      frames = await this.tabs.frames(tabId);
    } catch {
      return;
    }
    if (this.liveEntry(tabId) !== entry) return; // closed, filled or expired meanwhile
    const msg: FillMessage = {
      type: 'fill',
      origin: entry.origin,
      username: entry.username,
      password: entry.password,
      waitMs: Math.max(0, entry.expiresAt - this.timers.now()),
    };
    const targets = frames.filter(
      (frame) => originOf(frame.url) === entry.origin && (onlyFrameId === undefined || frame.frameId === onlyFrameId),
    );
    await Promise.all(
      targets.map(async (frame) => {
        let answer: unknown;
        try {
          answer = await this.tabs.sendFill(tabId, frame.frameId, msg);
        } catch {
          return; // no content script in that frame (yet)
        }
        if (parseFillResult(answer)?.password && this.entries.get(tabId) === entry) this.drop(tabId);
      }),
    );
  }
}
