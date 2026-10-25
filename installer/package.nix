# The installer as a package: two entry points and the data they need.
#
#   wabisabi-install  the TUI (and the unattended --answers path)
#   wabisabi-emit     the template renderer, on its own, so the emit step can
#                     be run and diffed without a disk anywhere near it
#
# Everything variable is baked in here rather than looked up at runtime: the
# questions, the template, the pinned flake.lock and the release this medium
# installs. An installer that resolved those at runtime would be an installer
# whose output depends on the day it is run.

{
  lib,
  symlinkJoin,
  writeShellApplication,
  age,
  bash,
  ckbcomp,
  coreutils,
  cryptsetup,
  diffutils,
  disko,
  dosfstools,
  e2fsprogs,
  gawk,
  git,
  gnugrep,
  gnused,
  gptfdisk,
  gum,
  jq,
  kbd,
  mkpasswd,
  nix,
  nixos-install-tools,
  openssh,
  python3,
  sops,
  util-linux,

  questions,
  template,
  targetLock,
  secretsTool,
  usbTool,
  stateVersion,
  nixpkgsSource,
  offline ? false,
}:

let
  emit = writeShellApplication {
    name = "wabisabi-emit";
    runtimeInputs = [
      bash
      coreutils
      gawk
      gnugrep
      gnused
      jq
      python3
      (lib.getBin util-linux)
    ];
    # Absolute, not `exec bash`: a systemd unit inherits no useful PATH, and
    # resolving the interpreter from one is how this failed the first time --
    # exit 127, eight milliseconds in, with nothing to show for it.
    text = ''
      exec ${lib.getExe bash} ${./emit.sh} "$@"
    '';
  };

  install = writeShellApplication {
    name = "wabisabi-install";
    runtimeInputs = [
      age
      bash
      ckbcomp
      coreutils
      cryptsetup
      diffutils
      disko
      dosfstools
      e2fsprogs
      gawk
      git
      gnugrep
      gnused
      gptfdisk
      gum
      jq
      kbd
      mkpasswd
      nix
      nixos-install-tools
      # ssh for a restore from a private repo or git+ssh flake inputs
      openssh
      python3
      secretsTool
      sops
      util-linux
    ];
    text = ''
      export WABISABI_QUESTIONS=${questions}
      export WABISABI_APPLIES=${./applies.jq}
      export WABISABI_TEMPLATE=${template}
      export WABISABI_EMIT=${./emit.sh}
      export WABISABI_LOCK=${targetLock}/flake.lock
      export WABISABI_URL=${targetLock.url}
      export WABISABI_DISKO=${./disko}
      export WABISABI_DISKS_LIB=${./disks.sh}
      # disko evaluates its own config at runtime with `import <nixpkgs>`, and
      # a systemd unit inherits no NIX_PATH at all, so the sources travel with
      # the installer instead of being looked up in the environment.
      export WABISABI_NIXPKGS=${nixpkgsSource}
      export WABISABI_STATE_VERSION=${stateVersion}
      export WABISABI_OFFLINE=${if offline then "1" else "0"}
      exec ${lib.getExe bash} ${./install.sh} "$@"
    '';
  };
in

symlinkJoin {
  name = "wabisabi-installer";
  paths = [
    install
    emit
    # On the medium's PATH too, for `wabisabi-secrets keygen` by hand.
    secretsTool
    # And the stick tool, to make another stick (or a kit) from a live session.
    usbTool
  ];
  meta = {
    description = "Interactive installer for a wabisabi machine";
    mainProgram = "wabisabi-install";
  };
}
