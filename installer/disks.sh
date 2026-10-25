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

# ── where a restore kit lives on an installer stick ──────────────────────
#
# A kit is NOT a partition. Adding an entry to an isohybrid ISO's partition
# table made a ThinkPad's firmware refuse to boot the stick (2026-10-25: the
# ISO carries an MBR AND a GPT, and an MBR entry the GPT does not know about
# was enough), so the stick stays byte-identical to the ISO and the kit sits
# in the free space after it: a LUKS2 container labelled WABISABI-DATA, at
# the first MiB boundary at or after the image's end. Both tools find it the
# same way, by reading that space.

KIT_LABEL=WABISABI-DATA

# The end of the isohybrid image on $1 (a disk or an image file), in bytes:
# the furthest of its MBR partitions (but type 83, the kit partition of the
# first wabisabi-usb), its GPT backup header, and its ISO 9660 volume. 0 when
# none of them is there, i.e. not an installer image.
image_end_bytes() {
  local dev="$1" end=0 e alt vol bs
  e=$(sfdisk -J "$dev" 2>/dev/null \
    | jq '[.partitiontable.partitions[]? | select(.type != "83") | .start + .size] | max // 0' 2>/dev/null || echo 0)
  [ "${e:-0}" -gt "$end" ] && end=$e
  if [ "$(dd if="$dev" bs=512 skip=1 count=1 status=none 2>/dev/null | head -c 8)" = "EFI PART" ]; then
    alt=$(dd if="$dev" bs=1 skip=$((512 + 32)) count=8 status=none 2>/dev/null | od -An -tu8 | tr -d ' ')
    [ $((alt + 1)) -gt "$end" ] && end=$((alt + 1))
  fi
  if [ "$(dd if="$dev" bs=1 skip=$((32768 + 1)) count=5 status=none 2>/dev/null)" = CD001 ]; then
    vol=$(dd if="$dev" bs=1 skip=$((32768 + 80)) count=4 status=none | od -An -tu4 | tr -d ' ')
    bs=$(dd if="$dev" bs=1 skip=$((32768 + 128)) count=2 status=none | od -An -tu2 | tr -d ' ')
    e=$((vol * bs / 512))
    [ "$e" -gt "$end" ] && end=$e
  fi
  echo $((end * 512))
}

mib_ceil() { echo $(( ($1 + 1048575) / 1048576 * 1048576 )); }

# Prints the byte offset of the kit on $1, or fails. It scans 128 MiB from
# the image's end, so a writer that started a little further on (it rounds
# up from the ISO FILE's size, which may exceed what the image declares)
# is still found.
kit_scan() {
  local dev="$1" end off i
  end=$(image_end_bytes "$dev")
  [ "$end" -gt 0 ] || return 1
  off=$(mib_ceil "$end")
  for ((i = 0; i < 128; i++)); do
    if [ "$(blkid -p -O "$off" -o value -s LABEL "$dev" 2>/dev/null || true)" = "$KIT_LABEL" ]; then
      echo "$off"
      return 0
    fi
    off=$((off + 1048576))
  done
  return 1
}
