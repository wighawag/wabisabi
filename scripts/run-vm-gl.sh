#!/usr/bin/env bash
# Run the demo VM using the HOST's qemu, for non-NixOS hosts.
#
# Why this exists:
#   The VM asks for `-device virtio-vga-gl` (see hosts/demo.nix). That is not
#   optional eye candy: niri refuses to run on a software EGL renderer, so
#   without a real GPU render node in the guest you get a black screen.
#
#   The qemu from nixpkgs *does* support virtio-vga-gl. What it cannot do on a
#   non-NixOS host is load that host's GL drivers: it looks for them under
#   /run/opengl-driver/lib/gbm, a path that only exists on NixOS, and dies with
#     MESA-LOADER: failed to open dri: /run/opengl-driver/lib/gbm/dri_gbm.so
#     qemu-system-x86_64: egl: render node init failed
#   The host's own qemu finds the host's Mesa in the usual places and works.
#
#   So: on NixOS, run ./result/bin/run-nixos-vm. Everywhere else, run this.
#
# Why the disk image is recreated every run:
#   In a NixOS build-vm the guest's /nix/store is an overlay whose upper layer
#   is a *tmpfs*, while /home and /nix/var live on the qcow2 and persist. So on
#   a second boot of the same image, the Nix database and the home-manager
#   profile still point at store paths that were wiped with the tmpfs, and
#   activation fails with
#     error: opening file '/nix/store/...-user-environment.drv': No such file
#     [FAILED] Failed to start Home Manager environment for demo
#   Reusing a demo image is therefore not supported. It is a demo: state is
#   meant to be disposable. Pass --keep if you want to reuse one anyway and
#   accept that activation will fail.
#
# Usage:
#   ./scripts/run-vm-gl.sh [--keep] [path/to/run-nixos-vm]
set -euo pipefail

KEEP=0
RUNNER=""
for arg in "$@"; do
  case "$arg" in
    --keep) KEEP=1 ;;
    *) RUNNER="$arg" ;;
  esac
done

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(dirname "$SCRIPT_DIR")

if [ -z "$RUNNER" ]; then
  if [ -x "$REPO/result/bin/run-nixos-vm" ]; then
    RUNNER="$REPO/result/bin/run-nixos-vm"
  else
    echo "==> building the demo VM"
    RUNNER=$(nix build --print-out-paths --no-link \
      "$REPO#nixosConfigurations.demo.config.system.build.vm")/bin/run-nixos-vm || {
      echo "error: couldn't build the VM." >&2; exit 1; }
  fi
fi

HOSTQEMU=$(command -v qemu-system-x86_64 || true)
if [ -z "$HOSTQEMU" ]; then
  echo "error: no qemu-system-x86_64 on PATH; install it (e.g. apt install qemu-system-x86)." >&2
  exit 1
fi
if ! "$HOSTQEMU" -device help 2>/dev/null | grep -q 'virtio-vga-gl'; then
  echo "error: $HOSTQEMU lacks virtio-vga-gl (VirGL). niri cannot run without a GPU render node." >&2
  echo "       On Debian/Ubuntu: apt install qemu-system-modules-opengl" >&2
  exit 1
fi

# Keep the disk image somewhere explicit, rather than whatever the current
# directory happens to be, and OUTSIDE the checkout: anything under the repo
# is copied into /nix/store whenever the tree is evaluated as a `path:` flake
# (which ignores .gitignore). See scripts/test-install-vm.sh.
VM_ROOT=${WABISABI_VM_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/wabisabi/vm}
mkdir -p "$VM_ROOT"
export NIX_DISK_IMAGE="$VM_ROOT/demo.qcow2"

if [ "$KEEP" -eq 1 ]; then
  echo "==> reusing $NIX_DISK_IMAGE (--keep; home-manager activation will likely fail)"
else
  rm -f "$NIX_DISK_IMAGE"
  echo "==> fresh disk image: $NIX_DISK_IMAGE"
fi

# Swap the nix qemu for the host qemu everywhere in the script. The GPU and
# display flags come from hosts/demo.nix and are already baked into $RUNNER;
# anything in QEMU_OPTS here is appended, and later flags win, so
#   QEMU_OPTS="-display gtk,gl=on" ./scripts/run-vm-gl.sh
# is how you override the display backend.
sed "s|/nix/store/[a-z0-9]*-qemu[^/]*/bin/qemu-system-x86_64|$HOSTQEMU|g;
     s|/nix/store/[a-z0-9]*-qemu[^/]*/bin/qemu-img|$(command -v qemu-img || echo '/usr/bin/qemu-img')|g" \
  "$RUNNER" > "$VM_ROOT/run-vm-gl.sh"
chmod +x "$VM_ROOT/run-vm-gl.sh"

echo "==> log in as demo / demo; the mod key in the VM is Alt"
exec env QEMU_OPTS="-m 4096 -smp 4 -enable-kvm ${QEMU_OPTS:-}" "$VM_ROOT/run-vm-gl.sh"
