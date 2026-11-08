import { SHOW_TIMEOUT_MS, type NativeChannel } from './native-channel';
import {
  EXTENSION_VERSION,
  PROTOCOL_VERSION,
  WEBSITE_URL,
  APP_NOT_RESPONDING,
  fillOfTabAnswer,
  originOf,
  parseContentMessage,
  parseFillResult,
  reportableUrl,
  type Credentials,
  type FillMessage,
  type TabFill,
  type TabReason,
} from './protocol';
import { systemTimers, type TimerHandle, type Timers } from './timers';

export const REPORT_DEBOUNCE_MS = 100;
const WINDOW_ID_NONE = -1;

export interface TabInfo {
  id?: number;
  url?: string;
  active?: boolean;
}

export interface FrameInfo {
  frameId: number;
  url: string;
}

export interface MessageSender {
  tab?: TabInfo;
  frameId?: number;
}

/** The browser APIs the controller uses, injectable for tests. */
export interface TabsAdapter {
  /** The active tab of the last focused window. */
  activeTab(): Promise<TabInfo | undefined>;
  frames(tabId: number): Promise<FrameInfo[]>;
  /** Resolves with the frame's answer; rejects or resolves undefined when no content script answered. */
  sendFill(tabId: number, frameId: number, msg: FillMessage): Promise<unknown>;
  /** Opens `url` in a new tab of the current window. */
  openTab(url: string): Promise<unknown>;
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
   * The toolbar button: ask the app to open its panel, as its shortcut does. Carries nothing. The host starts the app
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
    if (change.status === 'complete') void this.refill(tabId, tab.url);
    if (tab.active && (change.status === 'complete' || change.url !== undefined)) this.report('updated');
  }

  windowFocusChanged(windowId: number): void {
    if (windowId !== WINDOW_ID_NONE) this.report('focus');
  }

  tabRemoved(tabId: number): void {
    this.drop(tabId);
  }

  runtimeMessage(value: unknown, sender: MessageSender): void {
    const msg = parseContentMessage(value);
    const tabId = sender.tab?.id;
    if (!msg || tabId === undefined) return;
    if (msg.type === 'focus') {
      if (sender.frameId === 0 && sender.tab?.active) this.report('focus');
    } else if (msg.type === 'ready') {
      // A content script started after the answer arrived (document_idle can come after "complete").
      if (sender.frameId !== undefined) void this.fillTab(tabId, sender.frameId);
    } else {
      this.drop(tabId);
    }
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
    const fill = fillOfTabAnswer(answer);
    // The fill is for the tab this report named, and only for the origin of the URL reported.
    if (!fill || tabId === undefined || url === '' || fill.origin !== originOf(url)) return;
    this.keep(tabId, fill);
    await this.fillTab(tabId);
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
