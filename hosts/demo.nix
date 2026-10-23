{ lib, pkgs, ... }:

# A demo machine — deliberately NOT real hardware. It exists so that
#   nix flake check                      → validates the whole layer evals
#   nixos-rebuild build-vm --flake .#demo → boots the desktop in QEMU
# and proves the module layers are hardware-agnostic.

{
  # Fake disk identity — only used when building the VM.
  fileSystems."/" = {
    device = "/dev/disk/by-label/nixos";
    fsType = "ext4";
  };
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # Early KMS, so Plymouth owns the display from the initrd instead of letting
  # stage-2 console text draw over the splash. The right module is a property
  # of the hardware, which is why it lives here in hosts/ rather than in
  # modules/: for this VM it is the QEMU GPU (virtio_gpu, plus bochs if you
  # run it with plain `-vga std`). On a real machine put your own driver here,
  # usually i915, amdgpu or nouveau. Most nixos-hardware profiles do it for you.
  boot.initrd.kernelModules = [ "virtio_gpu" "bochs" ];

  users.users.demo = {
    isNormalUser = true;
    extraGroups = [ "wheel" "networkmanager" "video" ];
    password = "demo";  # declarative (not initialPassword) — always works
  };

  # Debug aid: dump greetd + home-manager diagnostics to the serial console on boot.
  systemd.services.debug-greetd = {
    wantedBy = [ "multi-user.target" ];
    after = [ "greetd.service" ];
    serviceConfig.Type = "oneshot";
    script = ''
      sleep 15
      {
        echo "=== greetd state ==="
        systemctl is-active greetd || true
        echo "=== tuigreet processes ==="
        ${pkgs.procps}/bin/ps aux | grep -v grep | grep tuigreet || echo "NO TUIGREET RUNNING"
        echo "=== greetd journal ==="
        journalctl -u greetd --no-pager -n 15 || true
        echo "=== home-manager-demo status ==="
        systemctl status home-manager-demo.service -l --no-pager || true
        echo "=== home-manager-demo journal ==="
        journalctl -u home-manager-demo.service --no-pager -n 40 || true
      } > /dev/ttyS0 2>&1 || true
    '';
  };

  # Enable the system layer (the home layer is wired in flake.nix).
  wabisabi.enable = true;
  # The agent layer (pi, wherever, local model, search) is set up for this user.
  wabisabi.user = "demo";

  # Debug/testing access for the demo VM.
  virtualisation.vmVariant = {
    services.openssh.enable = true;
    virtualisation.forwardPorts = [{
      from = "host";
      host.port = 2222;
      guest.port = 22;
    }];

    # THE VM NEEDS A REAL GPU RENDER NODE.
    #
    # QEMU's default display is emulated VGA, which the guest drives with
    # bochs-drm. That gives /dev/dri/card0 but NO /dev/dri/renderD*, and niri
    # deliberately refuses software EGL (llvmpipe): see
    # niri/src/backend/tty.rs, "software EGL renderers are skipped". The
    # symptom is not a slow desktop, it is a BLACK SCREEN with niri running
    # happily in the background, Wayland socket and all.
    #
    # virtio-vga-gl gives the guest a virtio-gpu with VirGL, so it gets a
    # real renderD128 and niri renders normally.
    #
    # SDL rather than GTK: with `-display gtk,gl=on` on a GNOME/Wayland host,
    # QEMU shows the GL scanout but not the plain 2D console scanout, so the
    # window stays black through the whole boot and the tuigreet login screen
    # is invisible (you can log in blind, and the desktop then appears). SDL
    # displays both. Override with QEMU_OPTS if your host prefers GTK.
    virtualisation.qemu.options = [
      "-vga" "none"
      "-device" "virtio-vga-gl"
      "-display" "sdl,gl=on"
    ];
  };

  system.stateVersion = "26.05";
}