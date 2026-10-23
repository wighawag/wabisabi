# The systems whose closures ride on the offline ISO.
#
# "Offline" has to mean "any answer you can give the installer can be built
# without a network", not "the defaults work and anything else fails halfway
# through". So the payloads are derived from the same question data the
# installer asks from: every value of every enum appears in at least one
# payload, and every optional app is switched on. Add a browser to the enum
# and this grows a payload to cover it, with nothing to remember.
#
# Bools are only ever switched ON here: a false adds no packages, so there is
# nothing for it to carry.

{
  lib,
  nixosSystem,
  homeManagerModule,
  self,
  system,
  stateVersion,
  questions,
}:

let
  items = lib.concatMap (g: g.items) questions.groups;

  # Only wabisabi's own options: the others (firmware, initrd modules) are
  # target-hardware facts, not package choices.
  relevant = lib.filter (
    i: i.emit != null && lib.hasPrefix "wabisabi." i.emit.attr && i.key != "system:enable"
  ) items;

  enums = lib.filter (i: i.kind == "enum") relevant;
  bools = lib.filter (i: i.kind == "bool") relevant;

  # As many payloads as the widest enum has values.
  count = lib.foldl' (acc: i: lib.max acc (lib.length i.values)) 1 enums;

  pathOf = item: lib.drop 1 (lib.splitString "." item.emit.attr);

  settingsFor =
    block: index:
    let
      forBlock = lib.filter (i: i.emit.block == block);
      enumSettings = map (
        i: lib.setAttrByPath (pathOf i) (lib.elemAt i.values (lib.mod index (lib.length i.values)))
      ) (forBlock enums);
      boolSettings = map (i: lib.setAttrByPath (pathOf i) true) (forBlock bools);
    in
    lib.foldl' lib.recursiveUpdate { enable = true; } (enumSettings ++ boolSettings);

  payload =
    index:
    (nixosSystem {
      inherit system;
      specialArgs = {
        wabisabi = self;
      };
      modules = [
        self.nixosModules.wabisabi
        homeManagerModule
        (
          { ... }:
          {
            # A plausible stand-in for a real machine: the closure is what
            # matters, and none of this reaches the installed system.
            fileSystems."/" = {
              device = "/dev/disk/by-label/nixos";
              fsType = "ext4";
            };

            # THESE MUST MATCH template/configuration.nix EXACTLY. The
            # systemd-boot installer is a generated Python script that embeds
            # its settings, so a payload that differs by one bootloader option
            # produces a different derivation, and the target then has to
            # BUILD that script -- which needs python, mypy and mtools, none
            # of which a runtime closure carries. The symptom is an offline
            # install dying at "Cannot build install-systemd-boot.sh" with the
            # entire desktop already present on the medium.
            boot.loader.systemd-boot.enable = true;
            boot.loader.efi.canTouchEfiVariables = true;
            networking.hostName = "payload";
            users.users.payload = {
              isNormalUser = true;
              extraGroups = [ "wheel" ];
            };
            system.stateVersion = stateVersion;

            # AN OWNER, as every installed machine has one (the template sets
            # wabisabi.user to the created account). It is a string option, so
            # nothing above enumerates it; without it no payload carried the
            # owner's pi, wherever or memonaut, and an offline target had to
            # build them, and their toolchains, from source.
            wabisabi = settingsFor "system" index // {
              user = "payload";
              # SECRETS, as the installer's recommended path sets them up.
              # sops-install-secrets is built by sops-nix against our nixpkgs
              # and no public cache carries it, so without a payload that
              # uses secrets an offline target would have to compile it, Go
              # toolchain and all. The file here is a stand-in (validation is
              # off): what matters is the closure, which is the same for any
              # file. The target still validates its REAL file when it builds
              # its own manifest, with this same sops-install-secrets.
              secrets.sopsFile = builtins.toFile "payload-secrets.yaml" "";
            };
            sops.validateSopsFiles = false;

            home-manager.users.payload = {
              imports = [ self.homeModules.wabisabi ];
              wabisabi = settingsFor "home" index;
            };
          }
        )
      ];
    }).config.system.build.toplevel;

  toplevels = map payload (lib.range 0 (count - 1));

  # What the payloads actually cover, so the claim can be checked rather than
  # asserted in a comment.
  coverage = lib.listToAttrs (
    map (i: lib.nameValuePair i.key i.values) enums
  );
in

{
  inherit toplevels count coverage;
}
