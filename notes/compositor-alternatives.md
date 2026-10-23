# Compositor alternatives

Why wabisabi ships niri, what the runners-up were, and what it would cost to add one back. Written 2026-09-10 against nixpkgs `nixos-unstable` (the flake pin) and upstream release data fetched the same day. Versions below are what *this flake* would actually build, not what upstream has tagged.

Everything considered here is FSF-free, so rule 1 of this project does not narrow the field at all. The choice is about maintenance, ergonomics and taste.

## Why niri won

- **Build-time config validation.** The home-manager module runs `niri validate` on the generated KDL inside the derivation. A bad option fails `nixos-rebuild` instead of dropping the user into a black screen. For a project whose product is modules other people rebuild on their own schedule, nothing else on the list offers this.
- **A config format with a stated compatibility policy**, versus Hyprland renaming config keys in most minor releases.
- **Accessibility.** niri 25.08 implemented the `org.freedesktop.a11y.KeyboardMonitor` D-Bus interface for Orca and bound `Super+Alt+S` to toggle it; 25.11 fixed modifier signalling to screen readers and made the Alt-Tab switcher speak. It is the only tiling compositor in this field with any screen-reader story at all.
- **Effects without a fork.** 26.04 mainlined blur, driven by the `ext-background-effect-v1` protocol, which clients (foot, kitty, Ghostty, Quickshell) request for themselves. Only KWin 6.7, Mutter 51 and niri implement it.
- **Upstream Nix support.** `programs.niri` in nixpkgs handles session, systemd units, gnome-keyring and portal routing; `wayland.windowManager.niri` in home-manager handles config and xwayland-satellite.

Costs we accepted: GPL-3.0-only rather than permissive (irrelevant here), a scrollable-column model that is genuinely different to learn, and animations that must be turned off on machines without an accelerated driver (hence `wabisabi.animations`).

## Sway, and the "no aesthetics is a feature" argument

Sway 1.12 (25 May 2026, 138 changes from 50 contributors, MIT) is the most conservative choice available and the strongest on the axes that matter for a shared module set: multi-maintainer, shares people with wlroots, runs a real RC process, and keeps i3 config compatibility as a project constraint so the config surface effectively does not break. Home-manager's `wayland.windowManager.sway` module is the most mature in the tree at ~757 lines.

1.12 also quietly closed the capability gap that used to be the argument against it: it runs on wlroots 0.20 and added individual-window capture, HDR10 via the Vulkan renderer, `color-management-v1`, `color-representation-v1`, `ext-workspace-v1` and `xdg-toplevel-tag-v1`. It also made display managers officially supported and stopped refusing to start on unsupported GPUs.

**The "we can add the looks later" idea needs care.** Aesthetics on Wayland lives in three layers, and only two of them are addable:

- **Layer A, client-side chrome:** bar, launcher, notifications, wallpaper, lock screen, GTK/Qt theme, cursors, fonts, terminal. Entirely compositor-independent. This is where most of the visual identity lives, and in wabisabi it is already isolated: the Catppuccin palette in `home/desktop.nix` feeds Waybar, mako, fuzzel, swaylock and GTK, and none of it knows what compositor is running. **This is the part worth protecting, and it survives any compositor swap.**
- **Layer B, compositor-drawn effects:** rounded corners, blur, shadows, animations, workspace overview. **There is no plugin API for Sway and upstream rejects these features by design.** You cannot add them with a package. It is fork-or-nothing.
- **Layer C, protocol-driven effects:** `ext-background-effect-v1`, where the client asks and the compositor obliges. Sway does not implement it. Neither does Hyprland (as of the version tested upstream). niri does.

So Sway plus an excellent layer A is a *different aesthetic* (crisp, flat, no motion), not a deferred version of the niri or Hyprland one. That is a perfectly good thing to want. It is just not "add it later".

### SwayFX, if you want the effects anyway

`pkgs.swayfx` 0.6 (MIT) is a drop-in `programs.sway.package` swap that accepts stock Sway configs as a superset, adding rounded corners, blur, shadows, dim-inactive, and **animations** as of 0.6. It is built on `scenefx` (also `wlrfx`, in nixpkgs at 0.5), a drop-in replacement for the wlroots scene API.

The "always a release behind upstream" criticism is now largely stale: 0.6 shipped 5 Aug 2026 rebased on sway 1.12, which is the current Sway release, and commits were landing as recently as 7 Sept 2026. Remaining risks: a small maintainer group, a fork-of-a-fork (`swayfx-enhanced`) diluting attention, and a GLES2-only renderer, so you cannot combine its effects with the wlroots Vulkan renderer (which is what Sway 1.12's HDR10 needs).

## Hyprland, and why it is not the default

Hyprland 0.56.2 (BSD-3-Clause) is the most featureful and the best-looking out of the box, and it is not disqualified on any licensing or capability ground. It is the default in a great many setups for good reasons.

The reason it is not ours is **config churn against a shared module set**. Releases in 2026: 0.53 (Jan), 0.54 (Feb), 0.55 (May), 0.56 (Jul), and 0.54, 0.55 and 0.56 each carry an explicit "Breaking changes" section that renames or removes config keys. The old Hyprland version of `home/desktop.nix` had two comments recording exactly this (`gaps_in` becoming snake_case, `disable_splash` becoming `disable_splash_rendering`). Every such rename is a build that breaks in *our* name for someone who just ran `nixos-rebuild`, with no build-time validation to catch it. Secondary costs: a compositor-specific portal (`xdg-desktop-portal-hyprland`) that must be version-matched, a plugin ABI that breaks on essentially every release, and several `hyprland-*` protocol extensions that live outside `wayland-protocols`, so anything built on them is not portable.

Governance is worth knowing about rather than adjudicating here: single copyright holder (vaxerski), sponsor-funded (Framework and 37signals among them), and a documented history of freedesktop.org conflict and community-conduct disputes with primary sources on both sides. A project with an explicit values section should decide that deliberately rather than by inertia.

Note also that the Hyprland *utilities* are not Hyprland-only: hyprlock uses `ext-session-lock-v1` and hypridle uses `ext-idle-notify-v1`, so both run under niri. We use swaylock and swayidle instead only to keep the whole session inside one ecosystem, not because the hypr ones would fail.

## The rest of the field

Verified as packaged in the current pin, with the NixOS module that exists for each:

| Compositor | Version | License | NixOS module | HM module | Note |
|---|---|---|---|---|---|
| river | 0.4.8 | GPL-3.0 | `programs.river` | yes | Layout is an external process you write. Elegant, bus factor 1, but genuinely active (releases through Aug 2026, commits Sept 2026). |
| dwl | 0.8 | GPL-3.0 | `programs.dwl` | no | dwm for Wayland, `config.h` and recompile, which is actually a good Nix fit via `overrideAttrs`. Not dead: two new lead developers as of 8 Sept 2026, just deliberately slow. Needs the IPC patch for a bar. |
| labwc | 0.20.2 | GPL-2.0+ | `programs.labwc` | yes (XML) | Openbox-style stacking. The most "boring and correct" option, best bus factor of the small compositors. |
| Wayfire | 0.10.1 | MIT | `programs.wayfire` | yes | Stacking with Compiz-style 3D effects. Alive, single maintainer. |
| mango | 0.16.3 | GPL-3.0+ | `programs.mango` | no | dwl plus SceneFX plus a runtime config file. Fast-moving, single maintainer. |
| miracle-wm | 0.10.1 | GPL-3.0 | `programs.miracle-wm` | no | i3-like, but built on Mir, so the wlroots portal glue does not apply. |
| pinnacle | 0.2.4 | GPL-3.0 | `programs.pinnacle` | no | Smithay, AwesomeWM-inspired, configured in Lua or Rust. Explicitly WIP. |
| cosmic-comp | 1.6.0 | GPL-3.0 | `services.desktopManager.cosmic` | 3rd-party | Full DE. Note most of COSMIC outside the compositor is MPL-2.0. |
| KWin | 6.7.4 | GPL family | `services.desktopManager.plasma6` | plasma-manager | Best HDR correctness; plain INI config makes it the best full-DE Nix fit. |
| Mutter | 50.4 | GPL-2.0+ | `services.desktopManager.gnome` | dconf only | The only mature screen-reader target. Worst declarative fit: dconf is a binary database, so home-manager writes into mutable state at activation. |

## Desktop shells (orthogonal to the compositor)

If the goal is "make a bare compositor look designed", the modern answer is not a different compositor but a QML shell, and the pin already has NixOS modules for two:

- `programs.dms-shell`, DankMaterialShell 1.5.3
- `programs.noctalia`, noctalia-shell 4.7.7
- both built on `quickshell` 0.3.1

They provide dock, control centre, notification centre, overview and lock as compositor-agnostic layer-shell clients, and they replace rather than complement Waybar plus fuzzel plus mako. There is also `umbriel` (MIT, `0-unstable-2026-09-03`, `programs.umbriel`), a new wlroots plus SceneFX compositor from the Noctalia project. All three are young and moving fast; none is a candidate for a default yet.

## If we ever add a compositor option

The shape would be `wabisabi.compositor = "niri" | "sway" | ...`, and the work is contained because the session is deliberately built out of generic parts. What is already portable: Waybar (it has first-class modules for sway, river, Hyprland, niri, mango, dwl and Wayfire), fuzzel, mako, swaylock, swayidle, the Catppuccin palette, the GTK theme, and grim/slurp/wf-recorder (niri implements `wlr-screencopy` v3, so they work unmodified).

What is compositor-bound, and therefore all that a second backend needs to supply:

1. the keybind block,
2. the Waybar workspaces module name and its CSS state classes (niri uses `.focused`, i3/sway use `.focused` too, Hyprland uses `.active`),
3. the greetd session command in `modules/desktop.nix`,
4. the portal set: niri wants gnome plus gtk, wlroots compositors want `xdg-desktop-portal-wlr` plus gtk, Hyprland wants its own. This is the one that must follow the compositor choice rather than being a flat default in `modules/core.nix`.

## Sources

Package versions and module availability were evaluated against the flake's own `nixpkgs` and `home-manager` inputs. Release facts come from upstream release pages and APIs fetched 2026-09-10: [sway releases](https://github.com/swaywm/sway/releases), [niri releases](https://github.com/niri-wm/niri/releases), [Hyprland releases](https://github.com/hyprwm/Hyprland/releases), [swayfx releases](https://github.com/wlrfx/swayfx/releases), [dwl on Codeberg](https://codeberg.org/dwl/dwl), [river on Codeberg](https://codeberg.org/river/river). Protocol support tables from [wayland.app](https://wayland.app/protocols/), notably [ext-background-effect-v1](https://wayland.app/protocols/ext-background-effect-v1) and [wlr-screencopy](https://wayland.app/protocols/wlr-screencopy-unstable-v1).
