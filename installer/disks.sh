# The disk-safety rules, shared by wabisabi-install and wabisabi-usb.
#
# Sourced, not run. The caller defines die, warn, note and ASSUME_YES; these
# functions only decide whether a device may be destroyed, and ask. Kept in
# one file because the two tools destroy different disks for different
# reasons, and the rules for "this is the wrong disk" must not drift apart.

# The disk the running system booted from (a live USB stick, or the root
# disk of an installed machine), so it can be called out in a list rather
# than silently offered as a target.
live_disk() {
  local src
  src=$(findmnt -no SOURCE /iso 2>/dev/null || true)
  [ -z "$src" ] && src=$(findmnt -no SOURCE / 2>/dev/null || true)
  [ -z "$src" ] && return 0
  # A partition names its disk. A whole disk names nothing, and that is the
  # usual case for a USB stick written from an ISO: the ISO 9660 filesystem
  # starts at sector 0, so /iso is often mounted from the disk itself.
  local parent
  parent=$(lsblk -no PKNAME "$src" 2>/dev/null | head -1)
  if [ -n "$parent" ]; then
    echo "$parent"
  elif [ "$(lsblk -dno TYPE "$src" 2>/dev/null)" = disk ]; then
    basename "$src"
  fi
}

# Checks that --yes does NOT get to skip, because they are not about being
# sure, they are about the target being the wrong device entirely.
check_device_safe() {
  local device="$1" live mounted

  [ -b "$device" ] || die "'$device' is not a block device."

  live=$(live_disk || true)
  if [ -n "$live" ] && [ "$(basename "$device")" = "$live" ]; then
    die "$device is the disk this system is running from. Refusing."
  fi

  # Anything mounted on the target is either the running system or somebody's
  # data that is currently in use. Neither is a target.
  mounted=$(lsblk -no MOUNTPOINTS "$device" 2>/dev/null | tr -d ' ' | grep -v '^$' || true)
  if [ -n "$mounted" ]; then
    die "$device has mounted filesystems ($(tr '\n' ' ' <<<"$mounted")). Refusing to overwrite a disk that is in use."
  fi
}

# Typed confirmation: the device name, back. --yes skips this one only.
confirm_destruction() {
  local device="$1" typed
  echo
  warn "About to DESTROY everything on $device:"
  lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINTS "$device" || true
  echo
  if [ "${ASSUME_YES:-0}" = 1 ]; then
    note "Proceeding without the typed confirmation (--yes)."
    return 0
  fi
  note "Type the device name ($(basename "$device")) to confirm, or anything else to abort."
  typed=$(gum input --placeholder "$(basename "$device")")
  [ "$typed" = "$(basename "$device")" ] || die "not confirmed; no disk was touched."
}
