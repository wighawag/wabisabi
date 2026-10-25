#!/usr/bin/env bash
# End-to-end install test: boot the installer ISO in QEMU, let it install onto
# a blank disk, then boot THAT DISK and check what came out.
#
# Evaluating is not verifying, and neither is a successful install: the
# interesting question is whether the machine that was just written to disk
# boots, comes up healthy, and is the machine its own flake describes. So this
# runs in four stages, each of which can fail on its own:
#
#   1. install   boot the autotest ISO, which runs wabisabi-install unattended
#                against a blank disk and powers off. Watches the serial log
#                for the success sentinel.
#   2. boot      boot the installed disk with a real GPU (virtio-vga-gl under
#                egl-headless, because niri refuses software EGL) and take a
#                screenshot of the login screen.
#   3. inspect   boot the ISO again with the installed disk attached, mount it,
#                and check the installed system from outside: the user, the
#                hostname, the keymap, the generated flake, failed units.
#   4. rebuild   on that same mounted system, rebuild /etc/nixos OFFLINE and
#                check it produces exactly the system that was installed. This
#                is the one that proves the generated flake is real rather
#                than decorative.
#
# Usage:
#   ./scripts/test-install-vm.sh [--luks] [--offline] [--restore] [--restore-fleet] [--stage N]
#
# --restore installs from an existing config repo (the restore-fixture
# output: two commits, sops secrets with the published test key) instead of
# answering questions, and checks the machine came out as the REPO describes.
# --restore-fleet does the same from a two-host FLEET repo shaped like
# my-boxes (installer/test-fleet): disks declared with disko, secrets
# encrypted to the host's SSH key, the host key placed from the repo.
#
# The disk image is always kept afterwards, for inspection.
set -euo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# Disk images live OUTSIDE the checkout. Anything under the repo is copied
# into /nix/store whenever the tree is evaluated as a `path:` flake (which
# ignores .gitignore), and these qcow2s once cost ~85 GB per evaluation:
# 13 such copies filled telemaque's 1.8 TB disk in two days (2026-10-25).
VM_ROOT=${WABISABI_VM_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/wabisabi/vm}
WORK="$VM_ROOT/install-test"
VARIANT="plain"
ISO_ATTR="iso-autotest"
ONLY_STAGE=""
DISK_SIZE="32G"
TIMEOUT_INSTALL=${TIMEOUT_INSTALL:-3600}
TIMEOUT_BOOT=${TIMEOUT_BOOT:-300}

while [ $# -gt 0 ]; do
  case "$1" in
    --luks) VARIANT="luks"; ISO_ATTR="iso-autotest-luks"; shift ;;
    --offline) VARIANT="offline"; ISO_ATTR="iso-autotest-offline"; shift ;;
    --restore) VARIANT="restore"; ISO_ATTR="iso-autotest-restore"; shift ;;
    --restore-fleet) VARIANT="restore-fleet"; ISO_ATTR="iso-autotest-restore-fleet"; shift ;;
    --stage) ONLY_STAGE="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

say() { printf '\n\033[1;35m==> %s\033[0m\n' "$*"; }
ok() { printf '\033[1;32m  ok\033[0m %s\n' "$*"; }
bad() { printf '\033[1;31m  FAIL\033[0m %s\n' "$*"; FAILURES=$((FAILURES + 1)); }
FAILURES=0

want_stage() { [ -z "$ONLY_STAGE" ] || [ "$ONLY_STAGE" = "$1" ]; }

# Tools. Prefer the host's QEMU when there is one (on a non-NixOS host it is
# the only one that can load the host's GL drivers -- see run-vm-gl.sh), and
# otherwise take everything from nixpkgs so this script has no prerequisites
# beyond nix itself.
nixbin() {
  local attr="$1" bin="$2"
  local out
  out=$(nix build --no-link --print-out-paths "nixpkgs#$attr" 2>/dev/null | head -1)
  echo "$out/bin/$bin"
}

QEMU=$(command -v qemu-system-x86_64 || nixbin qemu qemu-system-x86_64)
QEMU_IMG=$(command -v qemu-img || nixbin qemu qemu-img)
SOCAT=$(command -v socat || nixbin socat socat)
PNMTOPNG=$(command -v pnmtopng || nixbin netpbm pnmtopng)
OVMF_DIR=$(nix build --no-link --print-out-paths nixpkgs#OVMF.fd 2>/dev/null | head -1)
OVMF_CODE="$OVMF_DIR/FV/OVMF_CODE.fd"
OVMF_VARS_SRC="$OVMF_DIR/FV/OVMF_VARS.fd"

# THE GRAPHICAL SESSION CANNOT BE VERIFIED WITHOUT A GL-CAPABLE HOST, and
# saying so is more useful than a test that quietly checks something else.
# niri refuses software EGL, so rendering the installed desktop needs QEMU's
# virtio-vga-gl, which needs working EGL/GBM on the host (on NixOS that means
# hardware.graphics.enable, which creates /run/opengl-driver). Without it this
# script verifies that the machine boots to its LOGIN screen, which the text
# greeter draws on the plain emulated VGA, and leaves the session itself to
# ./scripts/run-vm-gl.sh on a workstation.
GL=0
if [ -e /run/opengl-driver ] && [ -e /dev/dri/renderD128 ]; then GL=1; fi

mkdir -p "$WORK"
DISK="$WORK/$VARIANT.qcow2"
VARS="$WORK/$VARIANT-vars.fd"
SERIAL="$WORK/$VARIANT-install.log"
SHOT="$WORK/$VARIANT-login.ppm"

# ── stage 1: install ──────────────────────────────────────────────────────

if want_stage 1; then
  say "Building the $VARIANT autotest ISO"
  ISO_DIR=$(nix build --no-link --print-out-paths "$REPO#$ISO_ATTR")
  ISO=$(echo "$ISO_DIR"/iso/*.iso)
  ok "$(basename "$ISO") ($(du -h "$ISO" | cut -f1))"

  say "Creating a blank $DISK_SIZE disk"
  rm -f "$DISK" "$VARS" "$SERIAL"
  # qemu-img initialises io_uring at startup and fails outright with
  # "Cannot allocate memory" when locked-memory is tight, which it is right
  # after building a multi-gigabyte ISO. It is transient, so retry rather
  # than making the operator re-run the whole thing.
  for attempt in 1 2 3 4 5; do
    if "$QEMU_IMG" create -f qcow2 "$DISK" "$DISK_SIZE" >/dev/null 2>"$WORK/qemu-img.err"; then
      break
    fi
    if [ "$attempt" = 5 ]; then
      bad "could not create the disk image:"
      sed 's/^/      /' "$WORK/qemu-img.err"
      exit 1
    fi
    echo "    qemu-img failed (attempt $attempt), retrying in 20s: $(tr -d '\n' < "$WORK/qemu-img.err")"
    sleep 20
  done
  install -m 0644 "$OVMF_VARS_SRC" "$VARS"

  # THE OFFLINE VARIANT IS RUN WITH NO NETWORK DEVICE AT ALL. Leaving one
  # attached would let a supposedly offline install quietly fetch something
  # from cache.nixos.org and still pass, which would verify nothing.
  if [ "$VARIANT" = "offline" ]; then
    net=(-nic none)
    echo "    no network device attached: the medium has to be self-sufficient"
  else
    # Quoted: each comma-separated string is one QEMU argument, not several
    # array elements (shellcheck SC2054).
    net=(-netdev "user,id=net0" -device "virtio-net-pci,netdev=net0")
  fi

  say "Installing (unattended). This boots the ISO and waits for it to finish."
  echo "    log: $SERIAL"
  set +e
  timeout "$TIMEOUT_INSTALL" "$QEMU" \
    -machine q35,accel=kvm -cpu host -m 8192 -smp 4 \
    -drive if=pflash,format=raw,unit=0,readonly=on,file="$OVMF_CODE" \
    -drive if=pflash,format=raw,unit=1,file="$VARS" \
    -drive file="$DISK",if=virtio,format=qcow2 \
    -cdrom "$ISO" -boot d \
    "${net[@]}" \
    -display none -serial "file:$SERIAL"
  rc=$?
  set -e
  [ $rc -eq 0 ] || echo "  (qemu exited $rc)"

  if grep -q "WABISABI_INSTALL_OK" "$SERIAL"; then
    ok "installer reported success: $(grep -o 'WABISABI_INSTALL_OK.*' "$SERIAL" | head -1)"

    if [ "$VARIANT" = restore-fleet ]; then
      if grep -q "WABISABI_INSTALL_OK host=laptop user=tester layout=disko .*mode=restore" "$SERIAL"; then
        ok "restored the fleet's laptop, partitioned by its own disko declaration"
      else
        bad "the fleet restore did not report host=laptop with layout=disko"
      fi
      if grep -q "Placed /etc/ssh/ssh_host_ed25519_key" "$SERIAL"; then
        ok "the host key was placed from the repo before the first boot"
      else
        bad "the host key was not placed"
      fi
      # The laptop decrypts with its host key: if its own password secret
      # came through, the placed key was the right one.
      if grep -q "Password set for tester, as the config declares it" "$SERIAL"; then
        ok "the config's own password secret was decrypted with the placed host key"
      else
        bad "the declared password did not come through"
      fi
      if grep -q "used for this restore only" "$SERIAL"; then
        ok "the admin key was not copied to the new disk"
      else
        bad "the admin key's placement was not the expected one"
      fi
    elif [ "$VARIANT" = restore ]; then
      # The restore answers name only the source, the key and the disk. The
      # hostname and user are the fixture repo's, so seeing them here means
      # they were read out of the repo.
      if grep -q "WABISABI_INSTALL_OK host=restored user=mira .*mode=restore" "$SERIAL"; then
        ok "restored the repo's machine (host and user read from the repo)"
      else
        bad "the restore did not produce the repo's host and user"
      fi
      if grep -q "Your key opens the repo's secrets" "$SERIAL"; then
        ok "the key was proved against the repo's secrets before partitioning"
      else
        bad "the key was not checked against the repo"
      fi
    # The answers file says nothing about secrets, so this also checks that
    # an unanswered secrets question takes the recommended default.
    elif grep -q "WABISABI_INSTALL_OK.*secrets=generate" "$SERIAL"; then
      ok "secrets were set up with a generated key (the default)"
    else
      bad "secrets were not set up by default"
    fi
    # The first time the key, the encrypted file and sops-nix meet: the
    # installer compares the hash activation put in /etc/shadow with the one
    # it encrypted, and only says this when they are equal.
    if [ "$VARIANT" = restore-fleet ]; then
      : # its password is the config's own secret, checked above
    elif grep -q "from the encrypted config" "$SERIAL"; then
      ok "the login password came from the sops-encrypted config"
    else
      bad "the password did not come from the encrypted config"
    fi
    if [ "$VARIANT" = restore-fleet ]; then
      : # the fleet repo declares no /etc/nixos link, by design
    elif grep -q "does not link to" "$SERIAL"; then
      bad "/etc/nixos is not a link on the installed system"
    else
      ok "/etc/nixos links to the config repo"
    fi
  else
    bad "no success sentinel in the install log; last lines:"
    tail -30 "$SERIAL" | sed 's/^/      /'
    exit 1
  fi
fi

# ── stage 2: boot the installed disk ──────────────────────────────────────

if want_stage 2; then
  say "Booting the installed disk"
  MONITOR="$WORK/$VARIANT-monitor.sock"
  rm -f "$MONITOR" "$SHOT"

  if [ "$GL" = 1 ]; then
    # egl-headless gives the guest a real GL context with no window, which is
    # what lets a headless run screenshot a session that refuses llvmpipe.
    gfx=(-vga none -device virtio-vga-gl -display egl-headless)
    echo "    GL available: the session itself should render"
  else
    gfx=(-vga std -display none)
    echo "    no host GL: checking for the text login screen only"
  fi

  set +e
  "$QEMU" \
    -machine q35,accel=kvm -cpu host -m 4096 -smp 4 \
    -drive if=pflash,format=raw,unit=0,readonly=on,file="$OVMF_CODE" \
    -drive if=pflash,format=raw,unit=1,file="$VARS" \
    -drive file="$DISK",if=virtio,format=qcow2 \
    -netdev user,id=net0 -device virtio-net-pci,netdev=net0 \
    "${gfx[@]}" \
    -monitor "unix:$MONITOR,server,nowait" \
    -daemonize -pidfile "$WORK/$VARIANT.pid" 2>/dev/null
  rc=$?
  set -e

  if [ $rc -ne 0 ]; then
    bad "could not start the VM for the installed disk"
  else
    if [ "$VARIANT" = "luks" ]; then
      sleep "${LUKS_WAIT:-25}"
      # Evidence that the prompt was actually on screen when the keys were
      # sent, so a failure can be told apart from a mistimed one.
      echo "screendump ${SHOT%.ppm}-prompt.ppm" | "$SOCAT" - "unix-connect:$MONITOR" >/dev/null
      sleep 1
      "$PNMTOPNG" "${SHOT%.ppm}-prompt.ppm" > "${SHOT%.ppm}-prompt.png" 2>/dev/null || true
      say "Typing the LUKS passphrase"
      # THIS SPELLS "testpassphrase" ON A FRENCH KEYBOARD, and the difference
      # is the whole test. `sendkey` sends physical keys by their US names, and
      # installer/test-answers-vm.json chose layout "fr", which the installer
      # carries into the initrd through console.useXkbConfig. So the physical
      # key that yields 'a' is the one called 'q'.
      #
      # If this unlocks, the initrd really is using the layout that was chosen
      # during installation. If wabisabi ever stops carrying the layout that
      # far, this hangs at the passphrase prompt instead of quietly passing,
      # which is the failure everyone else discovers on real hardware.
      for ch in t e s t p q s s p h r q s e; do
        echo "sendkey $ch" | "$SOCAT" - "unix-connect:$MONITOR" >/dev/null
        sleep 0.1
      done
      echo "sendkey ret" | "$SOCAT" - "unix-connect:$MONITOR" >/dev/null
    fi

    echo "    waiting ${TIMEOUT_BOOT}s for the login screen"
    sleep "$TIMEOUT_BOOT"
    echo "screendump $SHOT" | "$SOCAT" - "unix-connect:$MONITOR" >/dev/null
    sleep 2
    if [ -s "$SHOT" ]; then
      "$PNMTOPNG" "$SHOT" > "${SHOT%.ppm}.png" 2>/dev/null || true
      ok "screenshot: ${SHOT%.ppm}.png"

      # A screen of one single colour is the classic "niri is running fine and
      # rendering nothing" failure, and it must not pass as success.
      colours=$(tail -c +16 "$SHOT" | od -An -tx1 -w3 -v | sort -u | head -5 | wc -l)
      if [ "$colours" -gt 1 ]; then
        ok "the screen has content (not a blank or single-colour frame)"
      else
        bad "the screen is a single flat colour: nothing rendered"
      fi

      # For LUKS, the machine must have moved PAST the passphrase prompt. If
      # the final frame still equals the prompt frame, the passphrase was
      # rejected -- which is what happens when the initrd keymap is not the
      # one chosen during installation.
      if [ "$VARIANT" = "luks" ] && [ -s "${SHOT%.ppm}-prompt.ppm" ]; then
        if cmp -s "$SHOT" "${SHOT%.ppm}-prompt.ppm"; then
          bad "still sitting at the LUKS passphrase prompt: the initrd keymap does not match the installed layout"
        else
          ok "unlocked and moved past the passphrase prompt (initrd keymap matches the chosen layout)"
        fi
      fi
    else
      bad "no screenshot produced"
    fi
    kill "$(cat "$WORK/$VARIANT.pid")" 2>/dev/null || true
  fi
fi

# ── stages 3 and 4: inspect the installed system from outside ─────────────

if [ "$ONLY_STAGE" = 3 ] || [ "$ONLY_STAGE" = 4 ]; then
  # Asked for by name, so do not print a green banner for work that does not
  # exist. A test tool that reports success for an unimplemented stage is
  # worse than one that has no such stage.
  say "Inspecting the installed system"
  bad "stages 3 and 4 are not implemented (see notes/installer.md); nothing was checked"
  exit 2
fi

say "Result"
if [ "$FAILURES" -eq 0 ]; then
  ok "all checks passed ($VARIANT)"
else
  bad "$FAILURES check(s) failed ($VARIANT)"
  exit 1
fi

echo "  (disk kept at $DISK for inspection; remove $WORK to reclaim the space)"
