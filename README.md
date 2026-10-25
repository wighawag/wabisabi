# wabisabi

An opinionated, **libre-only** Wayland desktop
distributed as NixOS + home-manager **modules**, so every default is an
addressable, overridable option rather than a dotfile you must not touch.

Not a distro: the modules are the product, an ISO is just a shortcut that
installs them, and no knowledge of wabisabi is required to use the system —
or to leave it.

## The two rules

1. **Open source only.** Enforced at build time: the system layer asserts
   that `nixpkgs.config.allowUnfree = false` and fails the build otherwise
   (opt out with `wabisabi.enforceLibre = false`).
2. **No non-self-hostable services.** Every app works fully locally or
   against infrastructure you can run yourself. No vendor accounts by
   default.

## The stack

| Role | Choice | License |
|---|---|---|
| Compositor | niri | GPL-3.0 |
| Login | greetd + Noctalia greeter (or tuigreet) | GPL/MIT |
| Bar | Waybar | MIT |
| Launcher | fuzzel | MIT |
| Notifications | mako | MIT |
| Lock / idle | swaylock + swayidle | MIT |
| Terminal | Ghostty (or foot) | MIT |
| Shell | bash + ble.sh, fzf, zoxide, atuin and a starship powerline prompt (still in Catppuccin colours, see below) | BSD/MIT/ISC |
| Editors | Neovim + Helix (both ship) | Apache-2.0/MPL |
| Browser | Firefox (or LibreWolf/Chromium) | MPL |
| Files | Thunar (or Nautilus) | GPL |
| Passwords | KeePassXC — local-first | GPL |
| Sync | Syncthing — P2P, self-hostable (optional) | MPL |
| Media | mpv + imv | GPL/MIT |
| Theme | Sumi: indigo ink and warm paper, from the enso wallpaper; Catppuccin Mocha as a choice | CC0 / MIT |
| Local AI model | llama.cpp + Gemma 4 E4B, on the CPU, on a unix socket | MIT / Apache-2.0 |
| Coding agent | pi, with wherever (a web UI for its sessions) | MIT / AGPL |
| Search | webveil, on SearXNG or on its own searchcast engines (no account, no profile) | AGPL |
| Recall | memonaut (search your past agent sessions) | AGPL |
| Browser automation | webhands on nixpkgs' Chromium | AGPL / BSD |
| Terminal tools | zellij, direnv, eza, bat; nix-ld for foreign binaries | MIT / Apache |
| Anonymous accounts | anonctl: every packet forced through Tor, fail-closed | AGPL |

## AI and privacy, on the machine

A wabisabi machine comes with an assistant that needs no account anywhere: a small open-weights model running on the CPU, private web search, and the pi coding agent wired to both, plus a web UI for its sessions on this machine only. Open it with `Super+A`, the "Assistant" launcher entry or the bar button (the first login says hello with a notification); `wherever-link` prints the address.

It also comes with three **anonymous accounts** (`anon`, `anon-john`, `anon-jane`) whose every connection the kernel forces through Tor, fail-closed: if Tor is down they have no network, never your address. Each is proven with `anonctl verify` before it is used, carries nothing of yours, and has its own agent (on the same local model, reached over a unix socket so their jail needs no exemption) and its own web UI (`sudo anon-reconcile links`).

The building blocks live in [nixos-modules](https://github.com/wighawag/nixos-modules), usable on any NixOS machine; wabisabi switches them on. All of it is on by default and each part is one option (`wabisabi.llm.enable`, `.search.enable`, `.agents.enable`, `.anon.enable`); the installer asks. How it fits together, what was verified and what was not: [`notes/agents.md`](notes/agents.md).

### Web search: SearXNG or searchcast

Agents (and you, with `webveil search`) search through webveil, which has two backends. A machine uses one, for the owner and the anonymous accounts alike, chosen by `wabisabi.search.backend`:

- **SearXNG** (`"searxng"`): a local SearXNG asks many search engines at once. It needs no setup. In practice many engines refuse it (CAPTCHAs, rate limits), more so over Tor, so its answers often come from whichever single engine still lets it through, and when that one stops, search stops.
- **searchcast** (`"searchcast"`): webveil asks the engines itself, with a real browser's network fingerprint, which gets through where SearXNG does not, directly and over Tor. No SearXNG runs at all. Which engines it asks, and how, is defined by **recipes**: small JavaScript modules, one per engine.
- **`"auto"`** (the default): searchcast when you give a recipe set, SearXNG otherwise.

The reason for the default: searchcast is only as good as its recipes. With a good recipe set of your own it is at least as good as SearXNG and does not hang on one engine; without one it runs webveil's bundled public engines (Mwmbl and Marginalia), which are weak alone, with off-topic or empty answers to many queries, so SearXNG is the better choice.

To use your own recipe set, give the release archive and its sha256 (the installer asks, under "AI and privacy", once you choose to review the options):

```nix
wabisabi.search.recipes = {
  url = "https://example.org/releases/my-set-1.0.0.tar.gz";
  sha256 = "<the archive's sha256, as sha256sum prints it>";
};
# Required with a set: the engine chain, recipe names tried in order.
# "mwmbl" and "marginalia" add webveil's bundled engines as fallbacks.
wabisabi.search.engines = [ "engine-a" "engine-b" "mwmbl" ];
```

The order matters, which is why there is no default: searchcast stops at the first engine that answers, and an answer of "no results" counts. Put first the engines you trust to answer well, over Tor as well (the anonymous accounts always search through Tor), and the ones that sometimes come back empty after them.

The archive is the format `searchcast install-recipes` takes (a `.tar.gz` of `*.mjs` code recipes and an optional `manifest.json`, at its root or under one directory). Nix downloads it when the system is built, checks the sha256 and unpacks it into the store; webveil loads it from there. Two things to know before you do:

- **The URL goes into your config.** If you publish your config repo, you publish where your recipes come from. For a set you keep private, put it in a private flake input or a local path and set `wabisabi.search.recipeSet` to it instead.
- **Recipes are code**, run by webveil with full Node access, as you and as each anonymous account. Pin only a set you trust: the sha256 is that trust decision, and nothing but those exact bytes is ever loaded.

`wabisabi.search.viaTor` sends the searches through Tor with either backend. With searchcast that is webveil's own egress, so `web_fetch` goes through Tor as well. The download of the recipe set itself does not: it comes from the machine's own address when the system is built.

To switch back to SearXNG, set `wabisabi.search.backend = "searxng";` (the recipe set can stay in the config, unused) or remove `wabisabi.search.recipes`, then rebuild.

## Architecture

```
┌─ user's flake ──────────────────────────────┐
│  hardware-configuration.nix   (their disks) │
│  nixos-hardware module         (their CPU)  │
│  wabisabi.nixosModules.wabisabi  ──┐      │
│  wabisabi.homeModules.wabisabi  ──┤      │
│  their overrides / other options     │      │
└──────────────────────────────────────┼──────┘
                                       ▼
       modules/  — system layer: services, programs, zero hardware
       home/     — user layer: apps, dotfiles, keybinds, theme
       hosts/    — demo VM (proves the layers are hardware-agnostic)
       template/ — what `nix flake new -t` scaffolds for users
```

Every value in both layers uses `lib.mkDefault`, so **anything the user sets
wins**. Options are the API — extend, override, or ignore any part.

## Usage

Try it in a VM (no hardware needed):

```sh
nix flake check              # validate: evaluates every layer, runs `niri validate`,
                             # and checks the installer against the options
./scripts/run-vm-gl.sh       # build if needed, then boot it
```

On NixOS you can skip the script and use the VM directly:

```sh
nix build .#nixosConfigurations.demo.config.system.build.vm
./result/bin/run-nixos-vm
```

(`nixos-rebuild build-vm --flake .#demo` is the same thing, but `nixos-rebuild`
only exists on NixOS hosts.)

Log in as `demo` / `demo`. Use `Alt+*` keybinds (host desktops eat `Super`).

> **The VM needs a real GPU render node, and this is not negotiable.** niri
> refuses to run on a software EGL renderer (llvmpipe), so a VM with QEMU's
> default emulated VGA gives you a **black screen** rather than a slow
> desktop: niri is running fine, with a Wayland socket and working IPC, it
> just cannot render. `hosts/demo.nix` therefore asks for
> `-device virtio-vga-gl`, which gives the guest VirGL and a real
> `/dev/dri/renderD128`.
>
> The QEMU from nixpkgs supports that device, but on a **non-NixOS host** it
> cannot load the host's GL drivers (it looks in `/run/opengl-driver`, a
> NixOS-only path) and dies with `egl: render node init failed`. That is what
> `./scripts/run-vm-gl.sh` is for: it swaps in your host's QEMU, which finds
> your host's Mesa. On NixOS you do not need it.
>
> The demo VM also sets `terminal = "foot"` and `animations = false`. Ghostty
> compiles shaders on first launch, which takes about 35 seconds on a virtual
> GPU. On real hardware neither workaround is needed.
>
> **The VM disk image is disposable, and `run-vm-gl.sh` recreates it every
> run.** That is deliberate: in a NixOS build-vm the guest's `/nix/store` is an
> overlay whose upper layer is a *tmpfs*, while `/home` and `/nix/var` live on
> the qcow2 and survive a reboot. Boot the same image twice and the
> home-manager profile points at store paths that were wiped with the tmpfs,
> so activation fails with `[FAILED] Failed to start Home Manager environment`
> and you silently get a stale session. `--keep` reuses the image if you
> really want to.
>
> If the window is black through the whole boot but you can log in blind and
> get a desktop, your host is not showing QEMU's 2D console scanout. Try
> `QEMU_OPTS="-display gtk,gl=on"` or `QEMU_OPTS="-display sdl,gl=off"`.

## Installing it

### With the ISO

Download one from [wabisabi.computer](https://wabisabi.computer) (the live ISO, or the smaller netinstall one), or build it yourself from any release tag:

```sh
nix build github:wighawag/wabisabi#iso-netinstall   # small, needs a network
nix build github:wighawag/wabisabi#iso-offline      # LIVE: try it first; carries everything, installs with no network
# write result/iso/*.iso to a USB stick, boot it, then:
sudo wabisabi-install
```

It asks for the machine's identity (hostname, user, password, timezone, locale, **keyboard layout**), then for the disk, then whether to set up **encrypted secrets** (recommended, see below), and then offers wabisabi's own options: greeter, shell, terminal, browser, file manager, apps, services. Skip that last part and you get the defaults, which are not written into your config and therefore keep following the project.

What it leaves behind is **an ordinary flake you own** at `~/nixos`, with `/etc/nixos` a link to it: `flake.nix`, `configuration.nix`, the `hardware-configuration.nix` it generated, a `flake.lock` pinned to exactly the revision the ISO installed, and with secrets set up, `.sops.yaml` and `secrets/secrets.yaml`. It is a git repo with two commits: the install, then the secrets. Nothing reads it back, nothing manages it, and removing the two module imports leaves you with a working NixOS machine that has never heard of wabisabi.

### Your config repo

`~/nixos` is the machine. The ISO is only the bootstrap: from then on, the machine changes when the repo changes.

```sh
cd ~/nixos && $EDITOR configuration.nix
sudo nixos-rebuild switch          # /etc/nixos links here, so no --flake needed
git commit -am "..." && git push   # after `git remote add origin ...` once
```

**Secrets.** The repo holds only what evaluation needs in the clear. Values that should not be public (your password's hash first, then any token you add) live in `secrets/secrets.yaml`, encrypted with [sops](https://github.com/getsops/sops) to one age key per repo. Only the key's public half is in the repo, so the repo can be pushed anywhere. The private key is in two places on the machine: `/var/lib/sops-nix/key.txt`, which sops-nix reads at boot, and `~/.config/sops/age/keys.txt`, which you use to edit. The installer shows it to you once and asks you to save a copy somewhere else. Keep that copy: the repo plus the key is the whole machine.

```sh
wabisabi-secrets edit       # the secrets file, decrypted, in $EDITOR
wabisabi-secrets password   # change your login password, in the repo AND now
wabisabi-secrets backup     # show the key again (text and QR code)
wabisabi-secrets init       # set it all up later, if you skipped it at install
```

Change your password with `wabisabi-secrets password`. Plain `passwd` still works, but only on this machine: NixOS applies a declared password when it creates the account, so a reinstall would bring back the one in the repo.

Only values can be secret. sops-nix decrypts on the machine at activation, after Nix has evaluated the config, so the username, the hostname and which services run are in the clear by construction. If those should not be public, keep the repo private.

**From another machine.** Edit a clone anywhere and deploy it over ssh. The secrets are decrypted on the target with the target's own key, so the machine you deploy from does not need the key (only editing the secrets does):

```sh
nixos-rebuild switch --flake .#HOSTNAME --target-host you@HOSTNAME --sudo
```

**After a wipe, or on a new disk.** Boot the ISO, run `sudo wabisabi-install`, and choose `restore` at the first question. It asks for the repo (anything `git clone` takes: a URL, or a path on a USB stick) and your age key, and then only for the disk. Everything else is read from the repo: hostname, user, keyboard, every option, and your password (from the encrypted secrets). Before touching the disk it proves the key opens the repo's secrets and evaluates the whole system, so a wrong key or a config that no longer builds stops it with nothing wiped. The only change it makes to your repo is a new `hardware-configuration.nix` for the new disks, as one commit you can push.

```sh
wabisabi-install --answers restore.json   # the same, unattended:
# { "install:mode": "restore", "restore:source": "https://...", "restore:ageKey": "AGE-SECRET-KEY-1...",
#   "disk:device": "/dev/nvme0n1", "disk:layout": "luks", "disk:passphrase": "..." }
```

On the offline ISO a restore works with no network only if the repo's `flake.lock` still pins what the medium carries; once you have updated, restore from the netinstall ISO or with a network.

**A fleet repo works too**, where the wabisabi machine is one host among several (colmena, nixos-anywhere, per-host keys). Restore follows what the chosen host's config declares and only falls back to its own conventions where the config says nothing:

- **Disks.** A config that declares them with [disko](https://github.com/nix-community/disko) is partitioned by that declaration (`disko --flake repo#host`), and the repo goes back untouched. Otherwise the config must take its root filesystem from `./hardware-configuration.nix`, which restore regenerates; anything else is refused before the disk is touched, because partitioning it any other way gives a machine that installs and does not boot.
- **Access.** `restore:sshKeyFile` (a key file on the USB stick) is used for the clone and for `git+ssh://` flake inputs, from RAM, and never copied to the disk.
- **Secrets encrypted to the host's SSH key.** Declare what has to be on disk before the first boot, and restore decrypts it with the key you give it (the admin key, in a fleet) and puts it in place:

  ```nix
  wabisabi.restore.files."/etc/ssh/ssh_host_ed25519_key" = {
    sopsFile = ../../secrets/laptop/ssh-host-key;   # encrypted to the admin key
    mode = "0600";
  };
  ```

- **The key you give it** goes only where the config reads one: both places for a config made by `wabisabi-secrets`, `sops.age.keyFile` if the config names one, and otherwise nowhere. An admin key is not left on a laptop as a side effect of reinstalling it.
- **The password** the config declares (its own sops secret, a hash) is trusted, not asked for.
- **Where the repo goes** is asked (`restore:repoPath`), defaulting to the `/etc/nixos` link the config declares, or `~/nixos`.

**The offline ISO is a live system.** It boots straight into the wabisabi desktop (user `nixos`, no password), so the machine can be tried before anything touches its disk: a welcome terminal says what to try and holds the install command. Everything runs from the stick and from RAM; the local model starts on first use rather than at boot, to spare that RAM. Its boot menu also has a **text installer only** entry, which is the plain installer with no desktop.

niri refuses a software renderer, so a live desktop on a machine with no usable GPU would be a black screen with niri running behind it. The live session therefore waits for the GPU driver and, if there is still no render node, starts a text shell that says so and how to install instead. The netinstall ISO stays text-only and small.

The installer also runs unattended, with the same questions in a file:

```sh
wabisabi-install --answers answers.json          # install
wabisabi-install --answers answers.json --out-only ./out   # just write the flake, touch no disk
```

See [`notes/installer.md`](notes/installer.md) for how it works, what is verified and what is not.

### By hand, without the ISO

```sh
nix flake new -t github:wighawag/wabisabi ~/nixos
# edit configuration.nix (username, hostname, stateVersion), drop in
# hardware-configuration.nix, pick a nixos-hardware module, then:
cd ~/nixos && git init && git add -A
sudo nixos-rebuild switch --flake ~/nixos
wabisabi-secrets init    # optional: sops secrets, starting with your password
```

The installer fills in this same template, so the two paths cannot diverge.

## Adopting on an *existing* NixOS config

The template scaffolds a fresh machine, but the same two modules compose into
a config you already have — nothing about wabisabi requires owning the flake.

**1. Add the input**, following your nixpkgs so the module layers evaluate
against *your* pin (they are plain modules: `pkgs` comes from whichever
`nixosSystem` imports them, never from this repo's lock):

```nix
wabisabi = {
  url = "github:YOUR_NAME/wabisabi";
  inputs.nixpkgs.follows = "nixpkgs";
  # If your config already imports sops-nix: follow yours, so both imports
  # are the same module and it is not declared twice.
  # inputs.sops-nix.follows = "sops-nix";
};
```

**2. Import the system layer into your host's module list** — it is inert
until you opt in, so importing it everywhere is safe:

```nix
modules = [
  wabisabi.nixosModules.wabisabi   # inert until wabisabi.enable = true
  ./hosts/my-laptop
  ...
];
```

**3. Opt in per host / per user** — system defaults in the host module, the
home layer under your existing `home-manager.users.<name>`:

```nix
{
  wabisabi.enable = true;                 # system layer
  home-manager.users.me = {
    imports = [ wabisabi.homeModules.wabisabi ];
    wabisabi.enable = true;               # apps, dotfiles, keybinds
  };
}
```

Everything both layers set is `mkDefault`, so your config wins every merge,
and each `wabisabi.*` option is a seam to override any default.

Already have a `nixosConfiguration` you don't want to touch? `extendModules`
composes the layers on top of it without editing it (this is exactly how the
compose was verified against an independent fleet repo — see
[`notes/composition-verification.md`](notes/composition-verification.md) for
what was tested and the version constraints found):

```nix
myboxes.nixosConfigurations.somehost.extendModules {
  modules = [
    wabisabi.nixosModules.wabisabi
    home-manager.nixosModules.home-manager
    {
      wabisabi.enable = true;
      home-manager.users.me = {
        imports = [ wabisabi.homeModules.wabisabi ];
        wabisabi.enable = true;
      };
    }
  ];
};
```

### Version constraints (verified, not guessed)

- The **system layer** (`nixosModules.wabisabi`) composes with nixpkgs 26.05
  and home-manager release-26.05 — no skew found.
- The **home layer** currently needs home-manager **master**: it configures
  `wayland.windowManager.niri`, which landed in HM after the 26.05 branch and
  does not exist in `home-manager/release-26.05`.
- Pairing HM master with a *stable* nixpkgs pin can surface assertion skew.
  The one hit so far was fzf (HM master wanted ≥ 0.73.0 for nushell
  integration, 26.05 ships 0.72.0); the home layer no longer enables HM's fzf
  (the shell lives in the system layer now), so it no longer applies to
  wabisabi's own settings.


## The compositor

niri is a **scrollable-tiling** compositor: windows sit in columns on an
infinite horizontal strip, and opening a window never resizes the windows you
already have. Workspaces are vertical, so the session is a grid: scroll left
and right through a workspace, up and down between workspaces.

The home-manager module runs `niri validate` on the generated config *inside
the build*, so a bad option fails `nixos-rebuild` rather than dropping you at
a black screen. See [`notes/compositor-alternatives.md`](notes/compositor-alternatives.md)
for why niri and not Sway, SwayFX or Hyprland, and what it would cost to add
one of them back.

## The keyboard layout

`wabisabi.keyboard.layout` (plus `.variant` and `.options`) is one setting for three keyboards, which is why it is an option rather than something you run once by hand.

niri deliberately keeps no copy of the layout: with an empty `xkb` block it asks systemd-localed, and localed reads `/etc/X11/xorg.conf.d/00-keyboard.conf`, which NixOS generates from `services.xserver.xkb.*` whenever a display manager is enabled. So this reaches the compositor with no X server anywhere in sight.

The other two keyboards are the text ones. The option also switches on `console.useXkbConfig`, which carries the layout to the VT **and into the initrd** -- so a LUKS passphrase chosen on a French keyboard is still typeable at the next boot. Getting that wrong produces a machine its owner cannot unlock, with nothing on screen to explain why, and it is the one thing the VM install test checks by physically typing the passphrase in the other layout.

## Keybinds (defaults, `modKey = SUPER`)

> The demo VM uses `modKey = ALT` instead: your host desktop eats `Super+...`
> inside QEMU. On real hardware, leave the default.

`Super+Shift+/` shows the full cheat sheet at any time.

| Keys | Action |
|---|---|
| `Super+Enter` | Terminal |
| `Super+D` | Launcher (fuzzel) |
| `Super+B` / `Super+E` | Browser / Files |
| `Super+A` | The assistant (the local AI's web UI) |
| `Super+Q` | Close window (`Super+Shift+Q` quits, with confirmation) |
| `Super+H/J/K/L` | Focus: left/right move between columns, up/down within one |
| `Super+Ctrl+H/J/K/L` | Move the window (Ctrl, not Shift: `Super+Shift+L` is lock) |
| `Super+1..9` | Workspaces (`+Shift` moves the column there) |
| `Super+U` / `Super+I` | Workspace down / up |
| `Super+O` | Overview |
| `Super+Space` / `Super+F` | Float / Fullscreen (`+Shift+F` maximises the column) |
| `Super+R` | Cycle column width (`Super+-` / `Super+=` for fine steps) |
| `Super+[` / `Super+]` | Pull a window into / push it out of the column |
| `Super+W` | Tabbed column display |
| `Super+C` | Centre the column |
| `Super+Shift+S` | Screenshot (interactive: region, window or screen) |
| `Print` / `Alt+Print` | Screenshot whole screen / focused window |
| `Super+Shift+R` | Toggle screen recording |
| `Super+Shift+L` | Lock (auto-locks after 5 min idle) |
| `Super+Shift+P` | Power off the monitors |
| `Super+Escape` | Release keyboard shortcuts to the focused app |

## The look

One palette draws the whole machine: `wabisabi.theme`, set once on the system layer and followed by the home layer. The palettes are data, in [`theme/palettes.nix`](theme/palettes.nix):

- **`sumi`** (墨, ink, the default) is sampled from the default wallpaper, an enso printed in indigo ink on warm paper, with a few pigment colours muted enough to sit on paper. The [website](https://wighawag.github.io/wabisabi-website/) uses the same values.
- **`catppuccin-mocha`** is the previous default, kept as a choice.

It reaches the boot splash, the greeter, Noctalia (as a palette file) or the classic Waybar/fuzzel/mako/swaylock, niri's focus ring, GTK3 and GTK4 apps, and the terminals; Helix follows through the terminal's own colours. `wabisabi.wallpaper` sets the desktop, lock screen and greeter background (default: the enso, CC0, see [`artwork/`](artwork/README.md)).

Not yet: the shell prompt, `ls` colours and fzf are drawn by [nixos-modules](https://github.com/wighawag/nixos-modules)' interactive shell, which only knows Catppuccin so far, and Neovim keeps its own default colours.

Noctalia's and the greeter's configs are **seeded, not owned**: a machine installed before this palette keeps the look it chose until you pick "wabisabi-sumi" in Noctalia's settings (the palette file is there either way).

## Boot appearance

`wabisabi.splash.enable` (default true) quiets the boot and shows a splash: under `sumi`, an enso that is painted as the machine starts (Plymouth learns how long boots take and paces the brush to it), its dry tail closing the circle as the boot ends. The same screen asks for the disk passphrase. Under Catppuccin it is the Catppuccin Plymouth theme.

`wabisabi.splash.hideBootMenu` (default true) skips systemd-boot's menu, so the machine goes from the firmware logo straight to the splash. **Hold Space while it starts** to get the menu, which is how you boot an older generation to roll back.

The splash hands over to the graphical greeter without a flash of console: plymouth is only deactivated at the end of the boot, so the finished enso stays up until the greeter draws over it, and quits afterwards. The ISOs' own boot menu (GRUB, UEFI) is themed from the wallpaper too.

None of this hides failures. Password prompts, fsck questions and the emergency shell still appear, so a broken boot is still visible and still interactive. Set `wabisabi.splash.enable = false` if you would rather watch every unit start.

For the graphical splash to actually appear (rather than Plymouth falling back to printing the boot log), your GPU driver has to be in the initrd, which is hardware knowledge and therefore yours, not this module's (the installer fills it in):

```nix
boot.initrd.kernelModules = [ "amdgpu" ];   # or i915, nouveau, ...
```

Most `nixos-hardware` profiles already do this. `hosts/demo.nix` does it for the VM's virtual GPU. The splash, the passphrase prompt and the handover were verified in QEMU (plain `virtio-vga`, filmed through QMP screendumps). One thing about testing it in a VM: the VM's kernel command line has `console=ttyS0`, and Plymouth deliberately falls back to text when it sees a serial console, so add `plymouth.ignore-serial-consoles` there. Real machines have no serial console and need nothing.

## Extending

- Add an option in `home/options.nix` (or `modules/options.nix`), gate the
  config on it, default it with `mkDefault`.
- Never use `mkForce` — that's how shared layers become hostile.
- Keep hardware knowledge out of `modules/` and `home/` — that belongs to
  the user's layer (nixos-hardware etc.).
- Keep the look in the portable layer. The palette (`theme/palettes.nix`,
  read through `wabisabi.theme`) themes the bar, launcher, notifications,
  lock screen and GTK, none of which know what compositor they run under. A
  new colour role goes in every palette at once. Only the keybinds,
  the Waybar workspaces module and the portal set are compositor-specific.

On a machine with no accelerated GPU driver, set `wabisabi.animations = false`:
under llvmpipe every animation frame is a full-screen CPU blit. The demo VM
already does this.
## Releases

The ISOs are downloaded from a Cloudflare R2 bucket served at `downloads.wabisabi.computer`, one folder per version, plus a `releases.json` listing what is there, which the website reads live. [`scripts/release.sh`](scripts/release.sh) is the whole process:

```sh
git tag v0.2.0 && git push origin v0.2.0
scripts/release.sh publish 0.2.0 --dry-run   # builds, checksums, shows every upload and deletion
scripts/release.sh publish 0.2.0             # ... and does them; keeps only the newest version
scripts/release.sh publish 0.2.0 --keep 3    # keeps the newest three instead
scripts/release.sh delete 0.1.0              # removes one version
scripts/release.sh list
```

`publish` builds both ISOs from the tag on GitHub (the netinstall image rebuilt from `v0.1.0` came out byte-identical to the published one), uploads them with a `SHA256SUMS`, and writes the checksums into the GitHub release's notes as well, so a tampered bucket cannot also rewrite GitHub. The netinstall ISO is attached to the GitHub release too, as the website's fallback download, and the website is rebuilt to pick it up. Only the newest version is kept by default, because an offline ISO is about 9 GB of storage; a deleted version is never lost, since its tag rebuilds it. It needs an R2 API token (Object Read & Write, this bucket only) as `R2_ACCOUNT_ID`, `R2_ACCESS_KEY_ID` and `R2_SECRET_ACCESS_KEY`, in the environment or in `~/.config/wabisabi/r2.env`.

The one-time Cloudflare setup (bucket, domain, CORS, upload key) and the reasons behind all this: [`notes/releasing.md`](notes/releasing.md).

## Notes

- [`notes/releasing.md`](notes/releasing.md): where the ISOs are published, the one-time Cloudflare setup, and a release step by step.
- [`notes/agents.md`](notes/agents.md): the agent layer (local model, search,
  pi and wherever, anonymous accounts), its design and what is verified.
- [`notes/installer.md`](notes/installer.md) — how the ISO and installer work,
  the decisions behind them, what is verified against a real VM install and
  what is not.
- [`notes/open-items.md`](notes/open-items.md) — what has actually been verified
  against a booted VM, what has not, and the next steps in order.
- [`notes/composition-verification.md`](notes/composition-verification.md) —
  proof that the layers compose into an *existing* NixOS config (verified
  against my-boxes' telemaque), and the version constraints that came out of it.
- [`notes/compositor-alternatives.md`](notes/compositor-alternatives.md) — why
  niri and not Sway, SwayFX or Hyprland, and what swapping would cost.
