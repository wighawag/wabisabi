{ lib, config, pkgs, ... }:

let cfg = config.wabisabi; in
{
  imports = [ ./options.nix ./core.nix ./boot.nix ./desktop.nix ./network.nix ./agents.nix ./secrets.nix ./tools.nix ];

  config = lib.mkIf cfg.enable {
    # ─── The libre rule, enforced at build time ───
    assertions = lib.optional cfg.enforceLibre {
      assertion = !(config.nixpkgs.config.allowUnfree or false);
      message = ''
        wabisabi: nixpkgs.config.allowUnfree = true, which violates the
        libre-only rule of this setup. Either keep allowUnfree = false, or
        explicitly opt out by setting wabisabi.enforceLibre = false.
      '';
    };
  };
}