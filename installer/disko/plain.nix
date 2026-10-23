# Whole-disk layout: GPT, an EFI system partition, ext4 root. No swap
# partition, because wabisabi.zram.enable is on by default and compressed RAM
# swap needs no disk layout. Hibernation does need a real swap area, and that
# is the reason the installer also offers the manual path.
#
# USED AT INSTALL TIME ONLY. The installed system does not import disko or
# depend on it: once this has partitioned and mounted the disk,
# nixos-generate-config writes the real UUIDs into hardware-configuration.nix
# and the machine is an ordinary NixOS machine that knows nothing about how it
# was partitioned.

{
  device ? throw "pass the target disk: disko --argstr device /dev/sdX",
  ...
}:

{
  disko.devices.disk.main = {
    inherit device;
    type = "disk";
    content = {
      type = "gpt";
      partitions = {
        ESP = {
          priority = 1;
          name = "ESP";
          start = "1M";
          end = "512M";
          type = "EF00";
          content = {
            type = "filesystem";
            format = "vfat";
            mountpoint = "/boot";
            # The ESP holds the kernels and initrds. umask keeps it readable
            # by root only, which stops systemd-boot warning about it.
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
}
