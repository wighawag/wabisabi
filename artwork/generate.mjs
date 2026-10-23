// Generates the committed boot artwork from enso.mjs. Run through
// ./generate.sh, which supplies the fonts from nixpkgs; needs ImageMagick
// with librsvg. Every output is written, never hand-edited, and the run is
// deterministic: `./generate.sh && git diff --exit-code artwork` is the drift
// check.
//
//   enso.svg                  the mark, ink = currentColor
//   plymouth/progress-*.png   the enso being painted, as the boot progresses
//   plymouth/animation-*.png  its dry tail closing the circle, at the end
//   plymouth/watermark.png    the wordmark under it
//   plymouth/{entry,bullet,lock,capslock}.png   the disk-unlock prompt
//
// The wallpaper-derived pieces (the GRUB background) are NOT here: they are
// built by Nix from the wallpaper, so replacing the wallpaper updates them.
import {writeFileSync, mkdirSync, rmSync, readdirSync} from 'node:fs';
import {execFileSync} from 'node:child_process';
import {dirname, join} from 'node:path';
import {fileURLToPath} from 'node:url';
import {ensoSvg, palette} from './enso.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const tmp = join(here, '.tmp');
const serif = process.env.WABISABI_FONT_SERIF;
if (!serif) throw new Error('WABISABI_FONT_SERIF is unset: run ./generate.sh, not this file');

// PNGs without timestamps, or every run "changes" every file.
const pngOut = ['-depth', '8', '-strip', '-define', 'png:exclude-chunk=date,time,tIME'];

function svgToPng(svg, out, size) {
	const src = join(tmp, 'in.svg');
	writeFileSync(src, svg);
	execFileSync('magick', [
		'-background', 'none', '-density', '288', src,
		'-resize', `${size}x${size}`, ...pngOut, out,
	]);
}

mkdirSync(tmp, {recursive: true});
writeFileSync(join(here, 'enso.svg'), ensoSvg());

// ── Plymouth ────────────────────────────────────────────────────────────────
const ply = join(here, 'plymouth');
rmSync(ply, {recursive: true, force: true});
mkdirSync(ply, {recursive: true});

// two-step shows progress-NNNN.png by BOOT PROGRESS, not by time: frame k of
// n appears when plymouth estimates the boot is k/n of the way to 90% done
// (from how long past boots took, kept in /var/lib/plymouth). So the brush
// goes round as the machine starts.
//
// At 90%, or earlier if the boot finishes first (the greeter handover
// deactivates plymouth, see modules/boot.nix), two-step plays the END
// animation, animation-NNNN.png, once, at 30 fps, and leaves its last frame on
// screen. That is the dry tail closing the circle, so what the login screen
// replaces is always the finished enso.
//
// Not throbber-NNNN.png: a throbber loops in a fixed 2.0 s whatever its frame
// count (THROBBER_DURATION in ply-throbber.c), and two-step draws it at the
// same spot as the progress animation, on top of it.
const SPLIT = 0.92;
const PROGRESS = 110;
for (let i = 0; i < PROGRESS; i++) {
	const name = `progress-${String(i + 1).padStart(4, '0')}.png`;
	// Frame 1 already shows the brush landing, so the screen is never blank.
	const upto = 0.02 + (SPLIT - 0.02) * (i / (PROGRESS - 1));
	svgToPng(ensoSvg({color: palette.paper, upto, style: false}), join(ply, name), 176);
}
const END = 24; // 0.8 s at 30 fps
const easeOut = (t) => 1 - (1 - t) ** 3;
for (let i = 0; i < END; i++) {
	const name = `animation-${String(i + 1).padStart(4, '0')}.png`;
	const upto = SPLIT + (1 - SPLIT) * easeOut((i + 1) / END);
	svgToPng(ensoSvg({color: palette.paper, upto, style: false}), join(ply, name), 176);
}

// The wordmark, set in Fraunces Soft Light like the website's headings.
execFileSync('magick', [
	'-background', 'none', '-fill', palette.paper, '-font', serif,
	'-pointsize', '44', '-density', '72', 'label:wabisabi',
	'-trim', '+repage', '-bordercolor', 'none', '-border', '4',
	...pngOut, join(ply, 'watermark.png'),
]);

// The password prompt: a quiet field, paper bullets, and the enso as the
// "lock" (it is the thing being unlocked).
svgToPng(
	`<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 320 44" width="320" height="44">` +
		`<rect x="0.75" y="0.75" width="318.5" height="42.5" rx="8" fill="#1f2c33" stroke="${palette.paper}" stroke-opacity="0.35" stroke-width="1.5"/></svg>`,
	join(ply, 'entry.png'),
	320,
);
svgToPng(
	`<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" width="16" height="16"><circle cx="8" cy="8" r="4" fill="${palette.paper}"/></svg>`,
	join(ply, 'bullet.png'),
	16,
);
svgToPng(ensoSvg({color: palette.paper, style: false}), join(ply, 'lock.png'), 40);
// Caps lock: an upward chevron over a bar, in the seal colour, because it is
// the one thing on this screen that is a warning.
svgToPng(
	`<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="24" height="24">` +
		`<path d="M12 4 L20 13 H15.5 V16 H8.5 V13 H4 Z" fill="${palette.seal}"/><rect x="8.5" y="18" width="7" height="2.2" fill="${palette.seal}"/></svg>`,
	join(ply, 'capslock.png'),
	24,
);

rmSync(tmp, {recursive: true, force: true});
console.log(`wrote enso.svg and plymouth/ (${readdirSync(ply).length} files)`);
