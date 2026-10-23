# The installer ISO, in two variants.
#
# Variants:
#   netinstall  small (~1.5G), TEXT ONLY. Evaluates from the sources on the
#               medium, fetches packages from cache.nixos.org. Needs a network.
#   offline     large (~9G), and LIVE: it boots into the wabisabi desktop so it
#               can be tried before installing, and it carries the package
#               closures too, so a machine with no network at all still gets
#               the same system. Its boot menu also has a text-only entry that
#               is exactly the old installer.
#
# THE LIVE DESKTOP HAS TO FAIL LEGIBLY, which is why the netinstall medium
# stayed text-only for so long. niri refuses to run on a software EGL renderer,
# so on a machine with no GPU render node (QEMU without virtio-vga-gl, an
# unsupported GPU) a naive live desktop is a black screen with niri running
# perfectly behind it. The live session therefore checks for a render node
# first and, without one, lands in a text shell that says why and how to
# install, instead of starting the compositor. See `liveSession` below.
#
# Both carry the wabisabi source and the pinned lock, so the ISO installs the
# exact revision it was built from rather than whatever is on the internet
# today.

{
  config,
  lib,
  pkgs,
  modulesPath,
  installer,
  nixpkgsSource,
  # Every flake source the generated config refers to, wabisabi's own
  # included. Without these the medium carries a lock that names store paths
  # it does not have, and the install dies at the last step asking to change
  # the lock file -- which is exactly what a pinned install must not do.
  sources,
  wabisabiRev,
  offline ? false,
  # The live desktop (the offline medium). Needs the wabisabi modules, which
  # the flake passes in as `wabisabiModules`.
  live ? false,
  wabisabiModules ? null,
  payloads ? [ ],
  # Unattended install, for the end-to-end VM test. Never set on media meant
  # for a person: it partitions the disk named in the answers file without
  # asking, which is precisely what you do not want a stray USB stick doing.
  autotest ? null,
  ...
}:

{
  imports = [
    (modulesPath + "/installer/cd-dvd/installation-cd-minimal.nix")
  ]
  ++ lib.optionals live [
    wabisabiModules.system
    wabisabiModules.homeManager
    ./live.nix
  ];

  # `image.baseName`, not `isoImage.isoName`: the latter still evaluates but is
  # renamed, and setting it produces a deprecation warning plus a filename that
  # comes from somewhere else entirely.
  # The autotest image must be impossible to mistake for real media, by name
  # and by volume label. It installs unattended with no confirmation, so a
  # file called wabisabi-netinstall.iso that silently partitions whatever the
  # baked answers name is a grenade sitting in a downloads directory.
  image.baseName = lib.mkForce (
    "wabisabi-${if offline then "offline" else "netinstall"}"
    + lib.optionalString (autotest != null) "-AUTOTEST-DESTROYS-DISKS"
  );

  isoImage = {
    # The UEFI boot menu, drawn like the website's first screen: the enso
    # wallpaper, darkened on the left, and the menu set in the dark half.
    # (Legacy BIOS boots keep syslinux's plain menu: the installer needs UEFI
    # anyway.)
    grubTheme = pkgs.callPackage ../pkgs/wabisabi-grub-theme/package.nix {
      wabisabi-artwork = pkgs.callPackage ../pkgs/wabisabi-artwork/package.nix { };
    };

    volumeID = lib.mkForce (if autotest != null then "WABISABI_TEST" else "WABISABI");
    # The offline image is mostly nix store, which is exactly what zstd is
    # good at; the default is already zstd but at a level tuned for a small
    # image, and this one is not small either way.
    squashfsCompression = "zstd -Xcompression-level 15";

    # What makes an offline install possible: the closures of representative
    # systems, so the target can be built without reaching for a substituter.
    storeContents = payloads;
  };

  # The installer needs to EVALUATE wabisabi on the target, not just copy
  # store paths, so the flake sources ride along in both variants.
  system.extraDependencies =
    sources
    ++ lib.optionals offline (
      with pkgs;
      [
        # BUILD-TIME dependencies, which are a different set from the runtime
        # closures in storeContents and are the reason a first attempt at an
        # offline install failed while looking fully stocked.
        #
        # Some derivations can never be prebuilt into the image, however many
        # payloads it carries: `system-path` changes with the chosen packages,
        # and the shrunk kernel-module set changes with whatever
        # nixos-generate-config finds on the actual machine. Those get built on
        # the target, and their builders have to be here.
        #
        # This list is nixpkgs' own, from nixos/tests/installer.nix, which
        # solves exactly this problem for exactly this reason. Deriving it by
        # hand means discovering it one failed 40-minute VM run at a time.
        stdenv
        stdenvNoCC

        bintools
        brotli
        brotli.dev
        brotli.lib
        desktop-file-utils
        docbook5
        docbook_xsl_ns
        kbd.dev
        kmod.dev
        libarchive.dev
        libcap-text-verifier
        libxml2.bin
        libxslt.bin
        lndir
        nixos-rebuild-ng
        perlPackages.ConfigIniFiles
        perlPackages.FileSlurp
        perlPackages.JSON
        perlPackages.ListCompare
        perlPackages.XMLLibXML
        (python3.withPackages (p: [ p.mistune ]))
        shared-mime-info
        shellcheck-minimal
        sudo
        switch-to-configuration-ng
        texinfo
        unionfs-fuse

        # Only the out output, which is what building the NixOS udev rules
        # needs; see the comment in nixos/modules/services/hardware/udev.nix.
        systemdMinimal.out

        # Found by running an offline install and reading what it could not
        # build, rather than by reasoning: mtools is pulled in by the
        # systemd-boot installer derivation, and the other two turned up
        # underneath it.
        #
        # `.all`, NOT the bare package. Adding `mtools` ships only its default
        # output, and nix then still has to build the derivation to get the
        # other ones -- which offline means failing, while `nix path-info`
        # cheerfully shows the package "present". That is why the list above
        # spells out brotli.dev, kmod.dev, libxml2.bin and friends.
      ]
      ++ mtools.all
      ++ tzdata.all
      ++ python3Packages.mypy.all
      ++ [
        # (kept separate so the nixpkgs-derived list above stays comparable
        # with its upstream source)
        hello
      ]
    );

  environment.systemPackages = [
    installer
    pkgs.gum
    pkgs.jq
    pkgs.git
  ];

  # disko evaluates its own configuration at runtime with `import <nixpkgs>`,
  # so NIX_PATH has to point at the sources on the medium. Without this the
  # partitioning step is the first thing to fail, and only on the offline
  # image, which is the worst possible place to discover it.
  nix.nixPath = [ "nixpkgs=${nixpkgsSource}" ];
  nix.settings = {
    experimental-features = [
      "nix-command"
      "flakes"
    ];
    # An offline medium that silently waits on a dead network looks like a
    # hang. Fail fast instead.
    connect-timeout = lib.mkIf offline 5;
  };

  # NetworkManager: `nmtui` is a text wifi picker that a person can actually
  # use, and it is the same stack the installed machine will run.
  #
  # DO NOT TOUCH `networking.wireless.enable` HERE. NetworkManager's own module
  # sets it to true: that is how its wpa_supplicant (D-Bus controlled, no
  # interfaces of its own) gets installed at all. This file used to force it
  # false, to turn off the minimal ISO's standalone wpa_supplicant, and so
  # removed the one NetworkManager needs. Both media then had a wifi card,
  # up, with firmware loaded, and no networks ever in range: NetworkManager
  # logged "Failed to D-Bus activate wpa_supplicant service" every 13 seconds
  # (seen on a ThinkPad T14s, ath11k). The installer profile no longer enables
  # a standalone one, so there is nothing to turn off.
  networking.networkmanager.enable = true;

  # Firmware, so that wifi exists on the medium that needs to reach the
  # network. See the note on the libre rule in README: these licences are
  # marked free in nixpkgs and do not trip `enforceLibre`, which is a fact
  # worth knowing rather than a loophole to lean on.
  hardware.enableRedistributableFirmware = true;

  # The layout question applies to the installer's own keyboard too: someone
  # typing a LUKS passphrase into the installer should be typing it on the
  # same layout that the initrd will present at the next boot. The installer
  # calls `loadkeys` itself once the answer is known.
  console.keyMap = lib.mkDefault "us";

  services.getty.helpLine = lib.mkForce ''

        wabisabi installer

        Run:  sudo wabisabi-install
        Wifi: sudo nmtui
        Docs: https://github.com/wighawag/wabisabi

        This medium installs wabisabi ${lib.substring 0 12 wabisabiRev}${lib.optionalString offline ", with no network required"}.
  '';

  # Never silently unfree, even on the installer.
  nixpkgs.config.allowUnfree = false;

  # ── the unattended path, used only by scripts/test-install-vm.sh ──
  systemd.services.wabisabi-autotest = lib.mkIf (autotest != null) {
    description = "Unattended wabisabi install (VM test)";
    wantedBy = [ "multi-user.target" ];
    after = [
      "network-online.target"
      "nix-daemon.service"
    ];
    wants = [ "network-online.target" ];
    serviceConfig = {
      Type = "oneshot";
      StandardOutput = "journal+console";
      StandardError = "journal+console";
    };
    script = ''
      # Refuse on bare metal. The answers name /dev/vda, which on most
      # physical machines simply does not exist -- but "it probably will not
      # match" is luck, not a control, and this runs before any prompt.
      if ! ${lib.getExe' pkgs.systemd "systemd-detect-virt"} --quiet; then
        echo "WABISABI_AUTOTEST_REFUSED: not running in a VM"
        exit 0
      fi

      echo "WABISABI_AUTOTEST_START"
      rc=0
      ${lib.getExe' installer "wabisabi-install"} --answers ${autotest} --yes --no-reboot || rc=$?
      if [ $rc -eq 0 ]; then
        echo "WABISABI_AUTOTEST_DONE"
      else
        echo "WABISABI_AUTOTEST_FAILED rc=$rc"
        # Without this, a failure is a VM that powered off nine seconds in and
        # told you nothing at all.
        echo "=== journal ==='"
        ${lib.getExe' pkgs.systemd "journalctl"} --no-pager -b -n 200 || true
      fi
      # The harness watches for the sentinel and then for the power-off.
      ${lib.getExe' pkgs.systemd "systemctl"} poweroff
    '';
  };

  # The test harness reads the install log from the serial port. ORDER MATTERS:
  # /dev/console is the LAST console on the command line, and that is where
  # systemd sends unit output, so the serial port has to come last or the whole
  # install log goes to a VGA console nobody is reading.
  boot.kernelParams = lib.mkIf (autotest != null) [
    "console=tty0"
    "console=ttyS0,115200"
  ];

  system.stateVersion = config.system.nixos.release;
}
