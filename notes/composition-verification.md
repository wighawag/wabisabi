# Composition: adopting the layers on an existing NixOS config

State as of 2026-09-10. Answers "can a user who already has a NixOS flake
import this setup?", with the answer **verified against a real independent
config** — the my-boxes fleet repo's `telemaque` host — not just argued from
the module shapes.

## The seam

The product is two plain flake-module outputs, `nixosModules.wabisabi`
(system) and `homeModules.wabisabi` (user). Three properties make them
importable into a config you don't control:

- **No `pkgs` opinion.** Modules take `pkgs` from whichever `nixosSystem`
  imports them; nothing from this repo's lock (nixpkgs unstable) enters the
  consumer's closure. `inputs.wabisabi.inputs.nixpkgs.follows = "nixpkgs"`
  is hygiene for locking, not correctness.
- **Inert until opted in.** Everything is gated behind `wabisabi.enable`
  (per layer, so a host can take one without the other), so the module can
  be imported fleet-wide and enabled per machine.
- **Loses every merge.** Every value is `mkDefault`, so the importing config
  wins. This is the property that makes the layers compose with someone
  else's opinionated baseline instead of fighting it.

The README's "Adopting on an existing NixOS config" section carries the
recipe. This note records what was actually proven and what was found.

## Verified, and how

- **The template scaffolds a machine that evaluates — after one fix.**
  `nix flake new -t .` + a stub `hardware-configuration.nix` failed with
  `The option 'wabisabi' does not exist`: `template/flake.nix` listed
  `./configuration.nix` and home-manager but never
  `wabisabi.nixosModules.wabisabi`, so `wabisabi.enable = true` in
  configuration.nix targeted an option nobody imported. Fixed by adding the
  module to the template's module list; the scaffolded machine then
  evaluates (and this repo's `nix flake check` still passes).
- **Both layers compose on top of my-boxes' telemaque**, evaluated via
  `extendModules` on that fleet's *real* `nixosConfigurations.telemaque`
  (26.05 pin; sops, wherever, pi-user, syncthing, Caddy, wireproxy, ollama
  all in scope), with `home-manager.useGlobalPkgs = true`:

  ```nix
  myboxes.nixosConfigurations.telemaque.extendModules {
    modules = [
      wabisabi.nixosModules.wabisabi
      home-manager.nixosModules.home-manager
      {
        wabisabi.enable = true;
        home-manager.users.wighawag = {
          imports = [ wabisabi.homeModules.wabisabi ];
          wabisabi.enable = true;
        };
      }
    ];
  };
  ```

  Resulting config spot-checks: `programs.niri.enable`,
  `services.greetd.enable`, the catppuccin-mocha Plymouth theme, the user's
  waybar/ghostty/zsh/niri home modules — all `true`/present, with the
  fleet's own firewall (default-deny + 22 + syncthing's 22000) and users
  untouched. `extendModules` is the zero-edit variant of adoption; a host
  that joins a fleet flake would instead import the module into that
  flake's shared module list and opt in in its own host file (the fleet
  module list is inert the same way the modules here are).
- **The composition builds**, not just evaluates: `nix build` of the
  extended config's toplevel dry-run resolves (989 paths substituted, 343
  built — activation glue, the home profile, the `niri validate` check).
  Not booted: proof stops at buildability.

## Found: version constraints (the real cost of the seam)

- **The system layer is version-portable.** No skew found on nixpkgs 26.05
  with home-manager release-26.05.
- **The home layer currently requires home-manager master.** It configures
  `wayland.windowManager.niri`, which landed in HM *after* the 26.05 branch:
  `home-manager/release-26.05` has no niri window-manager module at all
  (eval suggests river/sway/labwc instead). An adopter on release-26.05
  fails here, not in anything we wrote.
- **HM master against a *stable* nixpkgs pin has assertion skew.** The one
  hit: HM master's fzf module asserts fzf ≥ 0.73.0 for nushell integration
  (on by default); nixpkgs 26.05 ships fzf 0.72.0. One line in the adopting
  user's home config fixes it, and doubles as a live demonstration that
  consumer overrides win:

  ```nix
  programs.fzf.enableNushellIntegration = false;  # POSIX-shell users
  ```

- **niri itself is not a skew risk today**: 26.05 and unstable both ship
  26.04, so the in-build `niri validate` checks the config against the same
  schema on either pin.

## Open question worth settling deliberately

The home layer's HM-master coupling comes entirely from using HM's niri
module. The alternative is to render the KDL directly (`xdg.configFile` +
a `niri validate` checkPhase with `pkgs.niri`), which drops the master
requirement entirely and works on any HM that has the boring options we
use — at the cost of maintaining the KDL generation ourselves and losing
whatever upstream puts in the module (xwayland-satellite wiring, systemd
session units). Until someone actually wants to adopt on release HM, HM
master is the simpler deal; revisit if that changes.

## What is NOT verified

- **No boot.** The telemaque composition was evaluated and dry-run-built,
  never run. The demo VM remains the only booted proof of the layers, and
  it boots them on unstable, not 26.05.
- **A fleet host for real.** The future my-boxes machine that shares
  telemaque's setup (user, pi-user, syncthing, wherever...) is sketched,
  not created; the compose test deliberately reuses telemaque's own host
  file rather than a reduced one.
- **The home layer standalone** (home-manager on a non-NixOS distro, the
  README's claim that `homeModules.wabisabi` is usable by itself): never
  evaluated outside a NixOS integration.