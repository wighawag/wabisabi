# Whole-disk layout with an encrypted root: GPT, an unencrypted EFI system
# partition, and everything else inside LUKS2, unlocked by passphrase in the
# initrd at every boot.
#
# What is NOT encrypted, stated plainly: the ESP, which holds the kernel and
# the initrd. That is unavoidable without Secure Boot and measured boot, and
# it means this protects a powered-off machine against someone reading the
# disk, not against someone who can modify the boot partition and hand it back
# to you.
#
# The passphrase is typed on the keyboard layout chosen during installation,
# because wabisabi.keyboard.layout feeds console.useXkbConfig and so reaches
# the initrd. That is the single most important reason the layout is an option
# rather than something set after first boot.
#
# USED AT INSTALL TIME ONLY: nixos-generate-config detects the LUKS device and
# writes the boot.initrd.luks.devices entry into hardware-configuration.nix,
# so the installed system unlocks without disko being present.

{
  device ? throw "pass the target disk: disko --argstr device /dev/sdX",
  passphraseFile ? "/tmp/wabisabi-luks.key",
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
            mountOptions = [ "umask=0077" ];
          };
        };
        luks = {
          size = "100%";
          content = {
            type = "luks";
            name = "cryptroot";
            # Read once, at format time. The installed system prompts instead.
            passwordFile = passphraseFile;
            settings = {
              # Pass TRIM through to the SSD. The trade-off is real and small:
              # it lets an attacker with repeated disk access see which blocks
              # are unused. The alternative is an SSD that cannot garbage
              # collect, which ages the drive and slows it down.
              allowDiscards = true;
            };
            content = {
              type = "filesystem";
              format = "ext4";
              mountpoint = "/";
            };
          };
        };
      };
    };
  };
}
