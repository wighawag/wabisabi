# A TEST FIXTURE: a two-host fleet repo in the shape of my-boxes, for the
# installer's restore VM test (`./scripts/test-install-vm.sh --restore-fleet`).
# flake.nix in `restoreFleetFixture` fills in WABISABI_URL and adds the lock,
# the host key and the encrypted secrets, so none of that is committed here.
#
# The inputs are the template's exactly, because the lock it is given is the
# one the installer ships (installer/lock.nix), and a lock whose graph does
# not match its flake is one nix rejects.
{
  description = "A two-host fleet: the wabisabi restore-fleet test fixture";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    wabisabi = {
      url = "WABISABI_URL";
      # Point wabisabi at YOUR pins rather than its own. The module layers are
      # plain modules -- `pkgs` comes from the nixosSystem that imports them --
      # so this is what makes them evaluate against the nixpkgs above.
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.home-manager.follows = "home-manager";
      inputs.nixos-hardware.follows = "nixos-hardware";
    };
    nixos-hardware = {
      url = "github:NixOS/nixos-hardware";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { nixpkgs, home-manager, wabisabi, ... }: {
    # The wabisabi desktop: one host among several, as nono is in my-boxes.
    nixosConfigurations.laptop = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      specialArgs = { inherit wabisabi; };
      modules = [
        wabisabi.nixosModules.wabisabi
        home-manager.nixosModules.home-manager
        ./hosts/laptop
      ];
    };

    # Another host that has nothing to do with wabisabi. A restore has to
    # ask which machine it is restoring rather than assume the only one.
    nixosConfigurations.server = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [ ./hosts/server.nix ];
    };
  };
}
