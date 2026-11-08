import type { ChannelEvents, NativeChannel, PortLike, Request } from '../src/lib/native-channel';
import type { FillMessage, FillResult } from '../src/lib/protocol';
import type { FrameInfo, TabInfo, TabsAdapter } from '../src/lib/controller';

export class FakeChannel implements NativeChannel {
  events: ChannelEvents | undefined;
  sent: Request[] = [];
  answer: (msg: Request) => unknown = () => undefined;
  ensureCalls = 0;

  start(events: ChannelEvents): void {
    this.events = events;
    events.onConnect();
  }

  async request(msg: Request): Promise<unknown> {
    this.sent.push(msg);
    return this.answer(msg);
  }

  ensureConnected(): void {
    this.ensureCalls += 1;
  }

  tabReports(): Array<Extract<Request, { type: 'tab' }>> {
    return this.sent.filter((m): m is Extract<Request, { type: 'tab' }> => m.type === 'tab');
  }
}

export interface SentFill {
  tabId: number;
  frameId: number;
  msg: FillMessage;
}

export class FakeTabs implements TabsAdapter {
  active: TabInfo | undefined = { id: 1, url: 'https://example.com/login', active: true };
  framesByTab = new Map<number, FrameInfo[]>();
  fills: SentFill[] = [];
  opened: string[] = [];
  frameAnswer: (tabId: number, frameId: number) => FillResult | undefined = () => ({ username: true, password: true });

  async activeTab(): Promise<TabInfo | undefined> {
    return this.active;
  }

  async frames(tabId: number): Promise<FrameInfo[]> {
    return this.framesByTab.get(tabId) ?? [{ frameId: 0, url: this.active?.url ?? '' }];
  }

  async sendFill(tabId: number, frameId: number, msg: FillMessage): Promise<unknown> {
    this.fills.push({ tabId, frameId, msg });
    return this.frameAnswer(tabId, frameId);
  }

  async openTab(url: string): Promise<unknown> {
    this.opened.push(url);
    return undefined;
  }
}

type Listener<T extends unknown[]> = (...args: T) => void;

export class FakePort implements PortLike {
  posted: unknown[] = [];
  disconnected = false;
  private messageListeners: Array<Listener<[unknown]>> = [];
  private disconnectListeners: Array<Listener<[]>> = [];

  postMessage(msg: unknown): void {
    if (this.disconnected) throw new Error('Attempting to use a disconnected port object');
    this.posted.push(msg);
  }

  disconnect(): void {
    this.disconnected = true;
  }

  onMessage = { addListener: (cb: Listener<[unknown]>) => void this.messageListeners.push(cb) };
  onDisconnect = { addListener: (cb: Listener<[]>) => void this.disconnectListeners.push(cb) };

  /** The native side sends a message. */
  receive(msg: unknown): void {
    for (const cb of this.messageListeners) cb(msg);
  }

  /** The native side goes away. */
  drop(): void {
    this.disconnected = true;
    for (const cb of this.disconnectListeners) cb();
  }
}
