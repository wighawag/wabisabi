{ lib, pkgs, config, ... }:

# The session: niri compositor, greetd login, Wayland CLI tools.
# User-facing apps and dotfiles live in the home-manager layer (../home).

let
  cfg = config.wabisabi;

  noctaliaGreeter = cfg.greetd.enable && cfg.greetd.greeter == "noctalia";

  palette = (import ../theme/palettes.nix).${cfg.theme};

  # The wallpaper at a path that does not change when the image does: the
  # greeter's state keeps the path, and a store path there would dangle as
  # soon as the old image is garbage-collected. The extension is kept, for
  # loaders that go by it.
  wallpaperExt = let m = builtins.match ".*(\\.[A-Za-z0-9]+)" (toString cfg.wallpaper); in if m == null then "" else lib.head m;
  wallpaperPath = "/etc/wabisabi/wallpaper${wallpaperExt}";

  # The greeter's look, as the file its own Sync writes: palette, wallpaper,
  # dark mode. SEEDED, not owned (see the tmpfiles rules below), so a user
  # who later syncs their Noctalia look to the greeter still can.
  greeterConfig = (pkgs.formats.toml { }).generate "noctalia-greeter.toml" {
    appearance.hide_logo = true;
  };

  greeterSeed = (pkgs.formats.toml { }).generate "noctalia-greeter-sync.toml" {
    appearance = {
      scheme = "Synced";
      theme_mode = "dark";
      palette = import ../theme/noctalia.nix palette;
      wallpaper = {
        path = wallpaperPath;
        fill_mode = "crop";
        fill_color = "#${palette.base}";
      };
    };
  };

  # THE ANON ACCOUNTS ARE NOT DESKTOP USERS, so the greeter does not offer
  # them. They have no password (they are entered with `sudo anonctl use`,
  # which changes uid without one), so picking one could only ever fail; and
  # a desktop session could not run in one anyway, because anon accounts are
  # refused the system bus (nixos-modules' anon-host-sockets), which a
  # compositor needs to be handed its seat by logind.
  #
  # The greeter lists every passwd user with uid >= 1000 and a real shell, and
  # has no setting to exclude one: its only filter is a hard-coded set of
  # system names, which this extends. `--replace-fail` makes an upstream change
  # to that line fail the build instead of silently listing them again.
  anonNames = lib.optionals (cfg.anon.enable && cfg.anon.accounts != { }) (lib.attrNames cfg.anon.accounts);

  # The greeter's compositor paints every screen black before the greeter
  # has drawn anything (render_output_black). That black frame sat between
  # the boot splash and the login screen, so it is painted in the palette's
  # base instead: the splash's ink goes straight on into the greeter's.
  # --replace-fail, again, so an upstream change breaks the build loudly.
  clearColour = let
    ch = i: toString (lib.fromHexString (lib.substring i 2 palette.base) / 255.0);
  in "{${ch 0}f, ${ch 2}f, ${ch 4}f, 1.0f}";

  greeterPackage = pkgs.noctalia-greeter.overrideAttrs (old: {
    postPatch = (old.postPatch or "") + ''
      substituteInPlace src/compositor/noctalia_compositor.c --replace-fail \
        '.color = {0.0f, 0.0f, 0.0f, 1.0f},' \
        '.color = ${clearColour},'
    '' + lib.optionalString (anonNames != [ ]) ''
      substituteInPlace src/greeter/greeter_surface.cpp --replace-fail \
        '"greeter", "greetd", "sddm", "lightdm", "gdm", "nobody",' \
        '"greeter", "greetd", "sddm", "lightdm", "gdm", "nobody", ${
          lib.concatMapStrings (a: "\"${a}\", ") anonNames
        }'
    '';
  });

  # greetd launches `noctalia-greeter-session` -- the WRAPPER, not the
  # `noctalia-greeter` binary: the wrapper starts the bundled wlroots
  # compositor and runs the greeter inside it. Pointing greetd at the bare
  # executable gives a greeter with no compositor to draw on.
  greeterCmd =
    if noctaliaGreeter
    then lib.getExe' greeterPackage "noctalia-greeter-session"
    else "${lib.getExe pkgs.tuigreet} --time --remember --remember-session --cmd '${lib.getExe' pkgs.systemd "systemd-cat"} --identifier=niri-session ${lib.getExe' pkgs.niri "niri-session"}'";
in
lib.mkIf cfg.enable {
  # niri — a scrollable-tiling compositor. The nixpkgs module does the
  # session wiring for us: the session package for display managers, the
  # systemd user units used by `niri-session`, gnome-keyring for the Secret
  # portal, and the portal config (niri prefers gnome + gtk; the gnome one
  # is what makes screencasting work).
  programs.niri = {
    enable = lib.mkDefault true;

    # The gnome portal uses Nautilus as its file chooser. We default to
    # Thunar, so route FileChooser at the GTK portal instead. Users who set
    # `wabisabi.fileManager = "nautilus"` can flip this back on.
    useNautilus = lib.mkDefault false;
  };

  security.polkit.enable = lib.mkDefault true;

  # swaylock authenticates through PAM. Without this service entry it can
  # take a password but never accept it, which locks you out of your own
  # session until you switch to a TTY.
  security.pam.services.swaylock = { };

  # tuigreet's --remember/--remember-session persist state in
  # $HOME/.cache/tuigreet. The greetd module creates the greeter user
  # without a home directory, which makes tuigreet crash on startup
  # (black screen with a blinking cursor). Give it a writable home.
  users.users.greeter = lib.mkIf cfg.greetd.enable {
    home = lib.mkDefault "/var/lib/greeter";
    createHome = lib.mkDefault true;
  };

  # The graphical greeter's own bits. WIRED HERE RATHER THAN VIA
  # `services.displayManager.noctalia-greeter`, and that is not
  # not-invented-here: that module only exists in nixpkgs UNSTABLE, while the
  # PACKAGE is in release channels too (verified on 26.05). Depending on the
  # module would make this option explode with "did you mean cosmic-greeter?"
  # on any consumer pinning a release. What the module does is small and
  # stable: a state dir, accountsservice, polkit, and greetd's command.
  services.accounts-daemon.enable = lib.mkIf noctaliaGreeter (lib.mkDefault true);

  # The greeter keeps state (last session, last user) here. Without the
  # directory it starts but cannot remember anything.
  systemd.tmpfiles.settings."10-noctalia-greeter" = lib.mkIf noctaliaGreeter {
    "/var/lib/noctalia-greeter".d = {
      user = "greeter";
      group = "greeter";
      mode = "0750";
    };
  };

  # The greeter's look, installed as the greeter's own files before it starts.
  # A unit rather than tmpfiles C/z rules: the directory belongs to the
  # greeter, and tmpfiles refuses to chown root-copied files inside it
  # ("unsafe path transition"), which left sync.toml read-only to the greeter
  # that has to write it.
  #
  #   greeter.toml  the admin half, which Sync never touches, so it is OURS
  #                 and rewritten on every boot: only what wabisabi decides
  #                 (the Noctalia mascot stays off, so the login screen is the
  #                 wallpaper and the form).
  #   sync.toml     palette, wallpaper, dark mode, in the file the greeter's
  #                 own Sync writes. SEEDED, installed only if absent: the
  #                 greeter writes it too (last session, last scheme) and a
  #                 user's Noctalia Sync replaces it, so owning it would undo
  #                 both on every boot.
  systemd.services.noctalia-greeter-seed = lib.mkIf noctaliaGreeter {
    description = "Seed the greeter's appearance";
    wantedBy = [ "greetd.service" ];
    before = [ "greetd.service" ];
    after = [ "systemd-tmpfiles-setup.service" ];
    serviceConfig.Type = "oneshot";
    path = [ pkgs.coreutils ];
    script = ''
      d=/var/lib/noctalia-greeter
      install -m 0640 -o greeter -g greeter ${greeterConfig} "$d/greeter.toml"
      [ -e "$d/sync.toml" ] || install -m 0640 -o greeter -g greeter ${greeterSeed} "$d/sync.toml"
    '';
  };

  environment.etc."wabisabi/wallpaper${wallpaperExt}".source = cfg.wallpaper;

  services.greetd = lib.mkIf cfg.greetd.enable {
    enable = lib.mkDefault true;
    # Only the text greeter wants the VT wiring; the graphical one brings its
    # own compositor.
    useTextGreeter = lib.mkDefault (cfg.greetd.greeter == "tuigreet");
    settings.default_session = {
      # NOTE: assign sub-options directly with per-leaf mkDefault — wrapping
      # the whole namespace in one mkDefault gets silently dropped by the
      # module system when it crosses into the TOML-typed `settings` option.
      #
      # niri-session (rather than plain niri) is what imports the session
      # environment into the systemd user manager and D-Bus. Skip it and
      # portals, screencasting and every user service break in confusing ways.
      #
      # It runs on the VT, so anything it prints lands on your screen between
      # the password prompt and the first frame of the desktop. Upstream's
      # script currently calls `systemctl --user import-environment` with no
      # argument list, which systemd warns about. systemd-cat sends that to
      # the journal instead of the console: still diagnosable with
      # `journalctl -t niri-session`, no longer visible mid-login.
      command = lib.mkDefault greeterCmd;
      user = lib.mkDefault "greeter";
    };
  };

  # Session-adjacent CLI tools. GUI apps (bar, launcher, terminal, ...)
  # are managed by the home layer so users can swap them per-account.
  #
  # niri has a built-in screenshot UI, but grim/slurp stay: they are what
  # other tools shell out to, and niri implements wlr-screencopy v3 so they
  # work unmodified.
  environment.systemPackages = (with pkgs; [
    grim            # screenshots
    slurp           # region picker
    wl-clipboard    # clipboard
    brightnessctl
    pamixer
    playerctl
    wf-recorder
  ])
  # The greeter, so `noctalia-greeter-print-greetd-config` and friends are
  # reachable for troubleshooting a login that will not come up.
  ++ lib.optional noctaliaGreeter greeterPackage;
}
