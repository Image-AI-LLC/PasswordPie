import { messageId, type TabReason } from './protocol';
import { Backoff, systemTimers, type TimerHandle, type Timers } from './timers';

export const REQUEST_TIMEOUT_MS = 5_000;
/** `show` may wait for the host to start the app (8 s there), so it gets longer. */
export const SHOW_TIMEOUT_MS = 12_000;

/** A request without its id; the channel adds the id. */
export type Request =
  | { type: 'hello'; version: number; extension: string }
  | { type: 'tab'; url: string; reason: TabReason }
  | { type: 'show' };

export interface ChannelEvents {
  /** The channel can carry requests now (Chrome: the port (re)connected; Safari: start). */
  onConnect(): void;
  /** The app asks for a tab report now. */
  onPoke(): void;
}

/** How the background talks to the PasswordPie app. */
export interface NativeChannel {
  start(events: ChannelEvents): void;
  /** Resolves with the answer, or undefined for no answer (timeout, disconnect, failure). */
  request(msg: Request, timeoutMs?: number): Promise<unknown>;
  /** Reconnect now if the port is down (the 1-minute alarm). */
  ensureConnected(): void;
}

/** The part of `runtime.Port` the channels use. */
export interface PortLike {
  postMessage(msg: unknown): void;
  disconnect(): void;
  onMessage: { addListener(cb: (msg: unknown) => void): void };
  onDisconnect: { addListener(cb: () => void): void };
}

/** Keeps one native port open, reconnecting with backoff when it drops. */
class ReconnectingPort {
  private port: PortLike | undefined;
  private retry: TimerHandle | undefined;
  private readonly backoff = new Backoff();

  constructor(
    private readonly connect: () => PortLike,
    private readonly timers: Timers,
    private readonly handlers: { onOpen(): void; onMessage(msg: unknown): void; onClose(): void },
  ) {}

  get current(): PortLike | undefined {
    return this.port;
  }

  open(): void {
    if (this.retry !== undefined) {
      this.timers.clearTimeout(this.retry);
      this.retry = undefined;
    }
    if (this.port) return;
    let port: PortLike;
    try {
      port = this.connect();
    } catch {
      this.scheduleRetry();
      return;
    }
    this.port = port;
    port.onMessage.addListener((msg) => {
      if (this.port !== port) return;
      this.backoff.reset();
      this.handlers.onMessage(msg);
    });
    port.onDisconnect.addListener(() => {
      if (this.port !== port) return;
      this.port = undefined;
      this.handlers.onClose();
      this.scheduleRetry();
    });
    this.handlers.onOpen();
  }

  private scheduleRetry(): void {
    if (this.retry !== undefined) return;
    this.retry = this.timers.setTimeout(() => {
      this.retry = undefined;
      this.open();
    }, this.backoff.next());
  }
}

function withTimeout<T>(promise: Promise<T>, timers: Timers, ms: number): Promise<T | undefined> {
  return new Promise((resolve) => {
    const timer = timers.setTimeout(() => resolve(undefined), ms);
    promise.then(
      (value) => {
        timers.clearTimeout(timer);
        resolve(value);
      },
      () => {
        timers.clearTimeout(timer);
        resolve(undefined);
      },
    );
  });
}

/** Chrome: one `connectNative` port carries requests, answers and pokes. */
export class ChromeNativeChannel implements NativeChannel {
  private nextId = 1;
  private readonly pending = new Map<number, (answer: unknown) => void>();
  private readonly port: ReconnectingPort;
  private events: ChannelEvents | undefined;

  constructor(connect: () => PortLike, private readonly timers: Timers = systemTimers) {
    this.port = new ReconnectingPort(connect, timers, {
      onOpen: () => this.events?.onConnect(),
      onMessage: (msg) => this.receive(msg),
      onClose: () => this.failPending(),
    });
  }

  start(events: ChannelEvents): void {
    this.events = events;
    this.port.open();
  }

  ensureConnected(): void {
    if (!this.port.current) this.port.open();
  }

  request(msg: Request, timeoutMs = REQUEST_TIMEOUT_MS): Promise<unknown> {
    const port = this.port.current;
    if (!port) return Promise.resolve(undefined);
    const id = this.nextId++;
    return new Promise((resolve) => {
      const timer = this.timers.setTimeout(() => finish(undefined), timeoutMs);
      const finish = (answer: unknown): void => {
        this.timers.clearTimeout(timer);
        this.pending.delete(id);
        resolve(answer);
      };
      this.pending.set(id, finish);
      try {
        port.postMessage({ ...msg, id });
      } catch {
        finish(undefined);
      }
    });
  }

  private receive(msg: unknown): void {
    const id = messageId(msg);
    if (id === undefined) {
      if (typeof msg === 'object' && msg !== null && 'type' in msg && msg.type === 'poke') this.events?.onPoke();
      return;
    }
    this.pending.get(id)?.(msg);
  }

  private failPending(): void {
    for (const finish of [...this.pending.values()]) finish(undefined);
  }
}

/**
 * Safari: each request is its own `sendNativeMessage`. The app's pokes arrive on a `connectNative`
 * port as `{name, userInfo}`; any message on it is a poke.
 */
export class SafariNativeChannel implements NativeChannel {
  private nextId = 1;
  private readonly port: ReconnectingPort;
  private events: ChannelEvents | undefined;

  constructor(
    private readonly send: (msg: object) => Promise<unknown>,
    connect: () => PortLike,
    private readonly timers: Timers = systemTimers,
  ) {
    this.port = new ReconnectingPort(connect, timers, {
      onOpen: () => {},
      onMessage: () => this.events?.onPoke(),
      onClose: () => {},
    });
  }

  start(events: ChannelEvents): void {
    this.events = events;
    this.port.open();
    events.onConnect();
  }

  ensureConnected(): void {
    if (!this.port.current) this.port.open();
  }

  async request(msg: Request, timeoutMs = REQUEST_TIMEOUT_MS): Promise<unknown> {
    const id = this.nextId++;
    let sending: Promise<unknown>;
    try {
      sending = this.send({ ...msg, id });
    } catch {
      return undefined;
    }
    const answer = await withTimeout(sending, this.timers, timeoutMs);
    return messageId(answer) === id ? answer : undefined;
  }
}
