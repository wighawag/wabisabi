# The fleet's wabisabi laptop, shaped like my-boxes' nono in each respect the
# installer's restore has to handle differently from a repo it made itself:
#
#   - its disks are DECLARED (disko), so the restore must partition with that
#     declaration and not with the installer's own layouts;
#   - its secrets are encrypted to its SSH HOST KEY (plus an admin key), not
#     to an age key file, so nothing can be decrypted until that host key is
#     back -- which is what wabisabi.restore.files does;
#   - its password comes from its OWN sops secret, not wabisabi.secrets;
#   - it declares no /etc/nixos link, so the repo's place is asked for.
{ config, wabisabi, ... }:

{
  imports = [ wabisabi.inputs.disko.nixosModules.disko ];

  disko.devices.disk.main = {
    device = "/dev/vda";
    type = "disk";
    content = {
      type = "gpt";
      partitions = {
        ESP = {
          size = "512M";
          type = "EF00";
          content = {
            type = "filesystem";
            format = "vfat";
            mountpoint = "/boot";
            mountOptions = [ "umask=0077" ];
          };
        };
        root = {
          size = "100%";
          content = {
            type = "filesystem";
            format = "ext4";
            mountpoint = "/";
          };
        };
      };
    };
  };

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;
  boot.initrd.availableKernelModules = [ "virtio_pci" "virtio_blk" "ahci" "xhci_pci" "sd_mod" ];
  nixpkgs.hostPlatform = "x86_64-linux";
  networking.hostName = "laptop";
  system.stateVersion = "CHANGEME_STATE_VERSION";

  # The host key IS the sops identity.
  services.openssh.enable = true;
  sops.age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];

  sops.secrets."laptop/user-password" = {
    sopsFile = ../../secrets/laptop/user-password;
    format = "binary";
    neededForUsers = true;
  };
  users.users.tester = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    hashedPasswordFile = config.sops.secrets."laptop/user-password".path;
  };

  # What a restore must put back before the first boot: the host key, kept in
  # the repo encrypted to the admin key only (as my-boxes' birth.sh does).
  wabisabi.restore.files."/etc/ssh/ssh_host_ed25519_key" = {
    sopsFile = ../../secrets/laptop/ssh-host-key;
    mode = "0600";
  };

  wabisabi.enable = true;
  wabisabi.user = "tester";
  home-manager.users.tester = {
    imports = [ wabisabi.homeModules.wabisabi ];
    wabisabi.enable = true;
  };
}
