export type TimerHandle = ReturnType<typeof setTimeout>;

/** The clock and timers, injectable so tests can drive them. */
export interface Timers {
  now(): number;
  setTimeout(fn: () => void, ms: number): TimerHandle;
  clearTimeout(handle: TimerHandle): void;
}

export const systemTimers: Timers = {
  now: () => Date.now(),
  setTimeout: (fn, ms) => setTimeout(fn, ms),
  clearTimeout: (handle) => clearTimeout(handle),
};

/** Reconnect delays: 1 s, doubling, at most 30 s. */
export class Backoff {
  private delay: number;

  constructor(
    private readonly initialMs = 1_000,
    private readonly maxMs = 30_000,
  ) {
    this.delay = initialMs;
  }

  next(): number {
    const current = this.delay;
    this.delay = Math.min(this.delay * 2, this.maxMs);
    return current;
  }

  reset(): void {
    this.delay = this.initialMs;
  }
}
