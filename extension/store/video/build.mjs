// The finished video, with its sound, from takes/: node build.mjs
//   1. composition/prep.mjs cuts the takes into clips and writes timing.js
//   2. render-cover.mjs renders the cover (cover.jpg and the video's first frame)
//   3. HyperFrames renders the picture
//   4. music/synth.py plays the music to timing.js
//   5. ffmpeg sets the music to -16 LUFS and puts it under the picture
//   6. music/check.py listens to the result: every cue within a frame of its fill, loudness and true peak as wanted
// Needs ffmpeg, uv, and what README.md ("Recording it again") sets up: PUPPETEER and HYPERFRAMES. Headless throughout.
import { execFileSync, spawnSync } from 'node:child_process';
import { mkdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const dir = path.dirname(fileURLToPath(import.meta.url));
const work = path.join(dir, 'composition/renders');
const out = path.join(dir, 'passwordpie-fill-1080p.mp4');
const TARGET_LUFS = -16;
mkdirSync(work, { recursive: true });
const run = (cmd, args, cwd = dir) => execFileSync(cmd, args, { cwd, stdio: 'inherit' });

run('node', ['composition/prep.mjs']);
run('node', ['render-cover.mjs']);
const silent = path.join(work, 'silent.mp4');
run(process.env.HYPERFRAMES ?? 'hyperframes', ['render', '.', '--quality', 'high', '--fps', '60', '--quiet', '--output', silent], path.join(dir, 'composition'));
const wav = path.join(work, 'music.wav');
run('uv', ['run', '-q', 'music/synth.py', wav]);

// One gain for the whole track (no compressor, no limiter): the difference between its loudness and the target.
const meter = spawnSync('ffmpeg', ['-nostats', '-i', wav, '-af', 'ebur128', '-f', 'null', '-'], { encoding: 'utf8' }).stderr;
const loudness = Number(/I:\s+(-?[\d.]+) LUFS/.exec(meter.slice(meter.lastIndexOf('Summary:')))?.[1]);
if (!Number.isFinite(loudness)) throw new Error('could not measure the loudness of the music');
const gain = TARGET_LUFS - loudness;
console.log(`music at ${loudness} LUFS: ${gain.toFixed(2)} dB to ${TARGET_LUFS}`);
run('ffmpeg', ['-v', 'error', '-y', '-i', silent, '-i', wav, '-map', '0:v:0', '-map', '1:a:0', '-c:v', 'copy',
  '-af', `volume=${gain.toFixed(2)}dB`, '-c:a', 'aac', '-b:a', '192k', '-movflags', '+faststart', out]);
run('uv', ['run', '-q', 'music/check.py', out]);
console.log(out);
