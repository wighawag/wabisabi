// The enso: wabisabi's mark, and the motif of its default wallpaper. One
// brush circle, drawn as several parallel "bristle" strands that sit edge to
// edge for most of the sweep and part near the end, which is what a dry brush
// does. At 16px the strands merge into one band, so small sizes need no
// separate geometry.
//
// `upto` (0..1) draws the stroke as it was being painted: everything the brush
// has covered so far, with a round brush head at the leading edge. That is
// what the boot splash animates.
//
// Deterministic: a seeded PRNG, so the same parameters give the same bytes.

export const palette = {
	ink: '#182329',
	paper: '#E4D0B5',
	paperLight: '#F4E1C3',
	seal: '#B8452F',
};

// mulberry32
function rng(seed) {
	return function () {
		seed |= 0;
		seed = (seed + 0x6d2b79f5) | 0;
		let t = Math.imul(seed ^ (seed >>> 15), 1 | seed);
		t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
		return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
	};
}

const f = (n) => Math.round(n * 100) / 100;

export function enso({cx = 128, cy = 128, r = 84, width = 34, strands = 7, seed = 7, upto = 1} = {}) {
	const rand = rng(seed);
	const start = (128 * Math.PI) / 180; // lower left, where the brush lands
	const sweep = (326 * Math.PI) / 180; // clockwise on screen, up the left side
	const steps = 180;

	const w = (u) =>
		width *
		(0.9 + 0.2 * Math.sin(Math.PI * Math.min(1, u * 1.1))) *
		(1 - 0.45 * u ** 3) *
		(1 - 0.5 * Math.max(0, (u - 0.82) / 0.18) ** 1.5);
	const rad = (u) => r * (1 + 0.025 * Math.sin(u * 9.1) + 0.015 * Math.sin(u * 23.7));
	const at = (u, off) => {
		const a = start + sweep * u;
		const m = rad(u) + off;
		return [cx + m * Math.cos(a), cy + m * Math.sin(a)];
	};

	const paths = [];
	for (let s = 0; s < strands; s++) {
		const lo = s / strands - 0.5;
		const hi = (s + 1) / strands - 0.5;
		// Drawn before the `upto` cut-off, so the PRNG is consumed the same way
		// in every frame and each frame is a prefix of the same final stroke.
		const end = 1 - rand() * 0.08 - (s === 0 || s === strands - 1 ? 0.04 : 0);
		const stop = Math.min(end, upto);
		if (stop <= 0) continue;
		const outer = [];
		const inner = [];
		for (let i = 0; i <= steps; i++) {
			const u = (i / steps) * stop;
			const width_u = w(u);
			const dry = Math.max(0, (u - 0.75) / 0.25);
			const gap = (width_u / strands) * 0.3 * dry;
			// Taper to a point only where the strand really ends, not where
			// the brush happens to be in this frame.
			const tip = Math.min(1, (end - u) / 0.12) ** 0.6;
			const c = (lo + hi) / 2;
			const h = ((hi - lo) / 2) * tip;
			outer.push(at(u, (c + h) * width_u - gap / 2));
			inner.push(at(u, (c - h) * width_u + gap / 2));
		}
		const pts = outer.concat(inner.reverse());
		paths.push('M' + pts.map(([x, y]) => `${f(x)} ${f(y)}`).join('L') + 'Z');
	}

	const circles = [];
	// Where the brush first touched the paper. It spreads as it lands.
	const land = Math.min(1, upto / 0.04);
	if (upto > 0) {
		const [x, y] = at(0, 0);
		circles.push({cx: f(x), cy: f(y), r: f((w(0) / 2) * land)});
	}
	// The brush head, while it is still moving (and not in the dry tail,
	// where there is no longer a full brush of ink to make a round edge).
	if (upto > 0 && upto < 0.8) {
		const [x, y] = at(upto, 0);
		circles.push({cx: f(x), cy: f(y), r: f(w(upto) / 2)});
	}
	return {d: paths.join(''), circles};
}

export function ensoSvg({color = 'currentColor', size = 256, upto = 1, opacity = 1, style = true} = {}) {
	const {d, circles} = enso({upto});
	const c = circles.map((k) => `<circle cx="${k.cx}" cy="${k.cy}" r="${k.r}"/>`).join('');
	return (
		`<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 256 256" width="${size}" height="${size}"` +
		(style ? ` style="color: ${palette.paper}"` : '') +
		`><g fill="${color}" opacity="${opacity}">${d ? `<path d="${d}"/>` : ''}${c}</g></svg>\n`
	);
}
