# wabisabi-secrets: sops for the owner's config repo. Used by the installer
# (on the ISO) and by the owner afterwards (on the installed machine), so it
# is one package called from both places rather than two scripts.

{
  lib,
  writeShellApplication,
  bash,
  age,
  coreutils,
  git,
  gnugrep,
  gnused,
  gum,
  jq,
  mkpasswd,
  qrencode,
  shadow,
  sops,
  getent,
  hostname,
}:

writeShellApplication {
  name = "wabisabi-secrets";
  runtimeInputs = [
    age
    coreutils
    git
    gnugrep
    gnused
    gum
    jq
    mkpasswd
    qrencode
    shadow
    sops
    getent
    hostname
  ];
  # Absolute interpreter: this also runs from a systemd unit on the autotest
  # ISO, which inherits no useful PATH.
  text = ''
    exec ${lib.getExe bash} ${./wabisabi-secrets.sh} "$@"
  '';
  meta.description = "Set up and use sops-encrypted secrets in a wabisabi machine's flake";
}
