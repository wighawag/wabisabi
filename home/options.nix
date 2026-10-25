{ lib, pkgs, osConfig ? null, ... }:

let
  # The system layer's value when this home is part of a NixOS config that
  # has one, so a machine is themed from one place; otherwise our own default.
  fromSystem = name: fallback:
    if osConfig != null && (osConfig.wabisabi.enable or false)
    then osConfig.wabisabi.${name}
    else fallback;
in
{
  options.wabisabi = {
    enable = lib.mkEnableOption "the wabisabi home layer (apps + dotfiles)";

    theme = lib.mkOption {
      type = lib.types.enum (lib.attrNames (import ../theme/palettes.nix));
      default = fromSystem "theme" "sumi";
      defaultText = lib.literalExpression ''osConfig.wabisabi.theme, or "sumi"'';
      description = ''
        The palette this home's apps are drawn in (theme/palettes.nix). Follows
        the system layer's `wabisabi.theme`, so it is normally set there.
      '';
    };

    wallpaper = lib.mkOption {
      type = lib.types.path;
      default = fromSystem "wallpaper"
        "${pkgs.callPackage ../pkgs/wabisabi-artwork/package.nix { }}/share/backgrounds/wabisabi/enso.jpg";
      defaultText = lib.literalExpression ''osConfig.wabisabi.wallpaper, or the enso'';
      description = ''
        The wallpaper of the desktop and the lock screen. Follows the system
        layer's `wabisabi.wallpaper`, so it is normally set there. Noctalia
        users can also pick one in its settings; that choice is kept.
      '';
    };

    shell = lib.mkOption {
      type = lib.types.enum [ "noctalia" "classic" ];
      default = "noctalia";
      description = ''
        Which desktop SHELL owns the bar, launcher, notifications, lock
        screen, wallpaper and OSDs.

        "noctalia" is one cohesive shell (MIT, native Wayland/GLES) that owns
        all of those surfaces, configured through its own settings GUI with
        hot reload. This module SEEDS its config once and then leaves it
        alone: the app owns the file, so the GUI can actually save.

        "classic" is the original stack of single-purpose pieces: Waybar +
        fuzzel + mako + swaylock + swayidle. More parts to keep visually
        consistent, but each is independently replaceable and every setting
        is declarative.

        The compositor is niri either way; this option changes only the
        shell layer around it.
      '';
    };

    modKey = lib.mkOption {
      type = lib.types.enum [ "SUPER" "ALT" "CTRL" ];
      default = "SUPER";
      description = ''
        Primary modifier for all keybinds.
        Use "ALT" when testing in a VM: host desktops swallow Super+...
        before QEMU can see them.
      '';
    };

    animations = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Compositor animations (window open/close, workspace switch, strip
        scrolling, overview).

        Turn this off on machines with no accelerated GPU driver: under
        llvmpipe every animation frame is a full-screen CPU blit, which is
        the difference between smooth and unusable. The demo VM sets this
        to false for exactly that reason.
      '';
    };

    terminal = lib.mkOption {
      type = lib.types.enum [ "ghostty" "foot" "kitty" ];
      default = "ghostty";
      description = "Terminal emulator.";
    };

    editor = lib.mkOption {
      type = lib.types.enum [ "neovim" "helix" ];
      default = "neovim";
      description = "Default $EDITOR (both are installed either way).";
    };

    browser = lib.mkOption {
      type = lib.types.enum [ "firefox" "librewolf" "chromium" "none" ];
      default = "firefox";
      description = "Web browser. All FOSS builds, no vendor telemetry.";
    };

    fileManager = lib.mkOption {
      type = lib.types.enum [ "thunar" "nautilus" "yazi" "none" ];
      default = "thunar";
      description = ''
        File manager, and the one bound to Mod+E.

        "yazi" is the odd one and worth understanding before picking it: it
        is a TUI, so it opens IN THE TERMINAL and has no XDG portal
        implementation. That does NOT cost you a file chooser -- "open a
        file" from Firefox is answered by the GTK PORTAL, which brings its
        own dialog and never involved Thunar (see modules/desktop.nix, where
        niri's `useNautilus` is off for exactly this reason). So choosing
        yazi means "no GUI file manager installed", not "no way to pick a
        file".

        "none" installs nothing and leaves Mod+E opening a terminal.
      '';
    };

    apps.media = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Media: mpv (video) + imv (images).";
    };

    apps.office = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "LibreOffice suite.";
    };

    apps.email = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Thunderbird (IMAP — works with any provider incl. self-hosted).";
    };

    apps.passwords = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "KeePassXC — local-first password database (no cloud service).";
    };

    apps.reading = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Reading: Papers (PDF and other documents, GNOME's GTK4 viewer) and Foliate (ebooks).";
    };

    apps.creative = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Creative: GIMP (raster images), Inkscape (vector drawing) and OBS
        Studio (recording and streaming, with its browser source). Large:
        about 3.7 GB, two thirds of it OBS's embedded browser.
      '';
    };

    apps.torrent = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "qBittorrent, a BitTorrent client with no account, no ads and a search plugin system.";
    };

    apps.syncthing = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Syncthing — peer-to-peer sync, self-hostable by design.";
    };
  };
}