# Open items

State as of 2026-09-10, after replacing Hyprland with niri, updated 2026-09-20
after building the installer. Written so the next session can pick up without
re-deriving anything.

> The installer, the two ISO variants and the VM install test have their own
> note: [`notes/installer.md`](installer.md). It supersedes this file for
> anything about installing, partitioning, the keyboard layout or the
> generated flake.

## Verified, and how

All of this was checked against a booted demo VM, not just evaluated:

- **A whole install, twice** (plain and LUKS), from ISO to a login screen on
  the installed disk. See `notes/installer.md`; run it with
  `./scripts/test-install-vm.sh`.
- **`niri validate` now actually runs in `nix flake check`.** It did not
  before, and the README claimed it did: `flake check` only evaluates
  `nixosConfigurations` to a `.drv`, so the config derivation was never built
  and the validation was never performed. It is a `checks` output now.

- **niri session end to end.** greetd hands off to `niri-session`, niri gets a real render node, output detected at 1280x800, Waybar / swayidle / polkit-gnome all `active`, `systemctl --failed` reports 0 units, home-manager activation succeeds on two consecutive runs.
- **Config validity at build time.** The home-manager niri module runs `niri validate` inside the derivation (`checkConfig = true`), so a bad option fails `nixos-rebuild` rather than producing a black screen.
- **XWayland.** xwayland-satellite 0.8.2 is installed by the HM module and niri spawns it on demand (seen in the journal when something touched the X11 socket).
- **Screenshots and recording.** niri implements `wlr-screencopy` v3, so grim, slurp and wf-recorder work unmodified.
- **The greetd `systemd-cat` wrapper.** The upstream `import-environment` deprecation warning now lands in the journal instead of the console, and the session still starts through the quoted command.

## Not verified

- **The graphical session inside the install test.** The install test verifies
  boot-to-login with the text greeter, because the machine it was built on has
  no `/run/opengl-driver` and QEMU therefore cannot hand the guest GL. Running
  it on a workstation with working graphics exercises the session too; the
  harness says which of the two it did.
- **swaylock actually unlocking.** `security.pam.services.swaylock` is set and swaylock starts, but the PAM path was never exercised by hand: everything in testing was driven over niri IPC. **Test this first, with an SSH escape hatch open (`ssh -p 2222 demo@localhost`, then `pkill swaylock`), because getting it wrong locks you out of the session.**
- **The keybinds.** Every bind was generated and validated by `niri validate`, but no key was ever physically pressed. `Alt+Shift+/` in the VM shows the live list.
- **Anything hardware-shaped.** Touchpad gestures, multi-monitor hotplug, VRR, brightness keys, suspend/resume. QEMU has none of it.

## Unfinished: the Plymouth splash

`wabisabi.splash.enable` (default true) is implemented and the **quiet boot half works**: kernel params are applied (confirmed on `/proc/cmdline`) and the login screen comes up with no boot text around it.

The **graphical splash does not render inside QEMU**. Plymouth starts correctly (`Started Show Plymouth Boot Screen` in the journal) but falls back to *details mode*, which prints the boot log to the screen. Those `[ OK ]` lines are Plymouth relaying systemd, which is why `systemd.show_status=false` does not silence them.

Leading theory, **not confirmed**: the `catppuccin-mocha` theme uses the `two-step` plugin and its `.plymouth` file sets `ImageDir` to a `/nix/store` path, which does not exist in the initrd, so Plymouth cannot load the theme's images and falls back. Plymouth does not restart between initrd and stage 2, so the fallback sticks for the whole boot.

Next steps, in order:

1. Test on real hardware with the correct DRM driver in `boot.initrd.kernelModules`. This is the normal, well-trodden path and may just work, which would make the VM behaviour a QEMU curiosity rather than a bug.
2. If it fails there too, verify the ImageDir theory: check whether Plymouth logs a theme-load error, and try a theme whose assets the NixOS module copies into `/etc/plymouth/themes` with relative paths.
3. Decide whether to set `wabisabi.splash.enable = false` for the demo VM specifically, so the VM boot is honest rather than half-themed.

## Deliberately deferred

- **A compositor option.** `wabisabi.compositor = "niri" | "sway" | ...` was scoped out on purpose. `notes/compositor-alternatives.md` records the evaluation, what Sway/SwayFX/Hyprland would cost, and the exact four things a second backend would have to supply.
- **A QML desktop shell.** `programs.dms-shell` (DankMaterialShell) and `programs.noctalia` are both in the pinned nixpkgs and would replace Waybar plus fuzzel plus mako wholesale. Young and fast-moving; not a default yet.
- **Blur.** niri 26.04 supports `ext-background-effect-v1`, so clients can request it. Not enabled; `wabisabi.animations` is the only eye-candy switch so far.

## Traps worth remembering

- **The demo VM disk image must be fresh each run.** The guest's `/nix/store` is an overlay on a *tmpfs* while `/home` and `/nix/var` persist on the qcow2, so a second boot of the same image leaves the home-manager profile pointing at store paths that no longer exist. `scripts/run-vm-gl.sh` recreates the image every run for this reason.
- **niri refuses software EGL.** No GPU render node means a black screen, not a slow desktop, and niri will be running happily in the background the whole time with a live Wayland socket.
- **`-display gtk,gl=on` hides the text console** on at least one GNOME/Wayland host: the splash and tuigreet are invisible but the desktop appears after a blind login. The demo VM uses `sdl,gl=on`.
