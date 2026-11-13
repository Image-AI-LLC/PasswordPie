// Cuts the recorded takes (../takes) into the clips the composition plays, and writes timing.js: when each key was
// pressed and when each field filled, in clip time. Needs ffmpeg. Run from anywhere: node prep.mjs
//
// The takes' event times are epoch ms from the recorder and the page. They are put on the video's clock by finding
// the frame where the username first shows in the form (a jump in the email field's brightness) and lining it up with
// the take's `filled` time; that offset is one frame or less.
import { execFileSync } from 'node:child_process';
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const dir = path.dirname(fileURLToPath(import.meta.url));
const takes = path.join(dir, '../takes');
const clips = path.join(dir, 'clips');
mkdirSync(clips, { recursive: true });

// The takes are variable frame rate: a frame only when the screen changed. Seeking into a still stretch starts at the
// next real frame, so every take is first made constant 60 fps from its own start, and cut from that.
mkdirSync(path.join(clips, 'cfr'), { recursive: true });
function constantRate(name) {
  const out = path.join(clips, 'cfr', `${name}.mp4`);
  execFileSync('ffmpeg', ['-v', 'error', '-y', '-i', path.join(takes, `${name}.mov`), '-vf', 'fps=60',
    '-c:v', 'libx264', '-preset', 'veryfast', '-crf', '8', '-pix_fmt', 'yuv420p', out]);
  return out;
}
const take = (name) => ({ ...JSON.parse(readFileSync(path.join(takes, `${name}.json`), 'utf8')), mov: constantRate(name) });

/** Seconds into the video of the first frame where the email field changes brightness by > 5. `crop` is the field
 * in that video's pixels (default: a take, 2560x1440). */
function fieldShows(mov, crop = '500:40:1500:625') {
  const out = execFileSync('ffmpeg', ['-v', 'error', '-i', mov, '-vf',
    `crop=${crop},signalstats,metadata=print:key=lavfi.signalstats.YAVG:file=-`, '-f', 'null', '-'], { encoding: 'utf8' });
  let t = 0;
  let first;
  for (const line of out.split('\n')) {
    const pts = /pts_time:([\d.]+)/.exec(line);
    if (pts) { t = Number(pts[1]); continue; }
    const y = /YAVG=([\d.]+)/.exec(line);
    if (!y) continue;
    if (first === undefined) first = Number(y[1]);
    else if (Math.abs(Number(y[1]) - first) > 5) return t;
  }
  throw new Error(`no fill found in ${mov}`);
}

/** Adds v(epochMs) → seconds into this take's video. */
function onVideoClock(t, offset) {
  const off = offset ?? fieldShows(t.mov) - (t.filled - t.recordingStarted) / 1000;
  return { ...t, offset: off, v: (ms) => (ms - t.recordingStarted) / 1000 + off };
}

const fill = onVideoClock(take('fill'));
const quick = onVideoClock(take('quick'));
const twostep = onVideoClock(take('twostep'));
// The typing take has no fill to line up with: use the quick take's offset (same session, same recorder).
const typing = onVideoClock(take('typing'), quick.offset);

const ENC = ['-c:v', 'libx264', '-preset', 'slow', '-crf', '14', '-pix_fmt', 'yuv420p', '-r', '60', '-an', '-movflags', '+faststart'];
// The capture is 2560x1440 at 2x. The top 80 px are Chrome's tab strip, where macOS draws its recording indicator in
// place of the window buttons: left out. The rest (address bar and page) goes in the browser card.
const CARD = 'crop=2560:1360:0:80,scale=1560:828:flags=lanczos';
// The side-by-side shows the PasswordPie panel and the form: 730x457 pt of the window from (340, 100).
const HALF = 'crop=1460:915:680:200,scale=820:514:flags=lanczos';

// Every clip is padded with its last frame to exactly `duration`.
// (A frame count, not -t: with these sources -t stops a few frames short.)
const frames = (seconds) => ['-frames:v', String(Math.round(seconds * 60))];
function cut(out, mov, from, duration, vf) {
  execFileSync('ffmpeg', ['-v', 'error', '-y', '-ss', from.toFixed(4), '-i', mov,
    '-vf', `tpad=stop_mode=clone:stop_duration=10,fps=60,${vf}`, ...frames(duration), ...ENC, path.join(clips, out)]);
}

const T = {};
// The email field in a clip: the take's field (1500,625 500x40) through the CARD or HALF crop and scale.
const CARD_FIELD = '300:24:856:334';
const HALF_FIELD = '260:20:406:240';
/** Seeking in a variable-frame-rate take lands a few frames early: move a clip's times to where its fill really is. */
function settle(times, clip, crop) {
  const shift = fieldShows(path.join(clips, clip), crop) - times.filled;
  if (Math.abs(shift) > 1.5 / 60 * (times.factor ?? 1)) throw new Error(`${clip}: the fill is ${shift.toFixed(3)} s off`);
  for (const key of Object.keys(times)) if (typeof times[key] === 'number' && key !== 'duration' && !key.endsWith('Ms') && key !== 'factor') times[key] += shift;
  times.shift = shift;
  return times;
}

// 1. Real time: ⌘\, the panel, Return, filled.
{
  const start = fill.v(fill.hotkey) - 0.5;
  cut('live.mp4', fill.mov, start, 3.6, CARD);
  T.live = settle({ duration: 3.6, hotkey: fill.v(fill.hotkey) - start, ret: fill.v(fill.ret) - start, filled: fill.v(fill.filled) - start,
    measuredMs: fill.filled - fill.ret }, 'live.mp4', CARD_FIELD);
}

// 2. The same take, four times slower, from just before Return to just after the fill.
{
  const slow = 4;
  const start = fill.v(fill.ret) - 0.35;
  const span = 1.25;
  execFileSync('ffmpeg', ['-v', 'error', '-y', '-ss', start.toFixed(4), '-i', fill.mov,
    '-vf', `tpad=stop_mode=clone:stop_duration=10,fps=60,setpts=${slow}*PTS,fps=60,${CARD}`, ...frames(span * slow),
    ...ENC, path.join(clips, 'slow.mp4')]);
  T.slow = settle({ duration: span * slow, factor: slow, ret: (fill.v(fill.ret) - start) * slow, filled: (fill.v(fill.filled) - start) * slow },
    'slow.mp4', CARD_FIELD);
}

// 3. Two-step, from just before Return: fill, Sign in, the code fills on the next page, Verify, home.
{
  const start = twostep.v(twostep.ret) - 0.7;
  const duration = 4.8;
  cut('twostep.mp4', twostep.mov, start, duration, CARD);
  const at = (ms) => twostep.v(ms) - start;
  T.twostep = settle({ duration, hotkey: at(twostep.hotkey), ret: at(twostep.ret), filled: at(twostep.filled), submit: at(twostep.submit),
    code: at(twostep.code), verify: at(twostep.verify), home: at(twostep.home) }, 'twostep.mp4', CARD_FIELD);
}

// 4. Side by side. Left: typing, real time for 3.6 s, then 4x until the last key, then held. Right: PasswordPie.
{
  const duration = 7.4;
  const realtime = 3.6;
  const ff = 4;
  const lead = 0.4;
  const l0 = typing.v(typing.click) - lead;
  const lEnd = typing.v(typing.typeEnd) + 0.15;
  const fast = (lEnd - (l0 + realtime)) / ff;
  const hold = duration - realtime - fast;
  if (hold < 0.8) throw new Error(`typing take too long for the side-by-side: ${fast.toFixed(2)} s at ${ff}x`);
  execFileSync('ffmpeg', ['-v', 'error', '-y', '-ss', l0.toFixed(4), '-t', (lEnd - l0).toFixed(4), '-i', typing.mov, '-filter_complex',
    `[0:v]tpad=stop_mode=clone:stop_duration=1,fps=60,trim=0:${(lEnd - l0).toFixed(4)},${HALF},split[a][b];[a]trim=0:${realtime},setpts=PTS-STARTPTS[a1];` +
    `[b]trim=${realtime},setpts=(PTS-STARTPTS)/${ff},fps=60,tpad=stop_mode=clone:stop_duration=${(hold + 1).toFixed(4)}[b1];[a1][b1]concat=n=2:v=1[v]`,
    '-map', '[v]', ...frames(duration), ...ENC, path.join(clips, 'typing.mp4')]);
  const r0 = quick.v(quick.hotkey) - lead;
  cut('quick.mp4', quick.mov, r0, duration, HALF);
  T.race = {
    duration, realtime, ff, lead,
    // Left timer: from the click in the email field to the last key of the password.
    typingMs: typing.typeEnd - typing.click,
    typingKeys: typing.keys,
    typingAvgGapMs: (typing.typeEnd - typing.typeStart) / (typing.keys - 1),
    // Right timer: from ⌘\ to the username and password in the form.
    pieMs: quick.filled - quick.hotkey,
    pieHotkeyAt: quick.v(quick.hotkey) - r0,
    pieReturnAt: quick.v(quick.ret) - r0,
    pieFilledAt: quick.v(quick.filled) - r0,
  };
  const pie = settle({ hotkey: T.race.pieHotkeyAt, ret: T.race.pieReturnAt, filled: T.race.pieFilledAt }, 'quick.mp4', HALF_FIELD);
  Object.assign(T.race, { pieHotkeyAt: pie.hotkey, pieReturnAt: pie.ret, pieFilledAt: pie.filled, pieShift: pie.shift,
    typingClickAt: lead });
}

const m = JSON.parse(readFileSync(path.join(dir, '../measurements.json'), 'utf8'));
T.measured = { runs: m.fill.n, medianMs: m.fill.median, p90Ms: m.fill.p90, machine: m.machine, chrome: m.chrome };
T.offsets = { fill: fill.offset, quick: quick.offset, twostep: twostep.offset };

writeFileSync(path.join(dir, 'timing.js'), `// Written by prep.mjs from ../takes and ../measurements.json. Times in seconds of each clip.\nwindow.PP = ${JSON.stringify(T, null, 2)};\n`);
console.log(JSON.stringify(T, null, 2));
