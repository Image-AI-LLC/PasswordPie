// @vitest-environment node
// The store promo video (store/video): its first frame is the cover, its claim is one every measured run keeps, its music follows the video's own timing data,
// and the finished file is what the store listing says it is. The checks that open the video need ffmpeg, and the
// ones that run the music scripts need uv; without them those are skipped, not passed.
import { execFileSync, spawnSync } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';

const video = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../store/video');
const mp4 = path.join(video, 'passwordpie-fill-1080p.mp4');
const cover = path.join(video, 'cover.jpg');
const timingFile = path.join(video, 'composition/timing.js');
const read = (file: string): string => readFileSync(path.join(video, file), 'utf8');

interface Timing {
  demo: { duration: number; hotkey: number; panel: number; ret: number; filled: number; submit: number; page: number; code: number; measuredMs: number };
  race: { duration: number; ff: number; pieFilledAt: number; pieReturnAt: number; typingFirstKeyAt: number; typingDoneAt: number; typingMs: number; pieHotkeyAt: number };
  measured: { runs: number; medianMs: number; p90Ms: number; maxMs: number; machine: string; chrome: string };
  scenes: { beat: number; cover: number; demo: number; race: number; end: number; duration: number };
}
const timingText = readFileSync(timingFile, 'utf8');
const timing = JSON.parse(timingText.slice(timingText.indexOf('{'), timingText.lastIndexOf('}') + 1)) as Timing;

const FRAME = 1 / 60;
const runs = (cmd: string, arg: string): boolean => spawnSync(cmd, [arg]).status === 0;
const ffmpeg = runs('ffmpeg', '-version');
const uv = runs('uv', '--version');
const out = (cmd: string, args: string[]): string => execFileSync(cmd, args, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });
/** stderr of an ffmpeg run that writes nothing. */
const ffmpegLog = (args: string[]): string => spawnSync('ffmpeg', ['-nostats', ...args, '-f', 'null', '-'], { encoding: 'utf8' }).stderr;

interface Plan { duration: number; beat: number; sections: number[]; end_card: number; fills: number[]; clicks: number[] }
const plan = (timingPath = timingFile): Plan =>
  JSON.parse(out('uv', ['run', '-q', path.join(video, 'music/synth.py'), '--plan', '--timing', timingPath])) as Plan;

describe('promo video: one timing for the picture and the music', () => {
  it('the composition starts each scene where the timing data says', () => {
    const html = read('composition/index.html');
    const start = (id: string): number => Number(new RegExp(`id="${id}" data-start="([\\d.]+)"`).exec(html)?.[1]);
    const s = timing.scenes;
    expect(start('v-demo')).toBeCloseTo(s.demo, 9);
    expect(start('v-typing')).toBeCloseTo(s.race, 9);
    expect(start('v-quick')).toBeCloseTo(s.race, 9);
    expect(Number(/data-duration="([\d.]+)" data-width/.exec(html)?.[1])).toBeCloseTo(s.duration, 9);
    for (const [id, clip] of [['v-demo', timing.demo], ['v-typing', timing.race], ['v-quick', timing.race]] as const) {
      expect(Number(new RegExp(`id="${id}" data-start="[\\d.]+" data-duration="([\\d.]+)"`).exec(html)?.[1])).toBeCloseTo(clip.duration, 9);
    }
    // The script takes the scene starts from the data, not from numbers of its own.
    expect(html).toContain('T.scenes');
    expect(html).not.toMatch(/S\d = \d/);
  });

  it('is 9 s at most, and each scene lasts exactly as long as its clip', () => {
    const s = timing.scenes;
    expect(s.duration).toBeLessThanOrEqual(9);
    expect(s.cover).toBe(0);
    // The cover is the first frame, for about half a second: whoever clicked the thumbnail has seen it.
    expect(s.demo).toBeGreaterThanOrEqual(0.4);
    expect(s.demo).toBeLessThanOrEqual(0.6);
    expect(s.race - s.demo).toBeCloseTo(timing.demo.duration, 9);
    expect(s.end - s.race).toBeCloseTo(timing.race.duration, 9);
    expect(timing.race.duration).toBeLessThanOrEqual(3);
    // The end card: 1.7 s at least, and on screen at 7/8 of the video, where YouTube takes a thumbnail from.
    expect(s.duration - s.end).toBeGreaterThanOrEqual(1.7);
    expect(s.duration * 7 / 8).toBeGreaterThan(s.end);
  });

  it('shows the fill and the two-step code as one stretch of real time: ⌘\\ to the code in 3 s at most', () => {
    const d = timing.demo;
    // One clip of one take, in order: ⌘\, the panel, Return, filled, Return (Sign in), the code.
    for (const [before, after] of [[0, d.hotkey], [d.hotkey, d.panel], [d.panel, d.ret], [d.ret, d.filled], [d.filled, d.submit], [d.submit, d.code]] as const) {
      expect(after).toBeGreaterThan(before);
    }
    expect(d.code).toBeLessThanOrEqual(3);
    expect(timing.scenes.demo).toBeGreaterThan(0);
    // The filled code stays for a second or more before the cut: a page that changed and filled itself has to be seen.
    expect(d.duration - d.code).toBeGreaterThanOrEqual(1);
    // The Sign in key cap is gone by the time the next page is up.
    expect(read('composition/index.html')).toContain("key('#k-sign', S1 + D.submit, pageGone, 0.4);");
    // The clip is cut from the two-step take at 60 frames a second, and nowhere else: not sped up, nothing left out.
    const prep = read('composition/prep.mjs');
    expect(prep).toContain("cut('demo.mp4', twostep.mov, start, duration, CARD);");
    expect(prep.match(/demo\.mp4/g)).toHaveLength(2);
    // By the take's own clocks (the recorder's and the page's, epoch ms) the same moments are as far apart as in the clip.
    const take = JSON.parse(read('takes/twostep.json')) as Record<'hotkey' | 'ret' | 'filled' | 'submit' | 'code', number>;
    expect((d.filled - d.hotkey) * 1000).toBeCloseTo(take.filled - take.hotkey, 3);
    expect((d.submit - d.ret) * 1000).toBeCloseTo(take.submit - take.ret, 3);
    expect(Math.abs((d.code - d.filled) * 1000 - (take.code - take.filled))).toBeLessThan(2 * 1000 * FRAME);
    const html = read('composition/index.html');
    expect(html.match(/<video /g)).toHaveLength(3);
  });

  it('is cut to a beat the take sets: scenes start on it, and so does each fill', () => {
    const s = timing.scenes;
    const beat = s.beat;
    // The form and the code fill 1.1 s apart in the take: two beats of 0.55 s, a whole number of frames.
    expect(60 / beat).toBeGreaterThanOrEqual(100);
    expect(60 / beat).toBeLessThanOrEqual(128);
    expect(beat * 60).toBeCloseTo(Math.round(beat * 60), 9);
    const offBeat = (t: number): number => Math.abs((t - s.demo) / beat - Math.round((t - s.demo) / beat)) * beat;
    for (const start of [s.demo, s.race, s.end]) expect(offBeat(start), `scene at ${start} s`).toBeLessThan(1e-6);
    for (const fill of [s.demo + timing.demo.filled, s.demo + timing.demo.code, s.race + timing.race.pieFilledAt]) {
      expect(offBeat(fill), `fill at ${fill.toFixed(3)} s`).toBeLessThanOrEqual(FRAME);
    }
  });

  it('counts Return to filled in real time, in seconds, and stops on the measured median, within a frame of this take', () => {
    const html = read('composition/index.html');
    // The counter runs for as long as this take took from Return to filled, to the median of the measured runs.
    expect(html).toContain("tl.to(count, { v: medianSeconds, duration: D.filled - D.ret, ease: 'none', onUpdate: showCount }, S1 + D.ret);");
    expect(html).toContain('const median = Math.round(T.measured.medianMs);');
    expect(html).toContain('const medianSeconds = median / 1000;');
    expect(html).toContain("document.getElementById('count').textContent = count.v.toFixed(2);");
    // The take's own time, by the page's clock and by the frames of the clip, is less than a frame from the median.
    expect(Math.abs(timing.demo.measuredMs - timing.measured.medianMs)).toBeLessThan(1000 * FRAME);
    expect(Math.abs((timing.demo.filled - timing.demo.ret) * 1000 - timing.demo.measuredMs)).toBeLessThan(1000 * FRAME);
    expect(timing.demo.measuredMs).toBeLessThan(500);
  });

  it('says the speed in seconds where it is big; milliseconds are small print', () => {
    const html = read('composition/index.html');
    const body = html.slice(html.indexOf('<body'), html.indexOf('<script'));
    // No "ms" beside a number in the markup, and the two big numbers have "s" for a unit.
    expect(body).not.toMatch(/>ms</);
    expect(body).toContain('<span id="count">0.00</span><small>s</small>');
    expect(body).toContain('<div class="num">&lt;0.5<small>s</small></div>');
    // The end card says what the cover says.
    const cover = read('cover/cover.html');
    const claim = '<div class="claim">From Return to a filled sign-in.<br><i>A heartbeat takes longer.</i></div>';
    expect(body).toContain(claim);
    expect(cover).toContain(claim.replace('class="claim"', 'class="abs claim"'));
    // Milliseconds are nowhere in the markup: only the end card's note has them, written from the measured data, as
    // on the cover. The demo shows the counter and what it counts, and no note.
    expect(body).not.toMatch(/\bms\b/);
    expect(body).not.toContain('meter-note');
    expect(html).toContain('const small = `Median ${median} ms of ${T.measured.runs} runs · slowest ${Math.round(T.measured.maxMs)} ms`;');
    expect(html.match(/textContent: small\b/g)).toHaveLength(1);
    expect(html).toContain("tl.set('#end-runs', { textContent: small }, 0);");
  });

  it('says how much faster the typing is shown, and keeps its clock true', () => {
    const html = read('composition/index.html');
    // The label is written from the number the clip was cut with, and nothing else is slowed down or sped up.
    expect(html).toContain('`${T.race.ff}× speed`');
    expect(html).not.toMatch(/\d× (slower|speed|faster)/);
    expect(html).not.toContain('slower');
    // Side by side: both start at the same moment, and the typing runs `ff` times as fast as it was typed.
    expect(timing.race.typingFirstKeyAt).toBe(timing.race.pieHotkeyAt);
    expect((timing.race.typingDoneAt - timing.race.typingFirstKeyAt) * timing.race.ff * 1000).toBeCloseTo(timing.race.typingMs, 3);
    expect(timing.race.typingDoneAt).toBeLessThan(timing.race.duration);
  });

  it.skipIf(!uv)('the music pops at the moments the forms fill, and clicks at the key presses', () => {
    const p = plan();
    const s = timing.scenes;
    expect(p.fills).toEqual([
      s.demo + timing.demo.filled,
      s.demo + timing.demo.code,
      s.race + timing.race.pieFilledAt,
    ]);
    expect(p.clicks).toEqual([
      s.demo + timing.demo.hotkey,
      s.demo + timing.demo.ret,
      s.demo + timing.demo.submit,
      s.race + timing.race.pieHotkeyAt,
      s.race + timing.race.pieReturnAt,
    ]);
    // The drums come in with the first scene, each scene starts a section, and the last hit is the end card.
    expect(p.sections).toEqual([s.demo, s.race]);
    expect(p.end_card).toBe(s.end);
    expect(p.duration).toBe(s.duration);
    expect(p.beat).toBe(s.beat);
  }, 60_000);

  it.skipIf(!uv)('a different timing gives different cues: nothing about them is kept in the music script', () => {
    const dir = mkdtempSync(path.join(tmpdir(), 'pp-timing-'));
    try {
      // The same scenes at a slower beat, and the first fill a little later.
      const moved = structuredClone(timing);
      const beat = timing.scenes.beat;
      const slower = beat * 1.05;
      const s = moved.scenes;
      const beats = (t: number): number => Math.round((t - timing.scenes.demo) / beat);
      [s.race, s.end] = [s.race, s.end].map((t) => s.demo + beats(t) * slower) as [number, number];
      s.beat = slower;
      s.duration = s.end + 2;
      moved.demo.filled += 0.25;
      moved.demo.ret += 0.25;
      const file = path.join(dir, 'timing.js');
      writeFileSync(file, `// moved\nwindow.PP = ${JSON.stringify(moved, null, 2)};\n`);
      const [was, now] = [plan(), plan(file)];
      expect(now.beat).toBeCloseTo(slower, 9);
      expect(now.sections).toEqual([s.demo, s.race]);
      expect(now.end_card).toBe(s.end);
      expect(now.duration).toBe(s.duration);
      expect(now.fills[0]).toBeCloseTo(was.fills[0]! + 0.25, 9);
      expect(now.clicks[1]).toBeCloseTo(was.clicks[1]! + 0.25, 9);
      expect(now.fills[2]).toBeCloseTo(s.race + timing.race.pieFilledAt, 9);
      // A scene that starts off the beat is refused, not played out of time.
      moved.scenes.race += 0.1;
      writeFileSync(file, `// off the beat\nwindow.PP = ${JSON.stringify(moved, null, 2)};\n`);
      expect(() => plan(file)).toThrow(/does not start on a beat/);
    } finally {
      rmSync(dir, { recursive: true });
    }
  }, 60_000);

});

describe('promo video: the cover', () => {
  it('shows the measured numbers', () => {
    const html = read('cover/cover.html');
    const m = JSON.parse(read('measurements.json')) as { machine: string; chrome: string; fill: { n: number; median: number; p90: number; max: number } };
    const text = html.slice(html.indexOf('<body')).replace(/<[^>]+>/g, ' ').replace(/\s+/g, ' ');
    expect(text).toContain(' &lt;0.5 s ');
    expect(text).toContain(`Median ${Math.round(m.fill.median)} ms of ${m.fill.n} runs`);
    expect(text).toContain(`slowest ${Math.round(m.fill.max)} ms`);
    expect(text).toContain(`Chrome ${/Chrome\/(\d+)/.exec(m.chrome)?.[1]}`);
    // Mac14,2 is the MacBook Air (M2, 2022).
    expect(text).toContain('MacBook Air (M2)');
    expect(m.machine).toMatch(/^Mac14,2, Apple M2,/);
    // And the video says the same.
    expect(timing.measured).toMatchObject({ runs: m.fill.n, medianMs: m.fill.median, p90Ms: m.fill.p90, maxMs: m.fill.max });
  });

  it('"<0.5 s" holds for every measured run, not for the median alone', () => {
    const m = JSON.parse(read('measurements.json')) as { fill: { n: number; max: number }; runs: { fillMs: number }[] };
    expect(m.runs).toHaveLength(m.fill.n);
    expect(m.fill.max).toBe(Math.max(...m.runs.map((r) => r.fillMs)));
    expect(m.fill.max).toBeLessThan(500);
    for (const r of m.runs) expect(r.fillMs).toBeLessThan(500);
  });

  it.skipIf(!ffmpeg)('is a 1280x720 JPEG', () => {
    expect(out('ffprobe', ['-v', 'error', '-show_entries', 'stream=codec_name,width,height', '-of', 'csv=p=0', cover]).trim()).toBe('mjpeg,1280,720');
  });
});

describe.skipIf(!ffmpeg)('promo video: the finished file', () => {
  const streams = (JSON.parse(out('ffprobe', ['-v', 'error', '-show_streams', '-show_format', '-of', 'json', mp4])) as {
    streams: Record<string, string | number>[];
  }).streams;
  const stream = (type: string): Record<string, string | number> => streams.find((s) => s.codec_type === type) ?? {};

  /** How alike a frame of the video (at `seconds`) and the cover are: SSIM, 1 = the same picture. */
  const likeCover = (seconds: number): number => {
    // The frame by its number: a seek to a time can land a frame off.
    const log = ffmpegLog(['-i', mp4, '-i', cover, '-frames:v', '1',
      '-lavfi', `[0:v]select='eq(n,${Math.round(seconds * 60)})',scale=1280:720:flags=area,format=gbrp[a];[1:v]format=gbrp[b];[a][b]ssim`]);
    return Number(/SSIM .*All:([\d.]+)/.exec(log)?.[1]);
  };

  it('is 1920x1080 at 60 fps, H.264 with AAC stereo sound, as long as the timing data says', () => {
    const [v, a] = [stream('video'), stream('audio')];
    expect([v.codec_name, v.width, v.height, v.r_frame_rate, v.pix_fmt]).toEqual(['h264', 1920, 1080, '60/1', 'yuv420p']);
    expect(Number(v.nb_frames)).toBe(Math.round(timing.scenes.duration * 60));
    expect([a.codec_name, a.sample_rate, a.channels]).toEqual(['aac', '48000', 2]);
    expect(Number(a.duration)).toBeCloseTo(timing.scenes.duration, 1);
    expect(Number(a.start_time)).toBe(0);
  });

  it('opens on the whole cover and cuts from it to the first scene on the first beat', () => {
    expect(likeCover(0)).toBeGreaterThan(0.97);
    // Whole until its last frame: no dissolve with the scene under it.
    expect(likeCover(timing.scenes.demo - FRAME)).toBeGreaterThan(0.97);
    expect(likeCover(timing.scenes.demo)).toBeLessThan(0.8);
    expect(likeCover(timing.scenes.end + 1)).toBeLessThan(0.8);
  });

  it('cuts on the beat: a scene is all there on its first frame, and was not there the frame before', () => {
    // The part of the picture each scene brings and then leaves alone: its headline, and for the end card everything.
    const [headline, all] = ['620:170:180:20', '1920:1080:0:0'];
    const s = timing.scenes;
    const alike = (crop: string, a: number, b: number): number => {
      const log = ffmpegLog(['-ss', a.toFixed(4), '-i', mp4, '-ss', b.toFixed(4), '-i', mp4, '-frames:v', '1',
        '-lavfi', `[0:v]crop=${crop}[a];[1:v]crop=${crop}[b];[a][b]ssim`]);
      return Number(/SSIM .*All:([\d.]+)/.exec(log)?.[1]);
    };
    for (const [crop, start] of [[headline, s.demo], [headline, s.race], [all, s.end]] as const) {
      expect(alike(crop, start, start + 0.3), `scene at ${start} s, on its first frame`).toBeGreaterThan(0.99);
      expect(alike(crop, start - FRAME, start + 0.3), `scene at ${start} s, the frame before`).toBeLessThan(0.9);
    }
  });

  it('gives YouTube a finished end card for a thumbnail, with nothing under the store\'s play button', () => {
    // YouTube offers frames from about 1/8, 3/8 and 7/8 of the video; the last is the end card.
    const offered = timing.scenes.duration * 7 / 8;
    expect(offered).toBeGreaterThan(timing.scenes.end);
    // Nothing on the card moves: that frame and the last second are the same picture.
    const log = ffmpegLog(['-ss', timing.scenes.end.toFixed(4), '-i', mp4, '-ss', (timing.scenes.duration - 1).toFixed(4), '-i', mp4,
      '-frames:v', '1', '-lavfi', 'ssim']);
    expect(Number(/SSIM .*All:([\d.]+)/.exec(log)?.[1])).toBeGreaterThan(0.995);
    // The play button is a tenth of the width, on the centre; the 300 px square around it is plain background.
    const centre = out('ffmpeg', ['-v', 'error', '-ss', offered.toFixed(4), '-i', mp4, '-frames:v', '1', '-vf',
      'crop=300:300:810:390,signalstats,metadata=print:file=-', '-f', 'null', '-']);
    const y = (key: string): number => Number(new RegExp(`signalstats\\.${key}=([\\d.]+)`).exec(centre)?.[1]);
    expect(y('YMAX') - y('YMIN')).toBeLessThanOrEqual(10);
    // The card itself is not plain: the same measure sees the brand and the number beside the centre.
    const whole = out('ffmpeg', ['-v', 'error', '-ss', offered.toFixed(4), '-i', mp4, '-frames:v', '1', '-vf',
      'signalstats,metadata=print:file=-', '-f', 'null', '-']);
    expect(Number(/signalstats\.YMAX=([\d.]+)/.exec(whole)?.[1]) - Number(/signalstats\.YMIN=([\d.]+)/.exec(whole)?.[1])).toBeGreaterThan(100);
  });

  /** Seconds into the video of the frame, near `at`, from which this part of the picture is as it stays: brighter or darker than before. */
  const changesAt = (crop: string, at: number): number => {
    const from = at - 0.25;
    const log = out('ffmpeg', ['-v', 'error', '-ss', from.toFixed(4), '-t', '0.5', '-i', mp4, '-vf',
      `crop=${crop},signalstats,metadata=print:key=lavfi.signalstats.YAVG:file=-`, '-f', 'null', '-']);
    const frames = [...log.matchAll(/pts_time:([\d.]+)[\s\S]*?YAVG=([\d.]+)/g)].map((m) => [Number(m[1]), Number(m[2])] as const);
    // The first frame that looks as the last one does: a page that comes up empty and fills two frames later
    // (the two-step code) counts from when it is filled.
    const [first, last] = [frames[0]![1], frames.at(-1)![1]];
    if (Math.abs(last - first) <= 5) return NaN;
    return from + frames.find(([, y]) => Math.abs(y - last) < 2)![0];
  };

  it('leaves nothing of the sign-in page on the two-step page: no ring on a field that is gone, no key cap', () => {
    // The first frame of the next page (its boxes still empty) and the one after it, where nothing has changed yet:
    // no orange in the two rings' crop, and the crop inside the key cap is plain page. The frame of the press is
    // the control: both marks are on there.
    const first = Math.round((timing.scenes.demo + timing.demo.page) * 60);
    expect(Math.round((timing.scenes.demo + timing.demo.code) * 60)).toBeGreaterThan(first + 1);
    const stat = (n: number, crop: string, key: string): number => {
      const log = out('ffmpeg', ['-v', 'error', '-i', mp4, '-vf', `select='eq(n,${n})',crop=${crop},signalstats,metadata=print:file=-`, '-f', 'null', '-']);
      return Number(new RegExp(`signalstats\\.${key}=([\\d.]+)`).exec(log)?.[1]);
    };
    const [rings, cap] = ['500:200:990:510', '240:50:840:962'];
    for (const n of [first, first + 1]) {
      expect(stat(n, rings, 'VMAX'), `ring on frame ${n}`).toBeLessThan(150);
      expect(stat(n, cap, 'YMAX') - stat(n, cap, 'YMIN'), `key cap on frame ${n}`).toBeLessThanOrEqual(10);
    }
    const press = Math.round((timing.scenes.demo + timing.demo.submit) * 60);
    expect(stat(press, rings, 'VMAX')).toBeGreaterThan(160);
    expect(stat(press, cap, 'YMAX') - stat(press, cap, 'YMIN')).toBeGreaterThan(100);
  });

  it('fills each form on the frame the timing data names', () => {
    // The email field: in the browser card (the demo) and in the right half of the side-by-side. The six boxes
    // of the two-step code: where the page with the code in them replaces the sign-in page.
    const [card, half, code] = ['300:24:1036:544', '260:20:1406:476', '440:60:1015:583'];
    const s = timing.scenes;
    for (const [crop, at] of [[card, s.demo + timing.demo.filled], [code, s.demo + timing.demo.code],
      [half, s.race + timing.race.pieFilledAt]] as const) {
      expect(Math.abs(changesAt(crop, at) - at), `fill at ${at.toFixed(3)} s`).toBeLessThanOrEqual(FRAME + 1e-3);
    }
  });

  it.skipIf(!uv)('sounds each pop within a frame of its fill and each click of its key, at -16 LUFS and no louder than -1.5 dBFS true peak', () => {
    const run = spawnSync('uv', ['run', '-q', path.join(video, 'music/check.py'), mp4], { encoding: 'utf8' });
    type Heard = { at: number; heard: number }[];
    const heard = JSON.parse(run.stdout) as { seconds: number; cues: Heard; clicks: Heard; lufs: number; truePeak: number; problems: string[] };
    const s = timing.scenes;
    expect(heard.cues.map((c) => c.at)).toEqual([s.demo + timing.demo.filled, s.demo + timing.demo.code, s.race + timing.race.pieFilledAt]);
    expect(heard.clicks).toHaveLength(5);
    for (const c of [...heard.cues, ...heard.clicks]) expect(Math.abs(c.heard - c.at), `sound at ${c.at.toFixed(3)} s, heard at ${c.heard.toFixed(3)} s`).toBeLessThanOrEqual(FRAME);
    expect(Math.abs(heard.lufs + 16)).toBeLessThanOrEqual(0.5);
    expect(heard.truePeak).toBeLessThanOrEqual(-1.5);
    expect(heard.seconds).toBeCloseTo(s.duration, 1);
    expect(heard.problems).toEqual([]);
    expect(run.status).toBe(0);
  }, 120_000);
});
