import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { ChromeNativeChannel, SafariNativeChannel } from '../src/lib/native-channel';
import { FakePort } from './fakes';

beforeEach(() => {
  vi.useFakeTimers({ toFake: ['setTimeout', 'clearTimeout', 'Date'] });
});

afterEach(() => {
  vi.useRealTimers();
});

function chrome() {
  const ports: FakePort[] = [];
  const events = { connects: 0, pokes: 0 };
  const channel = new ChromeNativeChannel(() => {
    const port = new FakePort();
    ports.push(port);
    return port;
  });
  channel.start({ onConnect: () => void (events.connects += 1), onPoke: () => void (events.pokes += 1) });
  const last = (): FakePort => {
    const port = ports.at(-1);
    if (!port) throw new Error('no port');
    return port;
  };
  return { channel, ports, events, last };
}

describe('ChromeNativeChannel', () => {
  it('connects once on start and reports the connect', () => {
    const { ports, events } = chrome();
    expect(ports).toHaveLength(1);
    expect(events.connects).toBe(1);
  });

  it('gives each request an id and matches answers by id, in any order', async () => {
    const { channel, last } = chrome();
    const a = channel.request({ type: 'hello', version: 1, extension: '0.1.0' });
    const b = channel.request({ type: 'tab', url: 'https://example.com/', reason: 'poke' });
    const [ha, hb] = last().posted as Array<{ id: number }>;
    expect(ha?.id).toEqual(expect.any(Number));
    expect(hb?.id).not.toBe(ha?.id);
    expect(last().posted[1]).toEqual({ type: 'tab', url: 'https://example.com/', reason: 'poke', id: hb?.id });
    last().receive({ type: 'tab', id: hb?.id });
    last().receive({ type: 'tab', id: 9999 }); // unknown id: ignored
    last().receive({ type: 'hello', id: ha?.id, version: 1, locked: false });
    await expect(b).resolves.toEqual({ type: 'tab', id: hb?.id });
    await expect(a).resolves.toEqual({ type: 'hello', id: ha?.id, version: 1, locked: false });
  });

  it('times out after 5 seconds with no answer', async () => {
    const { channel, last } = chrome();
    let result: unknown = 'pending';
    void channel.request({ type: 'tab', url: '', reason: 'poke' }).then((r) => (result = r));
    await vi.advanceTimersByTimeAsync(4_999);
    expect(result).toBe('pending');
    await vi.advanceTimersByTimeAsync(1);
    expect(result).toBeUndefined();
    const id = (last().posted[0] as { id: number }).id;
    last().receive({ type: 'tab', id, fill: { origin: 'https://example.com', username: 'u', password: 'p' } });
    expect(result).toBeUndefined(); // a late answer is dropped
  });

  it('treats a message without an id as a push; poke asks for a report', () => {
    const { events, last } = chrome();
    last().receive({ type: 'poke' });
    last().receive({ type: 'something-else' });
    expect(events.pokes).toBe(1);
  });

  it('answers pending requests with nothing when the port drops', async () => {
    const { channel, last } = chrome();
    const r = channel.request({ type: 'tab', url: '', reason: 'poke' });
    last().drop();
    await expect(r).resolves.toBeUndefined();
    await expect(channel.request({ type: 'tab', url: '', reason: 'poke' })).resolves.toBeUndefined();
  });

  it('reconnects with backoff from 1 s doubling to 30 s', async () => {
    const { ports, events, last } = chrome();
    const delays: number[] = [];
    for (let i = 0; i < 7; i += 1) {
      const before = ports.length;
      last().drop();
      let waited = 0;
      while (ports.length === before) {
        await vi.advanceTimersByTimeAsync(500);
        waited += 500;
      }
      delays.push(waited);
    }
    expect(delays).toEqual([1_000, 2_000, 4_000, 8_000, 16_000, 30_000, 30_000]);
    expect(events.connects).toBe(8);
  });

  it('resets the backoff once the native side answers', async () => {
    const { ports, last } = chrome();
    last().drop();
    await vi.advanceTimersByTimeAsync(1_000);
    last().drop();
    await vi.advanceTimersByTimeAsync(2_000);
    expect(ports).toHaveLength(3);
    last().receive({ type: 'hello', id: 1, version: 1, locked: false });
    last().drop();
    await vi.advanceTimersByTimeAsync(1_000);
    expect(ports).toHaveLength(4);
  });

  it('ensureConnected reconnects now when the port is down, and does nothing when it is up', async () => {
    const { channel, ports, last } = chrome();
    channel.ensureConnected();
    expect(ports).toHaveLength(1);
    last().drop();
    channel.ensureConnected();
    expect(ports).toHaveLength(2);
    await vi.advanceTimersByTimeAsync(60_000); // the pending backoff timer was cancelled
    expect(ports).toHaveLength(2);
  });

  it('survives a connect that throws', async () => {
    let calls = 0;
    const port = new FakePort();
    const channel = new ChromeNativeChannel(() => {
      calls += 1;
      if (calls === 1) throw new Error('Specified native messaging host not found.');
      return port;
    });
    channel.start({ onConnect: () => {}, onPoke: () => {} });
    await vi.advanceTimersByTimeAsync(1_000);
    expect(calls).toBe(2);
  });
});

describe('SafariNativeChannel', () => {
  function safari(send: (msg: object) => Promise<unknown>) {
    const ports: FakePort[] = [];
    const events = { connects: 0, pokes: 0 };
    const channel = new SafariNativeChannel(send, () => {
      const port = new FakePort();
      ports.push(port);
      return port;
    });
    channel.start({ onConnect: () => void (events.connects += 1), onPoke: () => void (events.pokes += 1) });
    return { channel, ports, events };
  }

  it('sends each request with sendNativeMessage, with an id, and returns the answer', async () => {
    const sent: object[] = [];
    const { channel, events } = safari(async (msg) => {
      sent.push(msg);
      return { type: 'tab', id: (msg as { id: number }).id };
    });
    expect(events.connects).toBe(1);
    const answer = await channel.request({ type: 'tab', url: 'https://example.com/', reason: 'focus' });
    expect(sent[0]).toEqual({ type: 'tab', url: 'https://example.com/', reason: 'focus', id: expect.any(Number) });
    expect(answer).toEqual({ type: 'tab', id: (sent[0] as { id: number }).id });
  });

  it('treats a failed or slow sendNativeMessage as no answer', async () => {
    const { channel } = safari(async () => {
      throw new Error('native app not found');
    });
    await expect(channel.request({ type: 'tab', url: '', reason: 'poke' })).resolves.toBeUndefined();

    const slow = safari(() => new Promise(() => {}));
    let result: unknown = 'pending';
    void slow.channel.request({ type: 'tab', url: '', reason: 'poke' }).then((r) => (result = r));
    await vi.advanceTimersByTimeAsync(5_000);
    expect(result).toBeUndefined();
  });

  it('drops an answer whose id does not match', async () => {
    const { channel } = safari(async () => ({ type: 'tab', id: -5, fill: { origin: 'x', username: 'u', password: 'p' } }));
    await expect(channel.request({ type: 'tab', url: '', reason: 'poke' })).resolves.toBeUndefined();
  });

  it('treats any message on the native port as a poke, and reconnects it with backoff', async () => {
    const { ports, events } = safari(async () => undefined);
    expect(ports).toHaveLength(1);
    ports[0]?.receive({ name: 'poke', userInfo: {} });
    expect(events.pokes).toBe(1);
    ports[0]?.drop();
    await vi.advanceTimersByTimeAsync(999);
    expect(ports).toHaveLength(1);
    await vi.advanceTimersByTimeAsync(1);
    expect(ports).toHaveLength(2);
    expect(events.connects).toBe(1); // reports come from start, not the poke port
  });
});
