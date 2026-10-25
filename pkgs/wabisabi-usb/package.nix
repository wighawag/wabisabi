# wabisabi-usb: write the installer to a USB stick, with a partition after it
# for an encrypted restore kit. See wabisabi-usb.sh.
#
# Everything it runs is pinned here, so it behaves the same on any Linux with
# nix (`nix run github:wighawag/wabisabi#usb`) and on the installer medium.
{
  lib,
  writeShellApplication,
  age,
  bash,
  coreutils,
  cryptsetup,
  curl,
  diffutils,
  e2fsprogs,
  git,
  gnugrep,
  gnused,
  gum,
  hostname,
  jq,
  openssh,
  systemd,
  util-linux,
}:

writeShellApplication {
  name = "wabisabi-usb";
  runtimeInputs = [
    age
    bash
    coreutils
    cryptsetup
    curl
    diffutils
    e2fsprogs
    git
    gnugrep
    gnused
    gum
    hostname
    jq
    openssh
    # udevadm settle, after the partition table changes
    systemd
    util-linux
  ];
  text = ''
    export WABISABI_DISKS_LIB=${../../installer/disks.sh}
    exec ${lib.getExe bash} ${./wabisabi-usb.sh} "$@"
  '';
  meta.description = "Write the wabisabi installer to a USB stick, with an encrypted restore kit";
}
