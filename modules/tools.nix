{ lib, pkgs, config, ... }:

# Tools beyond the desktop baseline, each behind one option (modules/options.nix):
# scanning, Flatpak, a developer's toolbox and virtual machines. GUI apps the
# owner picks per account (reading, creative, torrent) are in home/apps.nix;
# what is here needs the system: a service, a group, a capability.

let
  cfg = config.wabisabi;
  owner = cfg.user;
  ownerGroups = groups: lib.mkIf (owner != "") { users.users.${owner}.extraGroups = groups; };
in
lib.mkIf cfg.enable (lib.mkMerge [

  # ─── Scanning: driverless, like printing ───
  (lib.mkIf cfg.scanning.enable (lib.mkMerge [
    {
      hardware.sane = {
        enable = lib.mkDefault true;
        # eSCL (AirScan) and WSD: what every network scanner of the last
        # decade speaks. A list, so it merges with anything a machine adds.
        extraBackends = [ pkgs.sane-airscan ];
      };
      environment.systemPackages = with pkgs; [ simple-scan xsane ];
    }
    (ownerGroups [ "scanner" "lp" ])
  ]))

  # ─── Flatpak, Flathub and Flatseal ───
  (lib.mkIf cfg.flatpak.enable {
    services.flatpak.enable = lib.mkDefault true;

    # Adding a remote and installing from it are imperative by nature (Flatpak
    # keeps its own state in /var/lib/flatpak), so this is a oneshot that is
    # idempotent rather than a declaration. Flatseal is not in nixpkgs, which
    # is why it comes from Flathub at all. Offline at boot is not a failure
    # worth a red unit: the next boot tries again.
    systemd.services.wabisabi-flathub = {
      description = "Add the Flathub remote and install Flatseal";
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];
      path = [ config.services.flatpak.package ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        flatpak remote-add --system --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo || exit 0
        flatpak install --system --noninteractive --or-update flathub com.github.tchx84.Flatseal || exit 0
      '';
    };
  })

  # ─── A developer's toolbox ───
  (lib.mkIf cfg.dev.enable (lib.mkMerge [
    {
      environment.systemPackages = with pkgs; [
        nodejs
        pnpm
        uv
        cmake
        ninja
        # Low priority: where gcc is also installed, `cc`/`c++` stay gcc's.
        (lib.lowPrio clang)
        mold
        ccache
        nasm
        bison
        gperf
        sops
        wireguard-tools
        imagemagick
        ffmpeg
        yt-dlp
        zed-editor
      ];

      # tshark, with dumpcap allowed to capture for the `wireshark` group
      # (the CLI build: the GUI is a different, much larger package).
      programs.wireshark = {
        enable = lib.mkDefault true;
        package = lib.mkDefault pkgs.wireshark-cli;
      };
    }
    (ownerGroups [ "wireshark" ])
  ]))

  # ─── Virtual machines ───
  (lib.mkIf cfg.virtualisation.enable (lib.mkMerge [
    {
      virtualisation.libvirtd = {
        enable = lib.mkDefault true;
        qemu.package = lib.mkDefault pkgs.qemu_kvm;
      };
      programs.virt-manager.enable = lib.mkDefault true;
    }
    (ownerGroups [ "libvirtd" ])
  ]))
])
