# artwork

wabisabi's images: the default wallpaper and the boot splash, plus the mark they share, an enso (the Zen brush circle, drawn in one breath and left imperfect).

| Path | Kind | Made by |
|---|---|---|
| `enso.mjs` | authored | the mark's geometry, and its partial "being painted" frames |
| `generate.mjs`, `generate.sh` | authored | run `./generate.sh` to regenerate everything below |
| `enso.svg` | generated | the mark, ink = `currentColor` |
| `plymouth/progress-*.png` | generated | the enso painted as the boot progresses |
| `plymouth/animation-*.png` | generated | its dry tail closing the circle, at the end |
| `plymouth/watermark.png` | generated | the wordmark, Fraunces Soft Light |
| `plymouth/{entry,bullet,lock,capslock}.png` | generated | the disk-unlock prompt |
| `wallpapers/enso.jpg` | authored | the default wallpaper |
| `wallpapers/LICENSE` | | CC0 1.0, verbatim |

`pkgs/wabisabi-artwork` installs these where their consumers look; `pkgs/wabisabi-grub-theme` derives the ISO's boot menu from the wallpaper at build time, so a new wallpaper is a new menu without touching this folder.

Drift check: `./generate.sh && git diff --exit-code artwork`. The output is deterministic (seeded PRNG, 8-bit PNGs written without timestamps), so any diff means the committed files no longer match their source.

## Licence

All wallpapers are dedicated to the public domain under **CC0 1.0** (`wallpapers/LICENSE`), as is everything generated here. They were made with an image model; whatever rights their author holds in them are waived, so they can be used, changed and redistributed without asking and without attribution. `meta.license` of `pkgs/wabisabi-artwork` says the same to Nix.

## Decisions that are easy to undo by mistake

- **The splash follows boot progress, not time.** Plymouth's two-step plugin shows `progress-NNNN.png` by how far the boot is estimated to be (it learns from past boots), so the brush goes round as the machine starts. A `throbber-NNNN.png` loop would run in a fixed 2.0 s whatever its frame count, and two-step draws it on top of the progress animation.
- **The end animation matters for the handover.** At 90% of the estimate, or when the greeter takes over earlier, two-step plays `animation-NNNN.png` once and leaves the last frame up. That frame, the finished enso, is what stays on screen while the greeter starts (see the handover in `modules/boot.nix`). Without it, deactivating plymouth erases the enso and leaves only the wordmark.
- **The lock icon is the enso.** It is the thing being unlocked.
- **The caps-lock warning is the only thing in the seal colour.** It is the one warning on that screen.
- **8-bit PNGs.** ImageMagick writes 16-bit from SVG by default: twice the size in the initrd for nothing.

## Known gaps

- The wallpaper is 1456x816, which looks soft on a 4K screen. A 2x upscale is pending; replacing `wallpapers/enso.jpg` is the whole change (the GRUB theme follows).
- Plymouth scales its images by the display's scale factor, so on a HiDPI screen the enso is upscaled from 176 px.
