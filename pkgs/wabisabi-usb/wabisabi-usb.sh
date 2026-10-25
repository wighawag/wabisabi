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
# THE LAYOUT. `write` copies the ISO to the stick byte for byte, then adds one
# partition in the space after it. The ISO itself is not changed, apart from
# the one partition-table entry that names the new partition, so the stick
# boots exactly as the ISO does.
#
# THE RESTORE KIT is that partition, encrypted (LUKS2, labelled
# WABISABI-DATA) with a passphrase you choose, holding the answers a restore
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
KIT_LABEL=WABISABI-DATA
# The kit's container: small, because it holds a few small files. The LUKS2
# header takes 16 MiB of it.
KIT_IMAGE_MIB=64
KIT_FS_MIB=40
# Space the data partition must have at least.
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

# The data partition: the one wabisabi-usb added, after the ISO. Prints
# "<start-byte> <size-bytes>".
data_partition() {
  local json
  json=$(sfdisk -J "$TARGET" 2>/dev/null) || die "$TARGET has no partition table. Was it written with wabisabi-usb write?"
  jq -r --arg t "$TARGET" '
    .partitiontable as $pt
    | ($pt.sectorsize // 512) as $ss
    | [$pt.partitions[] | select(.type == "83")] | sort_by(.start) | last
    | if . == null then empty else "\(.start * $ss) \(.size * $ss)" end' <<<"$json"
}

# Sets DATA_START and DATA_SIZE (bytes), or dies. Not a $(...) helper: a die
# inside a command substitution only ends the subshell.
read_data_partition() {
  local p
  p=$(data_partition)
  [ -n "$p" ] || die "$TARGET has no data partition. Write the stick with: wabisabi-usb write $TARGET --iso ..."
  read -r DATA_START DATA_SIZE <<<"$p"
}

kit_present() {
  local start
  read -r start _ <<<"$(data_partition)"
  [ -n "$start" ] || return 1
  [ "$(blkid -p -O "$start" -o value -s LABEL "$TARGET" 2>/dev/null || true)" = "$KIT_LABEL" ]
}

# Zero the first bytes of the data partition: an old kit's header, or any
# other signature, must not survive a rewrite.
clear_data_start() {
  local start="$1" mib="${2:-32}"
  dd if=/dev/zero of="$TARGET" bs=1M count="$mib" seek="$start" oflag=seek_bytes conv=notrunc,fsync status=none
}

reread() {
  if ! is_file_target; then
    blockdev --rereadpt "$TARGET" 2>/dev/null || partx -u "$TARGET" 2>/dev/null || true
    udevadm settle 2>/dev/null || true
  fi
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
  [ -n "$RELEASE" ] && fetch_release "$RELEASE"
  [ -r "$ISO" ] || die "cannot read '$ISO'."

  local iso_bytes dev_bytes start
  iso_bytes=$(size_of "$ISO")
  dev_bytes=$(size_of "$TARGET")
  # The data partition starts on the first MiB boundary after the ISO.
  start=$(( (iso_bytes + 1048575) / 1048576 * 1048576 ))
  if [ $((dev_bytes - start)) -lt $((MIN_DATA_MIB * 1048576)) ]; then
    die "$TARGET ($((dev_bytes / 1048576)) MiB) is too small for this ISO ($((iso_bytes / 1048576)) MiB) plus a ${MIN_DATA_MIB} MiB data partition."
  fi

  heading "Writing $(basename "$ISO") to $TARGET"
  if is_file_target; then
    note "$TARGET is an image file; it is overwritten, not resized."
  else
    confirm_destruction "$TARGET"
  fi

  dd if="$ISO" of="$TARGET" bs=4M conv=notrunc,fsync status=progress
  # The ISO's own partition table must end inside the ISO, or the new
  # partition would overlap something it carries.
  local last_end
  last_end=$(sfdisk -J "$TARGET" 2>/dev/null | jq '[.partitiontable.partitions[]? | .start + .size] | max // 0')
  [ $((last_end * 512)) -le "$start" ] || die "the ISO's partition table reaches past its own end; refusing to add a partition to it."

  # Cleared BEFORE the partition is added: an earlier kit at the same place
  # would otherwise survive the rewrite (and make sfdisk stop to ask).
  clear_data_start "$start"
  echo "start=$((start / 512)), type=83" | sfdisk --quiet --append --no-reread --no-tell-kernel "$TARGET" >/dev/null \
    || die "could not add the data partition."
  sync
  reread

  # Proof that the ISO is intact: every byte outside the partition table
  # entries (MBR bytes 446..509) matches the ISO.
  if cmp -s -n 446 "$ISO" "$TARGET" && cmp -s -i 510 -n $((iso_bytes - 510)) "$ISO" "$TARGET"; then
    note "Verified: the ISO on $TARGET is byte-identical to $(basename "$ISO") outside the partition table."
  else
    die "the stick does not read back as the ISO. Try another stick, or write again."
  fi
  echo "WABISABI_USB_WRITTEN target=$TARGET data_start=$start"
  bold "$TARGET boots the installer, with $(( (dev_bytes - start) / 1048576 )) MiB free after it for a restore kit."

  if [ "$WITH_KIT" = 1 ]; then
    do_kit
  elif [ "$ASSUME_YES" != 1 ] && gum confirm --default=false "Put a restore kit on it now (your config repo and keys, encrypted)?"; then
    do_kit
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

do_kit() {
  need_root_for_device
  check_target
  read_data_partition
  local start="$DATA_START" size="$DATA_SIZE"
  [ "$size" -ge $((KIT_IMAGE_MIB * 1048576)) ] || die "the data partition is smaller than the ${KIT_IMAGE_MIB} MiB a kit needs."

  heading "A restore kit"
  if kit_present; then
    warn "$TARGET already holds a restore kit; it will be replaced."
    if [ "$ASSUME_YES" != 1 ]; then gum confirm "Replace it?" || die "kept the existing kit."; fi
  fi

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
  [ -r "$AGE_KEY" ] || die "no age key at $AGE_KEY. Give --age-key FILE."
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
  pass="" pass2=""
  [ "$(blkid -p -o value -s LABEL "$WORK/kit.img")" = "$KIT_LABEL" ] || die "the encrypted kit has no $KIT_LABEL label."

  clear_data_start "$start" 32
  dd if="$WORK/kit.img" of="$TARGET" bs=1M seek="$start" oflag=seek_bytes conv=notrunc,fsync status=none
  sync
  reread
  kit_present || die "the kit did not read back from $TARGET."

  echo "WABISABI_USB_KIT target=$TARGET host=$HOST"
  bold "The restore kit is on $TARGET."
  note "It holds: $SOURCE, machine '$HOST'$([ -n "$REPO_PATH" ] && echo ", into $REPO_PATH"), your age key$([ -n "$SSH_KEY" ] && echo " and $(basename "$SSH_KEY")")."
  note "Boot from the stick and run: sudo wabisabi-install. It finds the kit, asks its passphrase, and offers to erase it once the machine is back."
}

# ── wipe and show ─────────────────────────────────────────────────────────

do_wipe() {
  need_root_for_device
  read_data_partition
  local start="$DATA_START"
  if ! kit_present; then
    note "No restore kit on $TARGET."
    return 0
  fi
  if [ "$ASSUME_YES" != 1 ]; then
    gum confirm "Erase the restore kit on $TARGET?" || die "kept it."
  fi
  clear_data_start "$start" 32
  sync
  reread
  if kit_present; then die "the kit is still readable on $TARGET."; fi
  echo "WABISABI_USB_WIPED target=$TARGET"
  bold "The restore kit on $TARGET is erased."
  note "Its header and keyslots are overwritten, so what remains cannot be decrypted. A stick's flash may still hold stale copies of erased blocks, out of reach of any write: that is why the kit was encrypted."
}

do_show() {
  if ! is_file_target; then lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL "$TARGET" || true; fi
  local p
  p=$(data_partition)
  if [ -z "$p" ]; then
    note "No data partition: not written with wabisabi-usb."
    return 0
  fi
  local start size
  read -r start size <<<"$p"
  note "Data partition: $((size / 1048576)) MiB at $((start / 1048576)) MiB."
  if kit_present; then bold "A restore kit is on it."; else note "No restore kit on it."; fi
}

case "$cmd" in
  write) do_write ;;
  kit) do_kit ;;
  wipe) do_wipe ;;
  show) do_show ;;
  *) die "unknown command '$cmd' (wabisabi-usb --help)" ;;
esac
