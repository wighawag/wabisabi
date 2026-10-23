{ lib, pkgs, config, ... }:

# Boot presentation. Nothing here changes what boots, only what you see while
# it does: straight from the firmware logo to a splash, and from the splash to
# the greeter, with no menu and no wall of unit status lines in between.
#
# The handoff needs no wiring from us: the nixpkgs greetd module aliases
# itself to display-manager.service and orders itself after
# plymouth-quit-wait.service, so the splash hands straight over to the
# greeter.

let
  cfg = config.wabisabi;

  artwork = pkgs.callPackage ../pkgs/wabisabi-artwork/package.nix { };

  plymouth = "${config.boot.plymouth.package}/bin/plymouth";
  handover = cfg.greetd.enable && cfg.greetd.greeter == "noctalia";

  # The splash follows the palette. wabisabi's own theme paints an enso as
  # the machine boots (pkgs/wabisabi-artwork, artwork/README.md);
  # catppuccin-plymouth defaults to the macchiato flavour, and the rest of the
  # Catppuccin theme is Mocha.
  splash = {
    sumi = {
      package = artwork;
      name = "wabisabi";
    };
    catppuccin-mocha = {
      package = pkgs.catppuccin-plymouth.override { variant = "mocha"; };
      name = "catppuccin-mocha";
    };
  }.${cfg.theme};
in
lib.mkIf (cfg.enable && cfg.splash.enable) {
  boot.plymouth = {
    enable = lib.mkDefault true;
    themePackages = lib.mkDefault [ splash.package ];
    theme = lib.mkDefault splash.name;
    # The one font in the initrd, used for the disk-unlock prompt and any
    # message. The theme's Font= names this family ("Inter Variable"), which
    # is also the website's text face.
    font = lib.mkDefault "${pkgs.inter}/share/fonts/truetype/InterVariable.ttf";
  };

  # No menu, unless asked for: systemd-boot's `timeout 0` boots the default
  # entry at once and still shows the menu while a key (Space) is held, so the
  # rollback to an older generation is one held key away rather than gone.
  # mkDefault, so a config that wants the menu on every boot just sets it.
  boot.loader.timeout = lib.mkIf (cfg.splash.hideBootMenu && config.boot.loader.systemd-boot.enable) (
    lib.mkDefault 0
  );

  # Quiet the console so the splash is not fighting kernel and unit output.
  #
  # Note what `quiet` does NOT hide: systemd password prompts (disk unlock),
  # the emergency shell, and fsck errors that need an answer. A boot that
  # actually fails is still visible and still interactive. Set
  # `wabisabi.splash.enable = false` if you would rather watch every unit.
  #
  # kernelParams is an additive list, so these are appended rather than
  # mkDefault'd: a user adding their own params keeps these too.
  boot.kernelParams = [
    "quiet"                          # kernel messages
    "splash"
    "loglevel=3"
    "systemd.show_status=false"      # the [ OK ] unit lines in stage 2
    "rd.systemd.show_status=false"   # ... and in the initrd
    "rd.udev.log_level=3"
    "udev.log_level=3"
  ];

  # The handover, done the way GDM does it, so the finished enso stays on
  # screen until the login screen replaces it.
  #
  # Stock NixOS runs `plymouth quit` and only then starts greetd (greetd is
  # ordered after plymouth-quit-wait). Quitting clears the display, and the
  # greeter's compositor takes a moment to draw, so the bare console showed
  # through in between: about a second on real hardware, six in a VM.
  #
  # Instead, both units only DEACTIVATE plymouth: it stops drawing and lets go
  # of the display, but the last frame stays up. The greeter's compositor then
  # takes the display and draws over it, and once its Wayland socket exists
  # the handover unit makes plymouth quit with --retain-splash (quitting any
  # other way would blank the screen again). If the greeter never comes up,
  # plymouth still quits after 20 s, so a broken greeter is not hidden
  # behind a splash forever.
  #
  # ONLY for the graphical greeter: tuigreet draws on the text console, which
  # a lingering splash would cover.
  systemd.services.plymouth-quit.serviceConfig.ExecStart = lib.mkIf handover [ "" "-${plymouth} deactivate" ];
  systemd.services.plymouth-quit-wait.serviceConfig.ExecStart = lib.mkIf handover [ "" "-${plymouth} deactivate" ];
  systemd.services.wabisabi-splash-handover = lib.mkIf handover {
    description = "Hand the boot splash over to the greeter";
    after = [ "greetd.service" ];
    wantedBy = [ "greetd.service" ];
    serviceConfig.Type = "oneshot";
    path = [ pkgs.coreutils ];
    script = ''
      # noctalia-greeter-session runs its compositor with this runtime dir.
      dir="/tmp/noctalia-runtime-$(id -u greeter)"
      for _ in $(seq 80); do
        if ls "$dir"/wayland-* > /dev/null 2>&1; then
          sleep 1   # the socket comes before the first frame
          break
        fi
        sleep 0.25
      done
      ${plymouth} quit --retain-splash || true
    '';
  };

  boot.initrd.verbose = lib.mkDefault false;
  boot.consoleLogLevel = lib.mkDefault 0;
}
