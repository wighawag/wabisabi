#!/usr/bin/env bash
# wabisabi-usb: make a wabisabi installer stick, with room for a restore kit.
#
#   wabisabi-usb write DEVICE --iso FILE          the ISO you have
#   wabisabi-usb write DEVICE --release KIND      download the newest release's
#                                                 ISO (netinstall or offline),
#                                                 checked against its SHA-256
#   wabisabi-usb kit DEVICE                       put a restore kit on it
#   wabisabi-usb wipe DEVICE                      erase the restore kit
#   wabisabi-usb show DEVICE                      what is on it
#
# THE LAYOUT. `write` copies the ISO to the stick byte for byte and changes
# NOTHING else: no partition is added, because an entry added to an
# isohybrid ISO's partition table made a ThinkPad refuse to boot the stick.
# The stick boots exactly as the ISO does.
#
# THE RESTORE KIT lives in the free space after the ISO, at the first MiB
# boundary past its end (installer/disks.sh, kit_scan). It is a LUKS2
# container labelled WABISABI-DATA, encrypted with a passphrase you choose, holding the answers a restore
# needs and the keys it uses: your config repo, which machine in it, your age
# key and (for a private repo) an ssh key. Booted from the stick,
# `sudo wabisabi-install` finds it, asks for the passphrase and restores with
# no other question but the disk's own; after a successful install it offers
# to erase the kit. A lost stick gives away nothing without the passphrase.
#
# DEVICE may also be an image FILE, which is how the tool is tested and how
# you can prepare a stick image to write later; a file is never refused as
# "the wrong disk", since it is not one.
#
# Options:
#   --iso FILE              write: the ISO to write (a file or a block device)
#   --release KIND          write: netinstall | offline, newest published
#   --version X.Y.Z         write: with --release, that version instead
#   --kit                   write: then make a restore kit in the same run
#   --any-disk              write: allow a disk that is not removable/USB
#   --source REPO           kit: the config repo (anything git clone takes)
#   --host NAME             kit: the machine in it (nixosConfigurations name)
#   --repo-path PATH        kit: where the repo goes on the restored machine
#   --age-key FILE          kit: the age key (default: ~/.config/sops/age/keys.txt)
#   --ssh-key FILE|none     kit: a key for a private repo (default: ~/.ssh/id_ed25519
#                           when the repo is fetched over ssh)
#   --passphrase-file FILE  kit: the kit's passphrase, for unattended use
#   --yes                   skip the typed confirmations (never the safety checks)
set -euo pipefail

: "${WABISABI_DISKS_LIB:?internal: disks.sh path not baked in}"
DOWNLOADS="${WABISABI_DOWNLOADS:-https://downloads.wabisabi.computer}"
# The kit's container: small, because it holds a few small files. The LUKS2
# header takes 16 MiB of it.
KIT_IMAGE_MIB=64
KIT_FS_MIB=40
# Free space the stick must have after the ISO.
MIN_DATA_MIB=$((KIT_IMAGE_MIB + 16))

bold() { gum style --bold -- "$*"; }
note() { gum style --foreground 244 -- "$*"; }
warn() { gum style --foreground 214 -- "$*"; }
die() { gum style --foreground 196 --bold -- "error: $*" >&2; exit 1; }
heading() { echo; gum style --bold --foreground 141 -- "── $* ──"; }

# shellcheck disable=SC1090
source "$WABISABI_DISKS_LIB"

usage() { sed -n '2,42p' "$0" | sed 's/^# \{0,1\}//'; }

cmd="${1:-}"
[ -n "$cmd" ] || { usage; exit 2; }
shift
case "$cmd" in -h|--help|help) usage; exit 0 ;; esac
TARGET="${1:-}"
[ -n "$TARGET" ] || die "which device? (wabisabi-usb $cmd /dev/sdX; lsblk lists them)"
shift

WRITE_START=""
ISO="" RELEASE="" VERSION="" WITH_KIT=0 ANY_DISK=0 ASSUME_YES=0
SOURCE="" HOST="" REPO_PATH="" AGE_KEY="" SSH_KEY="" PASSFILE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --iso) ISO="$2"; shift 2 ;;
    --release) RELEASE="$2"; shift 2 ;;
    --version) VERSION="$2"; shift 2 ;;
    --kit) WITH_KIT=1; shift ;;
    --any-disk) ANY_DISK=1; shift ;;
    --source) SOURCE="$2"; shift 2 ;;
    --host) HOST="$2"; shift 2 ;;
    --repo-path) REPO_PATH="$2"; shift 2 ;;
    --age-key) AGE_KEY="$2"; shift 2 ;;
    --ssh-key) SSH_KEY="$2"; shift 2 ;;
    --passphrase-file) PASSFILE="$2"; shift 2 ;;
    --yes|-y) ASSUME_YES=1; shift ;;
    *) die "unknown argument '$1' (wabisabi-usb --help)" ;;
  esac
done

# Scratch space for the kit's keys: tmpfs, never a disk.
WORK=$(mktemp -d -p /run 2>/dev/null || mktemp -d -p /dev/shm 2>/dev/null || mktemp -d)
chmod 700 "$WORK"
trap 'rm -rf "$WORK"' EXIT INT TERM HUP

# The invoking user's home, also under sudo, for the default key paths.
user_home() {
  if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ]; then
    getent passwd "$SUDO_USER" | cut -d: -f6
  else
    echo "$HOME"
  fi
}

is_file_target() { [ -f "$TARGET" ]; }

size_of() {
  if [ -b "$1" ]; then blockdev --getsize64 "$1"; else stat -c %s "$1"; fi
}

need_root_for_device() {
  if ! is_file_target && [ "$(id -u)" != 0 ]; then
    die "writing to $TARGET needs root. Try: sudo wabisabi-usb $cmd $TARGET ..."
  fi
}

# Safety for a real device: the shared rules, plus "this is a stick". A
# laptop's internal disk is the one disk this tool must never be pointed at
# by a typo, and it is never removable.
check_target() {
  if is_file_target; then return 0; fi
  check_device_safe "$TARGET"
  local rm tran
  rm=$(lsblk -dno RM "$TARGET" 2>/dev/null | tr -d ' ')
  tran=$(lsblk -dno TRAN "$TARGET" 2>/dev/null | tr -d ' ')
  if [ "$rm" != 1 ] && [ "$tran" != usb ] && [ "$ANY_DISK" != 1 ]; then
    die "$TARGET is not a removable or USB disk. If it really is the stick, add --any-disk."
  fi
}

# The kit's place on the stick: the first MiB boundary after the ISO, where
# kit_scan looks. Sets DATA_START and DATA_SIZE (bytes), or dies. Not a $(...)
# helper: a die inside a command substitution only ends the subshell.
read_data_region() {
  local end found
  end=$(image_end_bytes "$TARGET")
  [ "$end" -gt 0 ] || die "$TARGET does not hold an installer ISO. Write it first: wabisabi-usb write $TARGET --iso ..."
  # An existing kit decides the offset (a writer may have started it further
  # on); otherwise the first MiB boundary after the image.
  if found=$(kit_scan "$TARGET"); then DATA_START=$found; else DATA_START=$(mib_ceil "$end"); fi
  DATA_SIZE=$(( $(size_of "$TARGET") - DATA_START ))
}

kit_present() { kit_scan "$TARGET" >/dev/null; }

# Zero the start of the kit's place: an old kit's header, or any other
# signature, must not survive a rewrite.
clear_data_start() {
  local start="$1" mib="${2:-32}"
  dd if=/dev/zero of="$TARGET" bs=1M count="$mib" seek="$start" oflag=seek_bytes conv=notrunc,fsync status=none
}

# ── write ─────────────────────────────────────────────────────────────────

fetch_release() {
  local kind="$1" index name sha size url dir out
  case "$kind" in netinstall|offline) ;; *) die "--release is netinstall or offline (got '$kind')." ;; esac
  heading "Finding the $kind ISO"
  index=$(curl -fsSL "$DOWNLOADS/releases.json") || die "could not read $DOWNLOADS/releases.json."
  local sel
  if [ -n "$VERSION" ]; then
    sel=$(jq -c --arg v "${VERSION#v}" --arg k "$kind" '.releases[] | select(.version == $v) | {version, f: (.files[] | select(.kind == $k))}' <<<"$index" | head -1)
  else
    sel=$(jq -c --arg k "$kind" '.releases[0] | {version, f: (.files[] | select(.kind == $k))}' <<<"$index" | head -1)
  fi
  [ -n "$sel" ] || die "no $kind ISO for ${VERSION:-the newest release} at $DOWNLOADS."
  VERSION=$(jq -r .version <<<"$sel")
  name=$(jq -r .f.name <<<"$sel")
  sha=$(jq -r .f.sha256 <<<"$sel")
  size=$(jq -r .f.size <<<"$sel")
  url="$DOWNLOADS/v$VERSION/$name"

  dir="${XDG_CACHE_HOME:-$(user_home)/.cache}/wabisabi/v$VERSION"
  mkdir -p "$dir"
  out="$dir/$name"
  if [ -f "$out" ] && [ "$(stat -c %s "$out")" = "$size" ]; then
    note "Already downloaded: $out"
  else
    note "v$VERSION, $((size / 1024 / 1024)) MiB, to $out"
    curl -fL --retry 3 -C - -o "$out" "$url" || die "download failed: $url"
  fi
  note "Checking its SHA-256 against the release index"
  echo "$sha  $out" | sha256sum -c --quiet - || { rm -f "$out"; die "the download does not match its published SHA-256; removed it. Try again."; }
  ISO="$out"
}

do_write() {
  [ -n "$ISO" ] || [ -n "$RELEASE" ] || die "write needs --iso FILE or --release netinstall|offline."
  [ -z "$ISO" ] || [ -z "$RELEASE" ] || die "give --iso or --release, not both."
  need_root_for_device
  check_target
  # Everything the kit needs, checked BEFORE the download and the write.
  [ "$WITH_KIT" = 1 ] && kit_gather
  [ -n "$RELEASE" ] && fetch_release "$RELEASE"
  [ -r "$ISO" ] || die "cannot read '$ISO'."

  local iso_bytes dev_bytes start
  iso_bytes=$(size_of "$ISO")
  dev_bytes=$(size_of "$TARGET")
  # The data partition starts on the first MiB boundary after the ISO.
  # The kit's place: the first MiB boundary after the ISO, whichever is
  # further of its file size and the image it declares (they are equal for
  # wabisabi's ISOs).
  local declared
  declared=$(image_end_bytes "$ISO")
  [ "$declared" -gt 0 ] || die "'$ISO' does not look like an isohybrid installer image (no ISO 9660, MBR or GPT)."
  start=$(mib_ceil "$iso_bytes")
  [ "$(mib_ceil "$declared")" -le "$start" ] || start=$(mib_ceil "$declared")
  if [ $((dev_bytes - start)) -lt $((MIN_DATA_MIB * 1048576)) ]; then
    die "$TARGET ($((dev_bytes / 1048576)) MiB) is too small for this ISO ($((iso_bytes / 1048576)) MiB) plus ${MIN_DATA_MIB} MiB for a restore kit."
  fi

  heading "Writing $(basename "$ISO") to $TARGET"
  if is_file_target; then
    note "$TARGET is an image file; it is overwritten, not resized."
  else
    confirm_destruction "$TARGET"
  fi

  # O_DIRECT on a device, so the progress dd prints is the STICK's progress.
  # Without it dd fills the page cache in seconds, shows a finished count, and
  # then sits silent in the final fsync for as long as the stick takes.
  if is_file_target; then
    dd if="$ISO" of="$TARGET" bs=4M conv=notrunc,fsync status=progress
  else
    note "Writing $((iso_bytes / 1048576)) MiB; the count below is what the stick has really taken."
    dd if="$ISO" of="$TARGET" bs=4M iflag=fullblock oflag=direct conv=fsync status=progress
  fi
  # Nothing is added to the partition tables (see THE LAYOUT): only the
  # start of the free space is cleared, so no earlier kit survives a rewrite.
  clear_data_start "$start"
  sync

  # Proof that the stick IS the ISO, byte for byte, read from the stick and
  # not from the page cache.
  is_file_target || blockdev --flushbufs "$TARGET" 2>/dev/null || true
  note "Reading it back to verify (about as long as the write took)"
  if cmp -s -n "$iso_bytes" "$ISO" "$TARGET"; then
    note "Verified: $TARGET holds $(basename "$ISO") byte for byte."
  else
    die "the stick does not read back as the ISO. Try another stick, or write again."
  fi
  WRITE_START=$start
  echo "WABISABI_USB_WRITTEN target=$TARGET data_start=$start"
  bold "$TARGET boots the installer, with $(( (dev_bytes - start) / 1048576 )) MiB free after it for a restore kit."

  if [ "$WITH_KIT" = 1 ]; then
    heading "Writing the restore kit"
    kit_apply
  elif [ "$ASSUME_YES" != 1 ] && gum confirm --default=false "Put a restore kit on it now (your config repo and keys, encrypted)?"; then
    kit_gather
    kit_apply
  else
    note "A restore kit can be added later: wabisabi-usb kit $TARGET"
  fi
}

# ── kit ───────────────────────────────────────────────────────────────────

valid_age_key() {
  [[ "$1" =~ ^AGE-SECRET-KEY-1[0-9A-Z]{58}$ ]] && age-keygen -y <(printf '%s\n' "$1") >/dev/null 2>&1
}

ask_text() {
  local prompt="$1" default="$2" value
  bold "$prompt" >&2
  value=$(gum input --value "$default" --placeholder "$default")
  echo "$value"
}

# Everything the kit holds, gathered and CHECKED before anything is written:
# a missing key must stop `write --kit` before the stick is overwritten, not
# after. Sets KIT_KEY and KIT_PASS.
KIT_KEY="" KIT_PASS="" KIT_GATHERED=0
kit_gather() {
  [ "$KIT_GATHERED" = 0 ] || return 0
  heading "What the restore kit will hold"
  local home interactive=1
  home=$(user_home)
  [ "$ASSUME_YES" = 1 ] && interactive=0

  # The repo: by default the one this is run from, which is where someone
  # making a kit for their own machine usually is.
  if [ -z "$SOURCE" ]; then
    local guess=""
    guess=$(git -C . remote get-url origin 2>/dev/null || true)
    [ "$interactive" = 1 ] || die "--source is required with --yes."
    SOURCE=$(ask_text "Your config repo (anything git clone takes)" "$guess")
  fi
  [ -n "$SOURCE" ] || die "a restore kit needs the config repo."

  if [ -z "$HOST" ]; then
    [ "$interactive" = 1 ] || die "--host is required with --yes."
    HOST=$(ask_text "Which machine in it (its nixosConfigurations name)" "$(hostname 2>/dev/null || true)")
  fi
  [ -n "$HOST" ] || die "a restore kit needs the machine's name."

  if [ -z "$REPO_PATH" ] && [ "$interactive" = 1 ]; then
    REPO_PATH=$(ask_text "Where the repo goes on the restored machine (empty: where the config says)" "")
  fi
  if [ -n "$REPO_PATH" ]; then
    case "$REPO_PATH" in /*) ;; *) die "--repo-path must be absolute (got '$REPO_PATH')." ;; esac
  fi

  # The age key, read from a file and never typed.
  [ -n "$AGE_KEY" ] || AGE_KEY="$home/.config/sops/age/keys.txt"
  [ -r "$AGE_KEY" ] || die "no age key at $AGE_KEY. Give --age-key FILE (on a machine where the key is root-only, e.g. --age-key /root/.config/sops/age/keys.txt)."
  local key
  key=$(grep -m1 '^AGE-SECRET-KEY-1' "$AGE_KEY" || true)
  valid_age_key "$key" || die "$AGE_KEY holds no valid age secret key."

  # An ssh key, when the repo is fetched over ssh (a private repo, or flake
  # inputs pinned as git+ssh).
  if [ -z "$SSH_KEY" ]; then
    case "$SOURCE" in
      git@*|ssh://*|*.git) [ -r "$home/.ssh/id_ed25519" ] && SSH_KEY="$home/.ssh/id_ed25519" ;;
    esac
  fi
  [ "$SSH_KEY" = none ] && SSH_KEY=""
  if [ -n "$SSH_KEY" ]; then
    [ -r "$SSH_KEY" ] || die "cannot read the ssh key $SSH_KEY."
    ssh-keygen -y -P "" -f "$SSH_KEY" >/dev/null 2>&1 \
      || die "$SSH_KEY is not an ssh private key, or it has a passphrase (the installer cannot ask for one)."
  fi

  # The passphrase, twice.
  local pass pass2
  if [ -n "$PASSFILE" ]; then
    pass=$(cat "$PASSFILE")
  else
    [ "$interactive" = 1 ] || die "--passphrase-file is required with --yes."
    while true; do
      bold "A passphrase for the kit" >&2
      note "Asked when the installer opens it. Not your login password: the stick may be lost, so make it a real one." >&2
      pass=$(gum input --password --placeholder "passphrase")
      pass2=$(gum input --password --placeholder "again")
      [ "$pass" = "$pass2" ] && [ ${#pass} -ge 8 ] && break
      warn "They did not match, or it is shorter than 8 characters. Again."
    done
  fi
  [ -n "$pass" ] || die "the kit's passphrase is empty."
  KIT_KEY="$key" KIT_PASS="$pass"
  pass="" pass2=""
  KIT_GATHERED=1
  note "Repo $SOURCE, machine '$HOST', age key from $AGE_KEY$([ -n "$SSH_KEY" ] && echo ", ssh key $SSH_KEY")."
}

kit_apply() {
  read_data_region
  # In the same run as `write`, exactly where write left the space.
  [ -z "$WRITE_START" ] || DATA_START=$WRITE_START DATA_SIZE=$(( $(size_of "$TARGET") - WRITE_START ))
  local start="$DATA_START" size="$DATA_SIZE"
  [ "$size" -ge $((KIT_IMAGE_MIB * 1048576)) ] || die "there are fewer than the ${KIT_IMAGE_MIB} MiB a kit needs after the ISO on $TARGET."
  local key="$KIT_KEY" pass="$KIT_PASS"

  # Build the kit in tmpfs, encrypt it there, then write it: no mapping, no
  # mount, and the plaintext never reaches the stick.
  mkdir -m 0700 "$WORK/kit"
  (umask 077; printf '%s\n' "$key" > "$WORK/kit/age.key")
  [ -n "$SSH_KEY" ] && install -m 0600 "$SSH_KEY" "$WORK/kit/ssh-key"
  jq -n --arg s "$SOURCE" --arg h "$HOST" --arg p "$REPO_PATH" \
    '{"install:mode": "restore", "restore:source": $s, "restore:host": $h}
     + (if $p == "" then {} else {"restore:repoPath": $p} end)' > "$WORK/kit/restore.json"

  truncate -s "${KIT_IMAGE_MIB}M" "$WORK/kit.img"
  mkfs.ext4 -q -L wabisabi-kit -d "$WORK/kit" "$WORK/kit.img" "${KIT_FS_MIB}M" >/dev/null \
    || die "could not build the kit's filesystem."
  note "Encrypting it (a few seconds: the passphrase is stretched with argon2id)"
  printf '%s' "$pass" | cryptsetup reencrypt --encrypt --type luks2 --reduce-device-size 16M \
    --label "$KIT_LABEL" --key-file - -q --disable-locks "$WORK/kit.img" >/dev/null \
    || die "could not encrypt the kit."
  pass="" KIT_PASS=""
  [ "$(blkid -p -o value -s LABEL "$WORK/kit.img")" = "$KIT_LABEL" ] || die "the encrypted kit has no $KIT_LABEL label."

  clear_data_start "$start" 32
  dd if="$WORK/kit.img" of="$TARGET" bs=1M seek="$start" oflag=seek_bytes conv=notrunc,fsync status=none
  sync
  kit_present || die "the kit did not read back from $TARGET."

  echo "WABISABI_USB_KIT target=$TARGET host=$HOST"
  bold "The restore kit is on $TARGET."
  note "It holds: $SOURCE, machine '$HOST'$([ -n "$REPO_PATH" ] && echo ", into $REPO_PATH"), your age key$([ -n "$SSH_KEY" ] && echo " and $(basename "$SSH_KEY")")."
  note "Boot from the stick and run: sudo wabisabi-install. It finds the kit, asks its passphrase, and offers to erase it once the machine is back."
}

do_kit() {
  need_root_for_device
  check_target
  read_data_region
  heading "A restore kit on $TARGET"
  if kit_present; then
    warn "$TARGET already holds a restore kit; it will be replaced."
    if [ "$ASSUME_YES" != 1 ]; then gum confirm "Replace it?" || die "kept the existing kit."; fi
  fi
  kit_gather
  kit_apply
}

# ── wipe and show ─────────────────────────────────────────────────────────

do_wipe() {
  need_root_for_device
  local start
  if ! start=$(kit_scan "$TARGET"); then
    note "No restore kit on $TARGET."
    return 0
  fi
  if [ "$ASSUME_YES" != 1 ]; then
    gum confirm "Erase the restore kit on $TARGET?" || die "kept it."
  fi
  clear_data_start "$start" 32
  sync
  if kit_present; then die "the kit is still readable on $TARGET."; fi
  echo "WABISABI_USB_WIPED target=$TARGET"
  bold "The restore kit on $TARGET is erased."
  note "Its header and keyslots are overwritten, so what remains cannot be decrypted. A stick's flash may still hold stale copies of erased blocks, out of reach of any write: that is why the kit was encrypted."
}

do_show() {
  if ! is_file_target; then lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL "$TARGET" || true; fi
  local end off
  end=$(image_end_bytes "$TARGET")
  if [ "$end" = 0 ]; then
    note "No installer ISO on it."
    return 0
  fi
  note "An installer image of $((end / 1048576)) MiB, then $(( ($(size_of "$TARGET") - end) / 1048576 )) MiB free."
  if off=$(kit_scan "$TARGET"); then
    bold "A restore kit is on it, at $((off / 1048576)) MiB."
  else
    note "No restore kit on it."
  fi
}

case "$cmd" in
  write) do_write ;;
  kit) do_kit ;;
  wipe) do_wipe ;;
  show) do_show ;;
  *) die "unknown command '$cmd' (wabisabi-usb --help)" ;;
esac
