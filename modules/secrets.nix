{ lib, pkgs, config, ... }:

# The owner's secrets, sops-encrypted in their own flake and decrypted by
# sops-nix on activation. The sops-nix module itself is imported by
# `nixosModules.wabisabi` in flake.nix, so the generated flake needs no input
# of its own for it and the installed machine's lock pins it like the rest.
#
# THE MODEL: one age key per machine flake, held in two places. The machine
# has it at `secrets.ageKeyFile` (root-only) to decrypt at activation; the
# owner has a copy in ~/.config/sops/age/keys.txt to edit with `sops`, and a
# backup somewhere that is not this machine. A reinstall is then "the flake +
# that key": nothing to re-encrypt, no second key to enrol.
#
# Only VALUES can be secret. sops-nix decrypts on the machine, after Nix has
# evaluated the config, so anything evaluation needs (the username, the
# hostname, which services run) is necessarily in the clear.

let
  cfg = config.wabisabi;
  on = cfg.enable && cfg.secrets.sopsFile != null;
  ownerPassword = on && cfg.secrets.ownerPassword && cfg.user != "";
in
lib.mkIf cfg.enable (lib.mkMerge [
  {
    # The tooling is there whether or not secrets are set up yet, because
    # `wabisabi-secrets init` is how a machine installed without them gets
    # them later.
    environment.systemPackages = [
      (pkgs.callPackage ../pkgs/wabisabi-secrets/package.nix { })
      pkgs.sops
      pkgs.age
    ];
  }

  (lib.mkIf on {
    sops.defaultSopsFile = cfg.secrets.sopsFile;
    sops.age.keyFile = lib.mkDefault cfg.secrets.ageKeyFile;
    # Only the age key. sops-nix otherwise also tries every ssh host key as a
    # decryption key, which here would only ever be a second, unenrolled
    # identity and a source of warnings.
    sops.age.sshKeyPaths = lib.mkDefault [ ];
    sops.gnupg.sshKeyPaths = lib.mkDefault [ ];
  })

  (lib.mkIf ownerPassword {
    # neededForUsers: decrypted before the users are created, into
    # /run/secrets-for-users, which is what hashedPasswordFile can read.
    sops.secrets.owner-password.neededForUsers = true;
    users.users.${cfg.user}.hashedPasswordFile = lib.mkDefault config.sops.secrets.owner-password.path;
  })

  {
    assertions = [
      {
        assertion = !(on && cfg.secrets.ownerPassword) || cfg.user != "";
        message = "wabisabi.secrets.ownerPassword needs wabisabi.user, to know whose password it is. Set wabisabi.user, or wabisabi.secrets.ownerPassword = false.";
      }
    ];
  }
])
