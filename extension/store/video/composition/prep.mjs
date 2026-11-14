// Cuts the recorded takes (../takes) into the clips the composition plays, and writes timing.js: when each key was
// pressed and when each field filled, in clip time, and when each scene starts. Needs ffmpeg. Run from anywhere: node prep.mjs
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
 * in that video's pixels (default: a take, 2560x1440); `from`: look only from there on, and compare with that frame. */
function fieldShows(mov, crop = '500:40:1500:625', from = 0) {
  const out = execFileSync('ffmpeg', ['-v', 'error', '-i', mov, '-vf',
    `crop=${crop},signalstats,metadata=print:key=lavfi.signalstats.YAVG:file=-`, '-f', 'null', '-'], { encoding: 'utf8' });
  let t = 0;
  let first;
  for (const line of out.split('\n')) {
    const pts = /pts_time:([\d.]+)/.exec(line);
    if (pts) { t = Number(pts[1]); continue; }
    const y = /YAVG=([\d.]+)/.exec(line);
    if (!y || t < from) continue;
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
// Where a cut starts, for ffmpeg: half a frame early, so the frame that starts at `from` is the first one kept
// (rounded to four places, `from` itself can fall just after it, and the cut would start a frame late).
const seek = (from) => (from - 0.5 / 60).toFixed(4);
function cut(out, mov, from, duration, vf) {
  execFileSync('ffmpeg', ['-v', 'error', '-y', '-ss', seek(from), '-i', mov,
    '-vf', `tpad=stop_mode=clone:stop_duration=10,fps=60,setpts=PTS-STARTPTS,${vf}`, ...frames(duration), ...ENC, path.join(clips, out)]);
  startsAtZero(out);
}

const T = {};
// The email field in a clip: the take's field (1500,625 500x40) through the CARD or HALF crop and scale.
const CARD_FIELD = '300:24:856:334';
const HALF_FIELD = '260:20:406:240';
/** A clip that does not start at 0 is played that much late by the renderer, whatever ffmpeg measures in it. */
function startsAtZero(clip) {
  const startsAt = Number(execFileSync('ffprobe', ['-v', 'error', '-select_streams', 'v:0', '-show_entries', 'stream=start_time', '-of', 'csv=p=0',
    path.join(clips, clip)], { encoding: 'utf8' }));
  if (startsAt !== 0) throw new Error(`${clip} starts at ${startsAt} s, not 0`);
}
/** Seeking in a variable-frame-rate take lands a few frames early: move a clip's times to where its fill really is. */
function settle(times, clip, crop) {
  const shift = fieldShows(path.join(clips, clip), crop) - times.filled;
  if (Math.abs(shift) > 1.5 / 60 * (times.factor ?? 1)) throw new Error(`${clip}: the fill is ${shift.toFixed(3)} s off`);
  for (const key of Object.keys(times)) if (typeof times[key] === 'number' && key !== 'duration' && !key.endsWith('Ms') && key !== 'factor') times[key] += shift;
  times.shift = shift;
  return times;
}

// The video is cut to a beat: 120 a minute, so a beat is 0.5 s, 30 frames. A scene starts on a beat, and its clip
// is cut so that what it is about (the form fills, the code fills) lands on a beat too: only where a clip starts
// is chosen. Nothing marked as real time is sped up, slowed down or thinned out.
// The composition (index.html), the music (../music/synth.py) and the tests take the scene starts from here.
const BEAT = 0.5;
T.scenes = { cover: 0, live: 1 * BEAT, slow: 5 * BEAT, twostep: 9 * BEAT, race: 12 * BEAT, end: 18 * BEAT, duration: 22 * BEAT };
const lasts = (scene, next) => T.scenes[next] - T.scenes[scene];
// A form fills on the fourth beat of its scene; the two-step code, which comes right after Sign in, on the second.
const FILL_AT = 3 * BEAT;
const CODE_AT = 1 * BEAT;

// 1. Real time, the quick take: ⌘\, the panel, Return, filled, one second from the first key.
{
  const duration = lasts('live', 'slow');
  const start = quick.v(quick.filled) - FILL_AT;
  cut('live.mp4', quick.mov, start, duration, CARD);
  T.live = settle({ duration, hotkey: quick.v(quick.hotkey) - start, ret: quick.v(quick.ret) - start, filled: quick.v(quick.filled) - start,
    measuredMs: quick.filled - quick.ret }, 'live.mp4', CARD_FIELD);
}

// 2. A fill three times slower (the fill take), from just before Return to just after the fields fill in.
{
  const slow = 3;
  const duration = lasts('slow', 'twostep');
  const start = fill.v(fill.filled) - FILL_AT / slow;
  execFileSync('ffmpeg', ['-v', 'error', '-y', '-ss', seek(start), '-i', fill.mov,
    '-vf', `tpad=stop_mode=clone:stop_duration=10,fps=60,setpts=${slow}*(PTS-STARTPTS),fps=60,${CARD}`, ...frames(duration),
    ...ENC, path.join(clips, 'slow.mp4')]);
  startsAtZero('slow.mp4');
  T.slow = settle({ duration, factor: slow, ret: (fill.v(fill.ret) - start) * slow, filled: (fill.v(fill.filled) - start) * slow,
    measuredMs: fill.filled - fill.ret }, 'slow.mp4', CARD_FIELD);
}

// 3. Two-step, in real time: the form as PasswordPie filled it, Sign in, and the code fills itself on the next page.
//    The second before (the same fill again, and the pause before Sign in) and what comes after (Verify, home) are
//    left out. The form is already filled when the clip starts, so there is no fill in it to settle the times on:
//    they are the take's own, on the clock checked at its fill. The code is where it shows: the next page comes up
//    with its six boxes empty, and two frames later they are filled; that second frame is the one put on the beat.
{
  const duration = lasts('twostep', 'race');
  const CODE_BOXES = '722:98:1370:692';
  const pageShows = fieldShows(twostep.mov, CODE_BOXES, twostep.v(twostep.submit));
  const codeShows = fieldShows(twostep.mov, CODE_BOXES, pageShows);
  if (Math.abs(codeShows - twostep.v(twostep.code)) > 2 / 60) throw new Error(`the code shows ${(codeShows - twostep.v(twostep.code)).toFixed(3)} s from where the page noted it`);
  const start = codeShows - CODE_AT;
  cut('twostep.mp4', twostep.mov, start, duration, CARD);
  const at = (ms) => twostep.v(ms) - start;
  T.twostep = { duration, submit: at(twostep.submit), page: pageShows - start, code: codeShows - start, codeNoted: at(twostep.code) };
}

// 4. Side by side, both from the first key at the same moment. Right: PasswordPie in real time (the quick take
//    again, closer in). Left: typing, `ff` times faster all the way, then held on its last frame.
{
  const duration = lasts('race', 'end');
  const ff = 6;
  const r0 = quick.v(quick.filled) - FILL_AT;
  cut('quick.mp4', quick.mov, r0, duration, HALF);
  const pie = settle({ hotkey: quick.v(quick.hotkey) - r0, ret: quick.v(quick.ret) - r0, filled: quick.v(quick.filled) - r0 }, 'quick.mp4', HALF_FIELD);
  // The typing take from `ff` times as long before its first key as the right side has before ⌘\. The take starts
  // 1.8 s before the first key; where that is not enough, its first frame (the page, untouched) is held.
  const l0 = typing.v(typing.typeStart) - pie.hotkey * ff;
  const held = Math.max(0, -l0);
  const lEnd = typing.v(typing.typeEnd) + 0.15;
  const typed = (typing.typeEnd - typing.typeStart) / 1000;
  if (pie.hotkey + typed / ff > duration - 0.4) throw new Error(`typing at ${ff}x does not end in time for the side-by-side`);
  execFileSync('ffmpeg', ['-v', 'error', '-y', '-i', typing.mov, '-vf',
    `fps=60,tpad=start_mode=clone:start_duration=${held.toFixed(4)},trim=${Math.max(0, l0).toFixed(4)}:${(held + lEnd).toFixed(4)},` +
    `setpts=(PTS-STARTPTS)/${ff},fps=60,tpad=stop_mode=clone:stop_duration=${duration},${HALF}`,
    ...frames(duration), ...ENC, path.join(clips, 'typing.mp4')]);
  startsAtZero('typing.mp4');
  T.race = {
    duration, ff,
    // Left timer: from the first key typed to the last key of the password (the click into the field comes before).
    typingMs: typing.typeEnd - typing.typeStart,
    typingKeys: typing.keys,
    typingAvgGapMs: (typing.typeEnd - typing.typeStart) / (typing.keys - 1),
    typingFirstKeyAt: pie.hotkey,
    typingDoneAt: pie.hotkey + typed / ff,
    typingHeld: held / ff,
    // Right timer: from ⌘\ to the username and password in the form.
    pieMs: quick.filled - quick.hotkey,
    pieHotkeyAt: pie.hotkey, pieReturnAt: pie.ret, pieFilledAt: pie.filled, pieShift: pie.shift,
  };
}

for (const [scene, at, beat] of [['live', T.live.filled, FILL_AT], ['slow', T.slow.filled, FILL_AT], ['twostep', T.twostep.code, CODE_AT], ['race', T.race.pieFilledAt, FILL_AT]]) {
  if (Math.abs(at - beat) > 1 / 60 + 1e-6) throw new Error(`${scene}: fills at ${at.toFixed(3)} s of its scene, not on the beat at ${beat} s`);
}

const m = JSON.parse(readFileSync(path.join(dir, '../measurements.json'), 'utf8'));
T.measured = { runs: m.fill.n, medianMs: m.fill.median, p90Ms: m.fill.p90, machine: m.machine, chrome: m.chrome };
T.offsets = { fill: fill.offset, quick: quick.offset, twostep: twostep.offset };

writeFileSync(path.join(dir, 'timing.js'), `// Written by prep.mjs from ../takes and ../measurements.json. Times in seconds of each clip; scenes in seconds of the video.\nwindow.PP = ${JSON.stringify(T, null, 2)};\n`);
console.log(JSON.stringify(T, null, 2));
