{ lib, pkgs, config, ... }:

# The curated app set. Every entry is open source and does not depend on a
# service you cannot self-host (or run fully locally). No vendor clouds,
# no proprietary blobs, no accounts required by default.

let cfg = config.wabisabi; in
lib.mkIf cfg.enable {
  programs.firefox = lib.mkIf (cfg.browser == "firefox") {
    enable = true;
    profiles.default.settings = {
      "toolkit.telemetry.enabled" = false;
      "datareporting.healthreport.uploadEnabled" = false;
      "browser.discovery.enabled" = false;
    };
  };

  home.packages =
    # Browsers not managed by a native HM module
    (lib.optionals (cfg.browser == "librewolf") [ pkgs.librewolf ])
    ++ (lib.optionals (cfg.browser == "chromium") [ pkgs.chromium ])
    # File manager
    ++ (lib.optionals (cfg.fileManager == "thunar") [
      pkgs.thunar
      pkgs.tumbler  # thumbnails
    ])
    ++ (lib.optionals (cfg.fileManager == "nautilus") [ pkgs.nautilus ])
    # yazi is a TUI file manager: no window of its own, no portal. See the
    # option's description for why that costs no file chooser.
    ++ (lib.optionals (cfg.fileManager == "yazi") [ pkgs.yazi ])
    # Optional app groups
    ++ (lib.optionals cfg.apps.media [ pkgs.mpv pkgs.imv ])
    ++ (lib.optionals cfg.apps.office [ pkgs.libreoffice ])
    ++ (lib.optionals cfg.apps.email [ pkgs.thunderbird ])
    ++ (lib.optionals cfg.apps.passwords [ pkgs.keepassxc ])
    ++ (lib.optionals cfg.apps.reading [ pkgs.papers pkgs.foliate ])
    ++ (lib.optionals cfg.apps.creative [ pkgs.gimp pkgs.inkscape pkgs.obs-studio ])
    ++ (lib.optionals cfg.apps.torrent [ pkgs.qbittorrent ]);

  # Syncthing: peer-to-peer, self-hostable by construction.
  services.syncthing = lib.mkIf cfg.apps.syncthing {
    enable = true;
  };
}