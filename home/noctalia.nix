{ lib, pkgs, config, noctaliaSrc, ... }:

# Noctalia: one shell owning bar, dock, launcher, control center,
# notifications, wallpaper, lock screen, OSDs and clipboard history, instead of
# the five single-purpose daemons in desktop.nix. MIT, native Wayland + OpenGL
# ES, no Qt or GTK dependency.
#
# BUILT FROM SOURCE, NOT CONSUMED AS A FLAKE, and that is a deliberate choice
# with a concrete payoff: upstream's flake pins its own nixos-unstable, so
# taking their outputs drags a SECOND nixpkgs into every consumer's closure and
# makes the shell's GL stack disagree with the compositor's. Their
# `nix/package.nix` is a plain callPackage file, so building it against OUR
# pkgs sidesteps that entirely and keeps one nixpkgs per machine. The source
# is pinned in flake.lock and injected as `noctaliaSrc`.
#
# WE ALSO DO NOT USE THEIR HOME MODULE, for a sharper reason. It sets
# `xdg.configFile."noctalia/config.toml".source`, which makes the config a
# READ-ONLY STORE SYMLINK -- and Noctalia's whole configuration model is a
# settings GUI with hot reload. A shell whose settings panel cannot save is
# worse than one with no settings panel. This module therefore SEEDS the
# config once and never touches it again: the app owns the file.
#
# That is the same rule this repo applies elsewhere (settings.json is seeded,
# not owned) and the one my-boxes learned from `~/.config/git/config` being a
# store symlink, which makes `git config --global` fail forever.

let
  cfg = config.wabisabi;

  # One patch to the shell's text: its first-run window greets the machine,
  # not the shell ("Welcome", not "Welcome to Noctalia"). English only; other
  # languages keep upstream's wording. --replace-fail, so an upstream rewording
  # breaks the build instead of silently bringing the old title back.
  noctalia = (pkgs.callPackage "${noctaliaSrc}/nix/package.nix" { }).overrideAttrs (old: {
    postPatch = (old.postPatch or "") + ''
      substituteInPlace assets/translations/en.json --replace-fail \
        '"title": "Welcome to Noctalia",' '"title": "Welcome",'
    '';
  });

  # The seed. Deliberately MINIMAL: enough that a fresh machine looks right
  # (the font the rest of the desktop uses, a dark theme), and nothing else.
  # Every other setting is the GUI's business, and anything written here that
  # the user later changes would look like a setting that "resets itself" if
  # this file were ever re-applied.
  #
  # The one addition is the assistant's bar button (home/assistant.nix), when
  # this home has an assistant. It needs the whole `end` list spelled out,
  # since Noctalia replaces rather than extends it: this is upstream's default
  # (src/config/config_types.h) with "assistant" in front. Being part of the
  # seed, it reaches only a home seeded after it exists; an existing config is
  # the user's, so add the widget there from the settings GUI if wanted.
  assistantBar = lib.optionalString cfg.assistant.enable ''

    [bar.main]
    end = ["assistant", "media", "tray", "notifications", "clipboard", "network", "bluetooth", "volume", "brightness", "battery", "control-center", "session"]

    [widget.assistant]
    type = "custom_button"
    glyph = "robot"
    tooltip = "Assistant"

    [widget.assistant.actions]
    left = "exec wabisabi-assistant"
  '';

  # `after-noctalia-intro CMD...`: run CMD once Noctalia's own first-login
  # intro has been closed, so a welcome of ours never lands on top of it.
  # Noctalia writes this marker when the intro is finished OR dismissed, and
  # reads it to decide whether to show the intro at all (setup_wizard_panel.cpp,
  # config_service.cpp). With the intro switched off the marker never comes, so
  # that case does not wait. Under the classic shell there is no intro and the
  # wrapper is a plain exec.
  afterIntro = pkgs.writeShellApplication {
    name = "after-noctalia-intro";
    runtimeInputs = [ pkgs.coreutils pkgs.gnugrep ];
    text =
      lib.optionalString (cfg.shell == "noctalia") ''
        state="''${NOCTALIA_STATE_HOME:+$NOCTALIA_STATE_HOME/noctalia}"
        state="''${state:-''${XDG_STATE_HOME:-$HOME/.local/state}/noctalia}"
        if ! cat "$HOME/.config/noctalia/config.toml" "$state/settings.toml" 2>/dev/null \
             | grep -Eq '^[[:space:]]*setup_wizard_enabled[[:space:]]*=[[:space:]]*false'; then
          while [ ! -e "$state/.setup-complete" ]; do sleep 2; done
        fi
      ''
      + ''
        exec "$@"
      '';
  };

  # The palette (theme/palettes.nix via `wabisabi.theme`). Catppuccin is one
  # of Noctalia's builtin palettes; sumi is shipped as a custom palette file
  # in Noctalia's own format, from the same role mapping the greeter uses
  # (theme/noctalia.nix), so the login screen and the shell match.
  c = (import ../theme/palettes.nix).${cfg.theme};
  sumi = cfg.theme == "sumi";
  paletteName = "wabisabi-sumi";
  roles = import ../theme/noctalia.nix c;
  # primary -> mPrimary, on_surface_variant -> mOnSurfaceVariant
  mName = role: "m" + lib.concatMapStrings
    (w: lib.toUpper (lib.substring 0 1 w) + lib.substring 1 (-1) w)
    (lib.splitString "_" role);
  ansiNames = [ "black" "red" "green" "yellow" "blue" "magenta" "cyan" "white" ];
  ansiSet = offset: lib.listToAttrs (lib.imap0
    (i: n: lib.nameValuePair n "#${lib.elemAt c.ansi (i + offset)}") ansiNames);
  paletteFile = (pkgs.formats.json { }).generate "${paletteName}.json" {
    dark = lib.mapAttrs' (role: v: lib.nameValuePair (mName role) v) roles // {
      terminal = {
        background = "#${c.base}";
        foreground = "#${c.text}";
        cursor = "#${c.bright}";
        cursorText = "#${c.base}";
        selectionBg = "#${c.surface2}";
        selectionFg = "#${c.bright}";
        normal = ansiSet 0;
        bright = ansiSet 8;
      };
    };
  };

  # The wallpaper link home/desktop.nix makes, at a path that does not change
  # when the image does: this file is seeded once, so a store path in it would
  # dangle after the next garbage collection.
  wallpaperExt = let m = builtins.match ".*(\\.[A-Za-z0-9]+)" (toString cfg.wallpaper); in if m == null then "" else lib.head m;
  wallpaperPath = "${config.xdg.dataHome}/wabisabi/wallpaper${wallpaperExt}";

  seed = pkgs.writeText "noctalia-config.toml" (''
    # Seeded ONCE by wabisabi on first login, then yours. Edit freely, in this
    # file or in Noctalia's settings GUI; nothing rewrites it.
    [shell]
    font_family = "JetBrainsMono Nerd Font"

    [theme]
    mode = "dark"
  '' + (if sumi then ''
    source = "custom"
    custom_palette = "${paletteName}"
  '' else ''
    source = "builtin"
    builtin = "Catppuccin"
  '') + ''

    [wallpaper]
    enabled = true
    fill_mode = "crop"
    fill_color = "#${c.base}"

    [wallpaper.default]
    path = "${wallpaperPath}"
  '' + assistantBar);
in
{
  options.wabisabi.afterNoctaliaIntro = lib.mkOption {
    type = lib.types.package;
    readOnly = true;
    internal = true;
    default = afterIntro;
    description = "`after-noctalia-intro CMD...`: run CMD once Noctalia's first-login intro is closed (a plain exec under the classic shell).";
  };

  config = lib.mkIf (cfg.enable && cfg.shell == "noctalia") {
    home.packages = [ noctalia ];

    # The palette file is ours and follows the flake, unlike config.toml: it
    # only DEFINES a palette, and choosing another one in the settings is a
    # config.toml change, which stays the user's.
    xdg.configFile."noctalia/palettes/${paletteName}.json" = lib.mkIf sumi { source = paletteFile; };

    # Seed-if-absent. `-n` is the whole contract: present file wins, always.
    # Runs before home-manager's file linking so a first login has the config in
    # place when the service starts.
    home.activation.seedNoctaliaConfig = lib.hm.dag.entryBefore [ "writeBoundary" ] ''
      run mkdir -p "$HOME/.config/noctalia"
      run cp -n ${seed} "$HOME/.config/noctalia/config.toml" || true
      run chmod u+w "$HOME/.config/noctalia/config.toml" || true
    '';

    # A user service rather than a compositor spawn, matching every other piece
    # of the session: restarting niri does not orphan the shell, and the shell
    # can be restarted without touching niri.
    systemd.user.services.noctalia = {
      Unit = {
        Description = "Noctalia - Wayland desktop shell";
        Documentation = "https://docs.noctalia.dev/";
        PartOf = [ config.wayland.systemd.target ];
        After = [ config.wayland.systemd.target ];
      };
      Service = {
        ExecStart = lib.getExe noctalia;
        Restart = "on-failure";
        RestartSec = 2;
      };
      Install.WantedBy = [ config.wayland.systemd.target ];
    };
  };
}
