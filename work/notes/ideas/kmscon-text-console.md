---
title: kmscon for the text consoles, so the VTs can draw the full prompt
type: idea
status: incubating
created: 2026-09-27
---

# kmscon for the text consoles

Replace the kernel's text console on the VTs (Ctrl+Alt+F2 and up, the live ISO's text entry, a headless box's screen) with kmscon, a userspace console that draws with real fonts. The consoles would then show the same catppuccin-powerline prompt, icons and 24-bit colours as a terminal window, instead of the ASCII fallback they get today.

## Why

The kernel console draws from PSF bitmap fonts of at most 512 glyphs, in 16 colours. No font fixes that: the powerline separators would fit in a patched Terminus, but the Nerd Font icons (thousands) and the 24-bit Catppuccin palette cannot. So since nixos-modules 0d0ef77 the interactive shell gives `TERM=linux` starship's plain-text-symbols preset (`/etc/starship-console.toml`): same information, ASCII, named colours. It works everywhere, and it is the floor this idea would sit on, not replace.

kmscon renders with fontconfig/freetype, so it can use the JetBrainsMono Nerd Font wabisabi already installs, has full Unicode and true colour, and reports itself as `xterm-256color`, so the interactive shell would pick the full prompt with no change on its side.

## What it would take

NixOS already packages it (`services.kmscon`, kmscon 10.0.3 from the maintained fork in the current pin). A first cut in wabisabi, as an option defaulting to off:

```nix
services.kmscon = {
  enable = true;
  useXkbConfig = true;               # the same layout as wabisabi.keyboard.*
  config = {
    font-name = "JetBrainsMono Nerd Font";
    font-size = 14;
    hwaccel = true;                  # needs hardware.graphics.enable, which wabisabi sets
  };
};
```

Things to settle before it could be a default:

- **tty1 and greetd.** With a display manager enabled, the NixOS module does not pull kmscon onto tty1 (greetd owns it) and serves the other VTs through `autovt@`. Check that tuigreet on tty1 and kmscon on tty2+ coexist, and that switching between the niri session and a kmscon VT works both ways.
- **Boot and unlock stay on the kernel console.** The initrd (the LUKS passphrase prompt, whose keymap wabisabi carries there deliberately) and early boot are before kmscon starts, so they keep the kernel console. Nothing to fix, but worth knowing so nobody expects the pretty prompt there.
- **No GPU.** kmscon needs DRM; on a machine with no KMS driver it has nothing to draw on. The live ISO's "no usable GPU" fallback lands on a VT, which is exactly where this would fail. Either keep the kernel console there (the ASCII prompt already works) or verify kmscon falls back to fbdev cleanly.
- **Hardware acceleration.** `hwaccel` is the difference between smooth and sluggish scrolling on some GPUs, and a source of bugs on others. Try both on the laptop.
- **Assertions to respect.** `services.getty.loginOptions` is unsupported with kmscon, and a `font-name` requires fontconfig, which the live ISO had to switch back on (the minimal installer profile turns it off).
- **Where the option lives.** The console is a machine choice, so a wabisabi option (for example `wabisabi.console.kmscon.enable`); telemaque, being headless, is better served by the ASCII prompt it already has.

## How to verify

In the demo VM (it has a real render node), then on the laptop: log in on tty2 and check the full prompt draws; type the LUKS passphrase at boot on a non-US layout (unaffected, but prove it); switch VT to niri and back several times; run the live ISO on a GPU-less VM and confirm the fallback still produces a working text shell.

## Later

If it proves solid, turn it on by default for the installed desktop (not the live ISO's fallback path), and consider it for the installer's text entry, where a readable, colourful console helps most.
