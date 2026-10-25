#!/usr/bin/env bash
# wabisabi-install: ask, partition, install, get out of the way.
#
# The questions come from installer/questions.json, which is generated from
# the option declarations in modules/options.nix and home/options.nix, so this
# script knows nothing about what wabisabi's options ARE. It renders whatever
# it is handed. Adding an option to the API adds a question here with no edit
# to this file.
#
# Everything it writes to the target goes through installer/emit.sh, which
# fills in template/ -- the same template `nix flake new` scaffolds by hand.
#
#   wabisabi-install                          interactive
#   wabisabi-install --answers answers.json   unattended, same questions
#   wabisabi-install --out-only DIR           just write the flake, touch no disk
#
# A RESTORE KIT (made by `wabisabi-usb kit`) is an encrypted partition on the
# installer's own USB stick holding the restore answers and keys. Without
# --answers, the installer looks for one and offers to restore from it.
#
#   --kit DEV|auto              use the kit on the stick DEV (auto: look on the
#                               boot stick, then on any USB disk)
#   --no-kit                    do not look for one
#   --kit-passphrase-file FILE  its passphrase, for an unattended run
#   --wipe-kit                  erase the kit after a successful install
#                               (asked otherwise, unless --yes)
#
set -euo pipefail

: "${WABISABI_QUESTIONS:?internal: questions.json path not baked in}"
: "${WABISABI_APPLIES:?internal: applies.jq path not baked in}"
: "${WABISABI_TEMPLATE:?internal: template path not baked in}"
: "${WABISABI_EMIT:?internal: emit.sh path not baked in}"
: "${WABISABI_LOCK:?internal: flake.lock path not baked in}"
: "${WABISABI_URL:?internal: wabisabi input url not baked in}"
: "${WABISABI_DISKO:?internal: disko layout dir not baked in}"
: "${WABISABI_NIXPKGS:?internal: nixpkgs source path not baked in}"
: "${WABISABI_DISKS_LIB:?internal: disks.sh path not baked in}"

# disko resolves `<nixpkgs>` when it evaluates a layout. Point it at the
# sources on this medium rather than at whatever the environment happens to
# say, which in a systemd unit is nothing at all.
export NIX_PATH="nixpkgs=$WABISABI_NIXPKGS${NIX_PATH:+:$NIX_PATH}"
: "${WABISABI_STATE_VERSION:?internal: state version not baked in}"
WABISABI_OFFLINE="${WABISABI_OFFLINE:-0}"

ANSWERS_IN="" OUT_ONLY="" ASSUME_YES=0 TARGET=/mnt NO_REBOOT=0
KIT_ARG="" KIT_PASSFILE="" WIPE_KIT=0

while [ $# -gt 0 ]; do
  case "$1" in
    --answers) ANSWERS_IN="$2"; shift 2 ;;
    --out-only) OUT_ONLY="$2"; shift 2 ;;
    --target) TARGET="$2"; shift 2 ;;
    --yes|-y) ASSUME_YES=1; shift ;;
    --no-reboot) NO_REBOOT=1; shift ;;
    --offline) WABISABI_OFFLINE=1; shift ;;
    --kit) KIT_ARG="$2"; shift 2 ;;
    --no-kit) KIT_ARG=none; shift ;;
    --kit-passphrase-file) KIT_PASSFILE="$2"; shift 2 ;;
    --wipe-kit) WIPE_KIT=1; shift ;;
    --debug) set -x; shift ;;
    -h|--help)
      sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) echo "wabisabi-install: unknown argument '$1'" >&2; exit 2 ;;
  esac
done

# ── output helpers ────────────────────────────────────────────────────────

# `--` before the text in every one of these: the messages are prose, and
# prose that begins with a word like "--yes" is otherwise parsed by gum as a
# flag, which turns an informational line into a failed install.
bold() { gum style --bold -- "$*"; }
note() { gum style --foreground 244 -- "$*"; }
warn() { gum style --foreground 214 -- "$*"; }
die() { gum style --foreground 196 --bold -- "error: $*" >&2; exit 1; }
heading() { echo; gum style --bold --foreground 141 -- "── $* ──"; }

# /run is tmpfs, so the LUKS passphrase never touches a real filesystem. On
# the ISO /tmp is tmpfs too, but this also runs on ordinary NixOS hosts where
# it is not, and a passphrase written to disk and then unlinked is still a
# passphrase written to disk.
WORK=$(mktemp -d -p /run 2>/dev/null || mktemp -d)
chmod 700 "$WORK"

# Set the moment the disk is handed to disko, so a later failure can say so.
DISK_TOUCHED=0

# Where a restore kit is opened, briefly: OUTSIDE $WORK, because $WORK is
# removed with rm -rf on exit and a mount inside it would be removed with it.
KIT_MAPPER=wabisabi-kit
KIT_MNT=/run/wabisabi-kit

on_exit() {
  local code=$?
  if mountpoint -q "$KIT_MNT" 2>/dev/null; then umount "$KIT_MNT" || true; fi
  if [ -e "/dev/mapper/$KIT_MAPPER" ]; then cryptsetup close "$KIT_MAPPER" || true; fi
  if [ -n "${KIT_LOOP:-}" ]; then losetup -d "$KIT_LOOP" 2>/dev/null || true; fi
  # The work directory holds the LUKS passphrase while disko formats. Remove
  # it on every exit path, successful or not.
  rm -rf "$WORK"
  if [ "$code" -ne 0 ]; then
    echo
    warn "wabisabi-install stopped (exit $code)."
    if [ "$DISK_TOUCHED" = 1 ]; then
      # Every other abort path says "no disk was touched", which teaches the
      # reader that silence means safety. Past this point it does not.
      warn "${device:-the target disk} HAS ALREADY BEEN PARTITIONED AND FORMATTED."
      warn "Whatever was on it before is gone, and it is not yet a bootable system."
    fi
  fi
  exit $code
}
trap on_exit EXIT INT TERM HUP

# ── answers ───────────────────────────────────────────────────────────────

declare -A ANSWER=()
ANSWER_ORDER=()

# Whether the user walked through wabisabi's own options. Declared here
# because the --answers path never enters the interactive loop, and `set -u`
# turns an unset variable into a crash rather than an empty string.
reviewed=0

set_answer() {
  local key="$1" value="$2"
  if [ -z "${ANSWER[$key]+set}" ]; then ANSWER_ORDER+=("$key"); fi
  ANSWER[$key]="$value"
}

get_answer() { echo "${ANSWER[$1]:-}"; }

# Answers that came from a restore kit: the question loop does not ask them
# again, and asks everything the kit left out (a disk, for a config that
# does not declare its own) as usual.
declare -A PREFILLED=()

# THE INSTALLER'S OWN QUESTIONS NEED THEIR DEFAULTS WRITTEN DOWN, and this is
# the one place where "unanswered means it follows wabisabi" is NOT true.
#
# A wabisabi option left unanswered is simply absent from the generated
# config, so the machine keeps tracking the project's default -- which is the
# behaviour the summary promises. But `extra:` items are the installer's own
# (firmware, early-KMS modules): wabisabi has no opinion to fall back to, so
# silence there means the bare NixOS default. Skipping the option review used
# to leave `hardware.enableRedistributableFirmware` unset, which is `false`,
# which is a laptop that installed over wifi and then has no wifi.
apply_installer_defaults() {
  local key kind default
  while IFS=$'\t' read -r key kind default; do
    # secrets:mode too: an answers file written before secrets existed gets
    # the recommended setup, the same as pressing enter at the question.
    case "$key" in extra:*|secrets:mode|install:mode) ;; *) continue ;; esac
    [ -z "${ANSWER[$key]+set}" ] || continue

    if [ "$key" = "extra:initrdKernelModules" ]; then
      default=$(detect_drm_modules)
    fi
    [ -n "$default" ] || continue
    set_answer "$key" "$default"
  done < <(jq -r '.groups[].items[] | select(.emit != null or .key == "secrets:mode" or .key == "install:mode") | "\(.key)\t\(.kind)\t\(.default // "")"' "$WABISABI_QUESTIONS")
}

# Which answers are secrets is read from the QUESTION DEFINITIONS, not from a
# hardcoded list of key names. The whole point of questions.nix is that new
# questions appear here without editing this script, so a new password-kind
# question must not need someone to remember to add it to a `case` before it
# stops being written to a world-readable file on the installed machine.
mapfile -t SECRET_KEYS < <(jq -r '.groups[].items[] | select(.kind == "password" or .kind == "agekey") | .key' "$WABISABI_QUESTIONS")

is_secret() {
  local key="$1" secret
  for secret in "${SECRET_KEYS[@]}"; do
    [ "$key" = "$secret" ] && return 0
  done
  return 1
}

answers_json() {
  local key
  {
    echo "{}"
    for key in "${ANSWER_ORDER[@]}"; do
      # Passwords never reach a file.
      is_secret "$key" && continue
      jq -n --arg k "$key" --arg v "${ANSWER[$key]}" '{($k): $v}'
    done
  } | jq -s 'add'
}

q() { jq -r "$@" "$WABISABI_QUESTIONS"; }

# ── the question loop ─────────────────────────────────────────────────────

ask_item() {
  local item="$1"
  local key kind prompt help default values
  key=$(jq -r '.key' <<<"$item")
  kind=$(jq -r '.kind' <<<"$item")
  prompt=$(jq -r '.prompt' <<<"$item")
  help=$(jq -r '.help // ""' <<<"$item")
  default=$(jq -r '.default // ""' <<<"$item")

  # Already answered by a restore kit.
  [ -z "${PREFILLED[$key]+set}" ] || return 0

  # Conditional questions (the LUKS passphrase only exists for the LUKS
  # layout, the recipe set only for a backend that uses one). The rule is
  # applies.jq, shared with the flake check that tests it; it is handed the
  # answers its conditions name, and nothing else.
  local cond_key known='{}'
  while IFS= read -r cond_key; do
    [ -n "$cond_key" ] || continue
    known=$(jq --arg k "$cond_key" --arg v "$(get_answer "$cond_key")" '. + {($k): $v}' <<<"$known")
  done < <(jq -r '(.onlyIf // []) | if type == "object" then [.] else . end | .[].key' <<<"$item")
  jq -e --argjson answers "$known" -f "$WABISABI_APPLIES" <<<"$item" >/dev/null || return 0

  echo
  bold "$prompt"
  [ -n "$help" ] && note "$help"

  case "$kind" in
    text)
      # `pattern` comes from a strMatching option (whole-string, as Nix
      # matches it); `required` from a field that cannot be left half done.
      local value pattern required
      pattern=$(jq -r '.pattern // ""' <<<"$item")
      required=$(jq -r '.required // false' <<<"$item")
      while true; do
        value=$(gum input --value "$default" --placeholder "$default")
        if [ -z "$value" ]; then
          [ "$required" = true ] || break
          warn "This one cannot be left empty. Again."
        elif [ -n "$pattern" ] && ! [[ "$value" =~ ^($pattern)$ ]]; then
          warn "That does not have the expected form ($pattern). Again."
        else
          break
        fi
      done
      set_answer "$key" "$value"
      ;;
    password)
      local a b
      # --debug turns on `set -x`, which would otherwise trace the passphrase
      # itself to stderr, and under the unattended unit stderr is the journal
      # and the serial console. Trace nothing in here, then restore.
      local xtrace=0
      case "$-" in *x*) xtrace=1; set +x ;; esac
      while true; do
        a=$(gum input --password --placeholder "password")
        b=$(gum input --password --placeholder "again")
        [ "$a" = "$b" ] && [ -n "$a" ] && break
        warn "They did not match, or were empty. Again."
      done
      set_answer "$key" "$a"
      [ "$xtrace" = 1 ] && set -x
      ;;
    agekey)
      # Once, hidden, and checked on the spot: a mistyped key is only
      # otherwise discovered when the installed machine cannot decrypt its
      # own password.
      local k optional
      optional=$(jq -r '.optional // false' <<<"$item")
      local xtrace=0
      case "$-" in *x*) xtrace=1; set +x ;; esac
      while true; do
        k=$(gum input --password --placeholder "AGE-SECRET-KEY-1...")
        k=$(tr -d '[:space:]' <<<"$k")
        valid_age_key "$k" && break
        [ -z "$k" ] && [ "$optional" = true ] && break
        warn "That is not an age secret key (one line, starting AGE-SECRET-KEY-1). Again."
      done
      set_answer "$key" "$k"
      [ "$xtrace" = 1 ] && set -x
      ;;
    bool)
      local value
      if gum confirm --default="$([ "$default" = "true" ] && echo true || echo false)" "Enable?"; then
        value=true
      else
        value=false
      fi
      set_answer "$key" "$value"
      ;;
    enum)
      local value
      mapfile -t values < <(jq -r '.values[]' <<<"$item")
      value=$(gum choose --selected "$default" "${values[@]}")
      set_answer "$key" "$value"
      ;;
    strlist)
      local value required
      required=$(jq -r '.required // false' <<<"$item")
      while true; do
        if [ "$required" = true ]; then
          value=$(gum input --value "$default" --placeholder "space separated")
        else
          value=$(gum input --value "$default" --placeholder "space separated, may be empty")
        fi
        [ "$required" = true ] && [ -z "${value// /}" ] || break
        warn "This one cannot be left empty. Again."
      done
      set_answer "$key" "$value"
      ;;
    device)
      pick_device "$key"
      ;;
    *)
      die "question '$key' has kind '$kind', which this installer does not know how to ask."
      ;;
  esac
}

valid_age_key() {
  [[ "$1" =~ ^AGE-SECRET-KEY-1[0-9A-Z]{58}$ ]] && age-keygen -y <(printf '%s\n' "$1") >/dev/null 2>&1
}

# ── disks ─────────────────────────────────────────────────────────────────

# live_disk, check_device_safe and confirm_destruction, shared with
# wabisabi-usb so the two tools cannot disagree about the wrong disk.
# shellcheck disable=SC1090
source "$WABISABI_DISKS_LIB"


pick_device() {
  local key="$1" live choice device
  local -a disks labelled
  live=$(live_disk || true)

  mapfile -t disks < <(lsblk -dpno NAME,SIZE,MODEL,TYPE | awk '$NF == "disk"')
  [ "${#disks[@]}" -gt 0 ] || die "no disks found to install onto."

  local line name
  for line in "${disks[@]}"; do
    name=$(awk '{print $1}' <<<"$line")
    if [ -n "$live" ] && [ "$(basename "$name")" = "$live" ]; then
      labelled+=("$line   [the live medium you booted]")
    else
      labelled+=("$line")
    fi
  done

  choice=$(gum choose "${labelled[@]}")
  device=$(awk '{print $1}' <<<"$choice")
  set_answer "$key" "$device"
}

# ── the installer's own keyboard ───────────────────────────────────────────

keymap_applied=0
keymap_failed=0
apply_keymap() {
  # Switch the live console to the layout just chosen, BEFORE anything asks
  # for a LUKS passphrase. Otherwise the passphrase is typed on a US console,
  # stored, and then demanded at the next boot by an initrd running the
  # chosen layout -- an unbootable machine, created by the installer, with no
  # hint as to why.
  local layout variant
  [ "$keymap_applied" = 1 ] && return 0
  layout=$(get_answer "system:keyboard.layout")
  [ -n "$layout" ] || return 0
  variant=$(get_answer "system:keyboard.variant")
  keymap_applied=1

  # Build the argument list properly. This line previously read
  #   ckbcomp "$layout" ''${variant:+"$variant"}
  # which is Nix escaping that means nothing to bash: it passed an EMPTY
  # third argument whenever no variant was chosen, so the common case could
  # fail and fall through to the warning below.
  local -a args=("$layout")
  [ -n "$variant" ] && args+=("$variant")

  if ckbcomp "${args[@]}" 2>/dev/null | loadkeys - 2>/dev/null; then
    note "Console keyboard switched to '$layout${variant:+ ($variant)}'."
    return 0
  fi

  # Remembered rather than fatal here, because the layout is chosen BEFORE the
  # disk questions: at this point we do not yet know whether a passphrase is
  # coming. The check that matters happens before anything is partitioned.
  keymap_failed=1
  warn "Could not switch the console to '$layout'. Anything you type now uses the current layout."
}

# ── hardware detection ────────────────────────────────────────────────────

# The live session's keyboard, as systemd-localed has it (Layout, Variant).
# Empty when localed is not there to ask.
live_x11() {
  { localectl status 2>/dev/null || true; } | sed -n "s/^ *X11 $1: //p" | head -n 1 || true
}

detect_drm_modules() {
  # Early KMS for the Plymouth splash. This is hardware knowledge, so it
  # belongs to the machine's own config rather than to wabisabi's modules;
  # the installer is the one place that can see the actual hardware.
  local d driver out=()
  for d in /sys/class/drm/card*/device/driver; do
    [ -e "$d" ] || continue
    driver=$(basename "$(readlink -f "$d")")
    case "$driver" in
      amdgpu|i915|xe|nouveau|radeon|virtio_gpu|ast|mgag200)
        out+=("$driver")
        ;;
    esac
  done
  printf '%s\n' "${out[@]:-}" | sort -u | tr '\n' ' ' | sed 's/ *$//'
}

# ── restore: read the answers out of an existing config repo ───────────────

# A restore installs a config that already exists, so identity, keyboard,
# secrets, disks and every option come FROM the repo. The rule throughout:
# follow what the config DECLARES, and fall back to the installer's own way
# (its disk layouts, its key locations, asking for a password) only where the
# config says nothing. That is what lets one restore serve both a repo the
# installer made and a fleet repo in which this machine is one host of many.
#
# Everything here runs before any disk is touched: a repo that will not clone
# or evaluate, a key that does not open its secrets, or a config whose disks
# the installer cannot account for, stops the install with nothing
# partitioned.
install_mode=fresh
restore_ready=0
RESTORE_CLONE="" RESTORE_HOST="" RESTORE_REPO_PATH="" RESTORE_KEYFILE_PATH=""
RESTORE_PW_FROM_SECRETS=0 RESTORE_PW_DECLARED=0 RESTORE_DISKO=0 RESTORE_TEMPLATE_SECRETS=0
RESTORE_DISKS=()
# Further keys a restore kit carried, tried after restore:ageKey.
RESTORE_EXTRA_KEYS=()

restore_eval_in() {
  local src="$1" attr="$2" fn="$3"
  local -a flags=(--extra-experimental-features "nix-command flakes" --json --no-write-lock-file)
  [ "$WABISABI_OFFLINE" = 1 ] && flags+=(--offline)
  nix eval "${flags[@]}" "path:$src#$attr" --apply "$fn"
}
restore_eval() { restore_eval_in "$RESTORE_CLONE" "$@"; }

# Decrypt one sops file (or one value in it) with the key given for the
# restore, to stdout.
restore_decrypt() {
  local file="$1" format="$2" extract="${3:-}"
  local -a args=(decrypt --input-type "$format")
  [ "$format" = binary ] && args+=(--output-type binary)
  [ -n "$extract" ] && args+=(--extract "$extract")
  SOPS_AGE_KEY_FILE="$WORK/age.key" sops "${args[@]}" "$file"
}

restore_prepare() {
  restore_ready=1
  local source host facts key ssh_key

  # FETCHING OVER SSH. A private repo, or a public one pinned as git+ssh
  # (a fleet flake often pins its inputs that way), needs a key the ISO
  # does not have. One key covers both: git uses GIT_SSH_COMMAND, and so does
  # nix's git fetcher for flake inputs (checked: a sentinel command in it is
  # what `nix flake metadata git+ssh://...` runs). The key stays in $WORK, on
  # tmpfs, and is never copied to the new disk. accept-new, because the
  # installer has never seen github.com's host key and has nobody to ask.
  ssh_key=$(get_answer "restore:sshKeyFile")
  if [ -n "$ssh_key" ]; then
    [ -f "$ssh_key" ] || die "restore:sshKeyFile '$ssh_key' does not exist."
    install -m 0600 "$ssh_key" "$WORK/ssh_key"
    : > "$WORK/known_hosts"
    export GIT_SSH_COMMAND="ssh -i $WORK/ssh_key -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=$WORK/known_hosts"
  fi

  source=$(get_answer "restore:source")
  [ -n "$source" ] || die "a restore needs restore:source, the repo to restore from."

  heading "Fetching your config"
  RESTORE_CLONE="$WORK/restore"
  # safe.directory='*': git refuses to clone a LOCAL repo owned by another
  # user, which is every repo on a USB stick formatted with the owner's uid
  # (and a store path, in the VM test). The source is the one the person at
  # the keyboard named, and cloning only reads it.
  git -c safe.directory='*' clone -q -- "$source" "$RESTORE_CLONE" \
    || die "could not clone '$source'. Nothing was touched. (Network up? Private repo: give restore:sshKeyFile, or a token in an https URL.)"
  [ -f "$RESTORE_CLONE/flake.nix" ] || die "'$source' has no flake.nix at its top. Nothing was touched."
  [ -f "$RESTORE_CLONE/flake.lock" ] || warn "The repo has no flake.lock, so its inputs resolve to whatever is current today."

  local -a hosts
  mapfile -t hosts < <(restore_eval nixosConfigurations builtins.attrNames | jq -r '.[]') \
    || die "could not evaluate the repo's flake. Nothing was touched."
  [ "${#hosts[@]}" -gt 0 ] || die "the repo defines no nixosConfigurations."

  host=$(get_answer "restore:host")
  if [ -z "$host" ]; then
    if [ "${#hosts[@]}" = 1 ]; then
      host="${hosts[0]}"
    elif [ -z "$ANSWERS_IN" ]; then
      bold "The repo has several machines. Which one is this?"
      host=$(gum choose "${hosts[@]}")
    else
      die "the repo has several machines (${hosts[*]}); set restore:host."
    fi
  fi
  printf '%s\n' "${hosts[@]}" | grep -qxF -- "$host" \
    || die "the repo has no machine '$host' (it has: ${hosts[*]})."
  RESTORE_HOST="$host"

  heading "Reading $host"
  note "Evaluating the config (a minute, and it may download the sources it pins)."
  # Single-quoted on purpose: ${user} and friends are NIX interpolation.
  # shellcheck disable=SC2016
  facts=$(restore_eval "nixosConfigurations.$host.config" 'c: let
    user = c.wabisabi.user or "";
    u = c.users.users.${user} or { };
    secrets = builtins.attrValues (c.sops.secrets or { });
    # tryEval, not `or`: sops.defaultSopsFile has NO default, so a config that
    # never sets it (every secret naming its own file, as a fleet does)
    # throws on access rather than lacking the attribute.
    try = x: let r = builtins.tryEval x; in if r.success then r.value else null;
    defaultFile = try (toString (c.sops.defaultSopsFile or null));
    firstFile = if secrets == [ ] then null else try (toString (builtins.head secrets).sopsFile);
    first = if secrets == [ ] then null else builtins.head secrets;
  in {
    inherit user;
    hostName = c.networking.hostName;
    repoPath = if c.environment.etc ? nixos then toString c.environment.etc.nixos.source else "";
    layout = c.services.xserver.xkb.layout;
    variant = c.services.xserver.xkb.variant;
    keyFile = c.sops.age.keyFile or null;
    templateSecrets = (c.wabisabi.secrets.sopsFile or null) != null;
    # One file the given key must open: the default secrets file, else the
    # first declared secret. Proves the key before the disk is touched.
    probeFile = if defaultFile != null && defaultFile != "" then defaultFile
      else if firstFile != null then firstFile else "";
    probeFormat = if defaultFile != null && defaultFile != "" then (c.sops.defaultSopsFormat or "yaml")
      else if first != null then first.format else "yaml";
    passwordFromSecrets = (c.wabisabi.secrets.sopsFile or null) != null
      && (c.wabisabi.secrets.ownerPassword or false) && user != "";
    passwordDeclared = builtins.any (a: (u.${a} or null) != null)
      [ "hashedPasswordFile" "hashedPassword" "password" "initialHashedPassword" "initialPassword" ];
    disks = map (d: d.device) (builtins.attrValues (c.disko.devices.disk or { }));
    files = builtins.mapAttrs (_: f: {
      sopsFile = toString f.sopsFile;
      inherit (f) format mode;
      extract = if f.extract == null then "" else f.extract;
    }) (c.wabisabi.restore.files or { });
  }') || die "could not evaluate nixosConfigurations.$host. Nothing was touched."

  # The whole system, evaluated, so its assertions run NOW. A config that
  # fails one (a module the new pins reject, a check on a name) otherwise
  # fails at the build step, after this disk has been wiped. This only
  # evaluates; nothing is built or downloaded beyond the sources.
  note "Checking that it evaluates as a whole system."
  restore_eval "nixosConfigurations.$host.config.system.build.toplevel.drvPath" 'x: x' >/dev/null \
    || die "'$host' does not evaluate (the error is above). Nothing was touched."

  local user
  user=$(jq -r .user <<<"$facts")
  [ -n "$user" ] || die "'$host' does not name its owner (wabisabi.user), so there is no account to restore the repo into."
  set_answer "identity:hostname" "$(jq -r .hostName <<<"$facts")"
  set_answer "identity:username" "$user"
  set_answer "system:keyboard.layout" "$(jq -r .layout <<<"$facts")"
  set_answer "system:keyboard.variant" "$(jq -r .variant <<<"$facts")"

  # WHERE THE REPO GOES: as asked, else where the config says it lives (the
  # /etc/nixos link a wabisabi config declares), else the owner's ~/nixos. A
  # fleet repo usually declares no link, and belongs wherever its owner keeps
  # checkouts, which only they know.
  RESTORE_REPO_PATH=$(get_answer "restore:repoPath")
  if [ -z "$RESTORE_REPO_PATH" ]; then
    RESTORE_REPO_PATH=$(jq -r .repoPath <<<"$facts")
    case "$RESTORE_REPO_PATH" in
      /nix/store/*|"") RESTORE_REPO_PATH="/home/$user/nixos" ;;
      /*) ;;
      *) RESTORE_REPO_PATH="/home/$user/nixos" ;;
    esac
  fi
  case "$RESTORE_REPO_PATH" in
    /*) ;;
    *) die "restore:repoPath must be an absolute path (got '$RESTORE_REPO_PATH')." ;;
  esac
  case "/$RESTORE_REPO_PATH/" in
    */../*|*/./*) die "restore:repoPath must not contain . or .. components." ;;
  esac
  RESTORE_KEYFILE_PATH=$(jq -r '.keyFile // ""' <<<"$facts")
  [ "$(jq -r .templateSecrets <<<"$facts")" = true ] && RESTORE_TEMPLATE_SECRETS=1

  # THE DISKS. A config that declares them (disko) is partitioned by that
  # declaration: partitioning it any other way leaves a system whose
  # fileSystems name partitions that do not exist, which evaluates, builds,
  # installs, and does not boot. A config that does not is partitioned by the
  # installer's own layouts ONLY IF its root filesystem demonstrably comes
  # from ./hardware-configuration.nix, the file the restore regenerates.
  # Anything else is refused.
  mapfile -t RESTORE_DISKS < <(jq -r '.disks[]' <<<"$facts")
  if [ "${#RESTORE_DISKS[@]}" -gt 0 ]; then
    RESTORE_DISKO=1
    set_answer "restore:disko" "true"
    set_answer "disk:layout" "disko"
    local d
    for d in "${RESTORE_DISKS[@]}"; do
      [ -b "$d" ] || die "the config partitions $d, which this machine does not have. Change the disk device in the repo, push, and restore again. Nothing was touched."
    done
    note "The config declares its own disks (disko): ${RESTORE_DISKS[*]}. They will be partitioned as it says."
  else
    # Probe: swap in a hardware file naming a disk that cannot exist, and see
    # whether the evaluated root filesystem is that disk.
    local probe="$WORK/probe" probe_dev="/dev/disk/by-uuid/wabisabi-restore-probe"
    cp -a "$RESTORE_CLONE" "$probe"
    cat > "$probe/hardware-configuration.nix" <<EOF
{ lib, ... }: {
  fileSystems."/" = { device = "$probe_dev"; fsType = "ext4"; };
  fileSystems."/boot" = { device = "/dev/disk/by-uuid/PROBE-BOOT"; fsType = "vfat"; };
  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
}
EOF
    if [ "$(restore_eval_in "$probe" "nixosConfigurations.$host.config.fileSystems" 'f: f."/".device' 2>/dev/null | jq -r .)" != "$probe_dev" ]; then
      die "'$host' takes its root filesystem neither from ./hardware-configuration.nix at the top of the repo nor from disko, so the installer cannot know how to partition for it. Nothing was touched."
    fi
    rm -rf "$probe"
  fi

  # THE KEY, proved against the repo's own secrets now rather than
  # discovered at the first boot, when it would be a machine nobody can log
  # into.
  local probe_file probe_format nfiles
  key=$(get_answer "restore:ageKey")
  probe_file=$(jq -r .probeFile <<<"$facts")
  probe_format=$(jq -r .probeFormat <<<"$facts")
  nfiles=$(jq '.files | length' <<<"$facts")
  if [ -n "$key" ]; then
    valid_age_key "$key" || die "restore:ageKey is not a valid age secret key."
    (umask 077; printf '%s\n' "$key" > "$WORK/age.key")
  fi
  if [ -n "$probe_file" ] || [ "$nfiles" -gt 0 ]; then
    [ -s "$WORK/age.key" ] || die "the config has encrypted secrets, and restoring it needs the age key that opens them."
  fi
  if [ -n "$probe_file" ]; then
    # A restore kit may carry SEVERAL keys (a keys.txt holding more than one
    # identity): the one that opens this repo is the one used, and the only
    # one that goes anywhere afterwards.
    local candidate opened=0
    for candidate in "$key" "${RESTORE_EXTRA_KEYS[@]}"; do
      [ -n "$candidate" ] || continue
      valid_age_key "$candidate" || continue
      (umask 077; printf '%s\n' "$candidate" > "$WORK/age.key")
      if restore_decrypt "$probe_file" "$probe_format" >/dev/null 2>&1; then
        opened=1
        set_answer "restore:ageKey" "$candidate"
        break
      fi
    done
    if [ "$opened" = 0 ]; then
      local given wanted
      given=$(for candidate in "$key" "${RESTORE_EXTRA_KEYS[@]}"; do
        [ -n "$candidate" ] && age-keygen -y <(printf '%s\n' "$candidate") 2>/dev/null; done | sort -u | tr '\n' ' ')
      wanted=$(grep -oE 'age1[a-z0-9]{58}' "$probe_file" | sort -u | tr '\n' ' ')
      die "the age key given does not open this repo's secrets ($probe_file). Given: ${given:-none}. That file opens with: ${wanted:-unknown}. Nothing was touched."
    fi
    note "Your key opens the repo's secrets."
  fi

  # FILES TO PLACE BEFORE THE FIRST BOOT (wabisabi.restore.files), each
  # decrypted now, which both proves the key opens it and means nothing can
  # fail between partitioning and placing them. Kept on tmpfs until then.
  : > "$WORK/files.tsv"
  if [ "$nfiles" -gt 0 ]; then
    mkdir -m 0700 "$WORK/files"
    local i=0 path file format extract mode
    # \x1f, not a tab: tab is IFS WHITESPACE, so `read` merges consecutive
    # tabs and an empty field (extract, usually) silently shifts the rest.
    while IFS=$'\x1f' read -r path file format extract mode; do
      case "$path" in
        /*) ;;
        *) die "wabisabi.restore.files: '$path' is not an absolute path." ;;
      esac
      case "/$path/" in */../*) die "wabisabi.restore.files: '$path' contains '..'." ;; esac
      (umask 077; restore_decrypt "$file" "$format" "$extract" > "$WORK/files/$i") \
        || die "the key does not open $file, which the config wants placed at $path. Nothing was touched."
      printf '%s\t%s\t%s\n' "$i" "$path" "$mode" >> "$WORK/files.tsv"
      i=$((i + 1))
    done < <(jq -r '.files | to_entries[] | [.key, .value.sopsFile, .value.format, .value.extract, .value.mode] | join("\u001f")' <<<"$facts")
    note "$nfiles file(s) from the repo will be placed before the first boot: $(cut -f2 "$WORK/files.tsv" | tr '\n' ' ')"
  fi

  # THE PASSWORD: from the repo when it can be, asked only when it cannot.
  if [ "$(jq -r .passwordFromSecrets <<<"$facts")" = true ]; then
    RESTORE_PW_FROM_SECRETS=1
    # What activation will put in /etc/shadow, read now so the install can
    # check afterwards that it did.
    restore_decrypt "$probe_file" yaml '["owner-password"]' > "$WORK/password.hash" 2>/dev/null \
      || die "the repo's secrets have no owner-password, which its config says they do."
    note "Your password comes from the repo, as before."
  elif [ "$(jq -r .passwordDeclared <<<"$facts")" = true ]; then
    # The config sets it its own way (its own sops secret, a hash). Trust
    # that; setting another one here would only be overwritten, or worse,
    # override what the config meant.
    RESTORE_PW_DECLARED=1
    note "The config declares $user's password; it is set when the system is activated."
  elif [ -z "$(get_answer "identity:password")" ]; then
    [ -z "$ANSWERS_IN" ] || die "the repo does not hold the password; add identity:password to the answers."
    ask_item "$(q -c '.groups[].items[] | select(.key == "identity:password")')"
  fi

  # The passphrase for a LUKS layout is typed next, on the keyboard the
  # restored machine's initrd will present.
  apply_keymap
}

# ── restore kit: the answers and keys, from the installer's own stick ─────

# `wabisabi-usb kit` writes a LUKS2 container labelled WABISABI-DATA into the
# free space after the ISO on the same stick, NOT into a partition (see
# installer/disks.sh: kit_scan). Inside: restore.json (the non-secret restore
# answers), age.key, and optionally ssh-key. Nothing here trusts the stick
# beyond what an --answers file would be trusted with.
KIT_DEVICE="" KIT_OFFSET="" KIT_LOOP=""

# The disk holding a kit, looked for on the stick this installer booted
# from first, then on any other removable or USB disk.
find_kit() {
  local live d
  live=$(live_disk || true)
  for d in ${live:+/dev/$live} $(lsblk -dpno NAME,RM,TRAN | awk '$2 == 1 || $3 == "usb" {print $1}'); do
    if kit_scan "$d" >/dev/null 2>&1; then
      echo "$d"
      return 0
    fi
  done
}

load_kit() {
  local dev="$1" pass tries=0 n
  [ -b "$dev" ] || die "restore kit '$dev' is not a block device."
  [ "$(id -u)" = 0 ] || die "opening a restore kit needs root. Try: sudo wabisabi-install"
  KIT_OFFSET=$(kit_scan "$dev") || die "no restore kit on $dev (it is looked for in the space after the ISO)."
  # A read-only loop device over the kit, from its offset to the end of the
  # disk: the stick's own partition table is the ISO's and knows nothing of it.
  KIT_LOOP=$(losetup -f --show -r -o "$KIT_OFFSET" "$dev") || die "could not reach the restore kit on $dev."

  heading "Restore kit on $dev"
  # The passphrase never touches anything but a pipe. Traced by nothing.
  local xtrace=0
  case "$-" in *x*) xtrace=1; set +x ;; esac
  while true; do
    if [ -n "$KIT_PASSFILE" ]; then
      pass=$(cat "$KIT_PASSFILE")
    else
      pass=$(gum input --password --placeholder "the kit's passphrase")
    fi
    if printf '%s' "$pass" | cryptsetup open --readonly --key-file - "$KIT_LOOP" "$KIT_MAPPER" 2>/dev/null; then
      break
    fi
    tries=$((tries + 1))
    if [ -n "$KIT_PASSFILE" ] || [ "$tries" -ge 3 ]; then
      [ "$xtrace" = 1 ] && set -x
      die "that passphrase does not open the restore kit. Nothing was touched."
    fi
    warn "That passphrase does not open it. Again."
  done
  pass=""
  [ "$xtrace" = 1 ] && set -x

  # Copy out and close at once: the rest of the install reads tmpfs copies,
  # and the stick holds no open mapping while disks are being partitioned.
  mkdir -p "$KIT_MNT"
  mount -o ro,noload "/dev/mapper/$KIT_MAPPER" "$KIT_MNT" || die "the restore kit opened but does not mount."
  mkdir -m 0700 "$WORK/kit"
  for n in restore.json age.key ssh-key; do
    if [ -f "$KIT_MNT/$n" ]; then install -m 0600 "$KIT_MNT/$n" "$WORK/kit/$n"; fi
  done
  umount "$KIT_MNT"
  cryptsetup close "$KIT_MAPPER"
  losetup -d "$KIT_LOOP"
  KIT_LOOP=""

  [ -f "$WORK/kit/restore.json" ] || die "the restore kit has no restore.json. Nothing was touched."
  jq -e 'type == "object"' "$WORK/kit/restore.json" >/dev/null || die "the restore kit's restore.json is not a JSON object."

  local k v
  while IFS=$'\t' read -r k v; do
    set_answer "$k" "$v"
    PREFILLED[$k]=1
  done < <(jq -r 'to_entries[] | "\(.key)\t\(.value)"' "$WORK/kit/restore.json")
  set_answer "install:mode" restore
  PREFILLED["install:mode"]=1

  if [ -f "$WORK/kit/age.key" ]; then
    # The key file may carry age-keygen's comment lines; the key is the one
    # line that is a key.
    set_answer "restore:ageKey" "$(grep -m1 '^AGE-SECRET-KEY-1' "$WORK/kit/age.key" || true)"
    mapfile -t RESTORE_EXTRA_KEYS < <(grep '^AGE-SECRET-KEY-1' "$WORK/kit/age.key" | tail -n +2)
  else
    set_answer "restore:ageKey" ""
  fi
  PREFILLED["restore:ageKey"]=1
  if [ -f "$WORK/kit/ssh-key" ]; then
    set_answer "restore:sshKeyFile" "$WORK/kit/ssh-key"
  else
    set_answer "restore:sshKeyFile" ""
  fi
  PREFILLED["restore:sshKeyFile"]=1
  for k in restore:host restore:repoPath; do PREFILLED[$k]=1; done

  KIT_DEVICE="$dev"
  note "Restoring '$(get_answer restore:host)' from $(get_answer restore:source), as the kit says."
}

# Erase the kit: its LUKS header (and with it every keyslot) is overwritten,
# which makes the ciphertext behind it unreadable whatever the passphrase.
# Flash memory may keep stale copies of erased blocks out of reach of any
# write, which is why the kit was encrypted in the first place.
wipe_kit() {
  local dev="$1"
  dd if=/dev/zero of="$dev" bs=1M count=32 seek="$KIT_OFFSET" oflag=seek_bytes conv=notrunc,fsync status=none 2>/dev/null || true
  sync
  if kit_scan "$dev" >/dev/null 2>&1; then
    warn "Could not erase the restore kit on $dev. Wipe it yourself (wabisabi-usb wipe $dev): it holds your keys."
    return 1
  fi
  echo "WABISABI_KIT_WIPED device=$dev offset=$KIT_OFFSET"
  note "The restore kit on $dev is erased."
}

# ── run ───────────────────────────────────────────────────────────────────

# A restore kit: named, or found on its own when nothing else was said.
if [ -n "$KIT_ARG" ] && [ "$KIT_ARG" != none ]; then
  [ -z "$ANSWERS_IN" ] || die "--kit and --answers are two sources of answers; give one."
  if [ "$KIT_ARG" = auto ]; then
    KIT_ARG=$(find_kit)
    [ -n "$KIT_ARG" ] || die "--kit auto: no restore kit found after the ISO on the boot stick, or on any other USB disk."
  fi
  load_kit "$KIT_ARG"
elif [ -z "$KIT_ARG" ] && [ -z "$ANSWERS_IN" ] && [ -z "$OUT_ONLY" ] && [ "$(id -u)" = 0 ]; then
  found=$(find_kit)
  if [ -n "$found" ]; then
    heading "A restore kit"
    note "$found holds a restore kit (made with wabisabi-usb): the config repo, the machine and your keys."
    if gum confirm --default=true "Restore this machine from it?"; then
      load_kit "$found"
    fi
  fi
fi

if [ -n "$ANSWERS_IN" ]; then
  [ -f "$ANSWERS_IN" ] || die "answers file '$ANSWERS_IN' does not exist."
  while IFS=$'\t' read -r k v; do set_answer "$k" "$v"; done < <(jq -r 'to_entries[] | "\(.key)\t\(.value)"' "$ANSWERS_IN")
  note "Loaded $(jq 'length' "$ANSWERS_IN") answers from $ANSWERS_IN"
else
  clear 2>/dev/null || true
  gum style --border rounded --padding "1 3" --border-foreground 141 \
    "$(gum style --bold 'wabisabi')" \
    "an opinionated, libre-only Wayland desktop" \
    "" \
    "This asks for your machine's identity, then for wabisabi's own" \
    "options, and writes an ordinary NixOS flake to ~/nixos: a git" \
    "repo you own, that can rebuild this machine, and that you can" \
    "edit, push, or abandon afterwards."

  reviewed=0
  ngroups=$(q '.groups | length')
  for gi in $(seq 0 $((ngroups - 1))); do
    title=$(q ".groups[$gi].title")
    essential=$(q ".groups[$gi].essential // false")

    # A restore reads everything but the disk out of the repo.
    if [ "$(get_answer "install:mode")" = restore ]; then
      [ "$restore_ready" = 1 ] || restore_prepare
      [ "$essential" = true ] || break
      skip_key=$(q -r ".groups[$gi].skipWhen.key // \"\"")
      if [ -n "$skip_key" ] && [ "$(get_answer "$skip_key")" = "$(q -r ".groups[$gi].skipWhen.equals")" ]; then
        continue
      fi
    fi

    # Identity and disks are not optional. wabisabi's own options are, and
    # being asked twenty questions you have no opinion about is a bad first
    # impression -- so offer the defaults once, in one go, and let anyone who
    # does care say so. Options left at their default are NOT written into the
    # generated config, so the machine keeps tracking wabisabi's defaults
    # rather than freezing today's values into a file.
    if [ "$essential" != "true" ] && [ "$reviewed" = 0 ]; then
      heading "wabisabi's own options"
      note "$(q '[.groups[] | select(.essential != true) | .items[] | select(.emit != null)] | length') options control the desktop itself: greeter, shell, terminal, browser, apps, services."
      note "The defaults are the project's opinion and are all documented in modules/options.nix."
      if gum confirm --default=false "Review them one by one?"; then
        reviewed=1
      else
        note "Keeping the defaults. Nothing is written for them, so they follow wabisabi as it changes."
        break
      fi
    fi

    heading "$title"
    nitems=$(q ".groups[$gi].items | length")
    for ii in $(seq 0 $((nitems - 1))); do
      item=$(q -c ".groups[$gi].items[$ii]")

      # Offer the detected GPU driver as the default rather than an empty box.
      if [ "$(jq -r '.key' <<<"$item")" = "extra:initrdKernelModules" ]; then
        item=$(jq --arg d "$(detect_drm_modules)" '.default = $d' <<<"$item")
      fi

      # Offer the layout the live session is using: someone who picked one
      # there (wabisabi-keyboard) has already said what this keyboard is.
      # The variant only goes with the layout it belongs to.
      case "$(jq -r '.key' <<<"$item")" in
        system:keyboard.layout)
          live_layout=$(live_x11 Layout)
          if [ -n "$live_layout" ]; then
            item=$(jq --arg d "$live_layout" '.default = $d' <<<"$item")
          fi
          ;;
        system:keyboard.variant)
          if [ "$(get_answer system:keyboard.layout)" = "$(live_x11 Layout)" ]; then
            item=$(jq --arg d "$(live_x11 Variant)" '.default = $d' <<<"$item")
          fi
          ;;
      esac

      ask_item "$item"
    done

    # As soon as the layout is known, make it the layout in use.
    apply_keymap
  done
fi

# Both paths: whatever the installer owns and nobody answered gets its
# documented default, explicitly, rather than falling through to NixOS's.
apply_installer_defaults

install_mode=$(get_answer "install:mode")
case "$install_mode" in fresh|restore) ;; *) die "install:mode must be fresh or restore (got '$install_mode')." ;; esac
if [ "$install_mode" = restore ]; then
  [ -z "$OUT_ONLY" ] || die "--out-only writes a new flake; a restore has one already."
  [ "$restore_ready" = 1 ] || restore_prepare
fi

# ── validate ──────────────────────────────────────────────────────────────

hostname=$(get_answer "identity:hostname")
username=$(get_answer "identity:username")
layout=$(get_answer "disk:layout")
device=$(get_answer "disk:device")

# Mirrors the assertion in nixpkgs' networking module, so an invalid name
# fails HERE rather than after the disk has been partitioned.
[[ "$hostname" =~ ^[[:alnum:]]([[:alnum:]_-]{0,61}[[:alnum:]])?$ ]] || die "'$hostname' is not a valid hostname."
[[ "$username" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die "'$username' is not a valid Linux username."

# Names that already exist on any NixOS system: declaring them as a normal
# user is an evaluation error, which without this check arrives after the wipe.
case "$username" in
  root|nobody|messagebus|systemd-*|nixbld*|greeter|nscd|sshd|polkituser)
    die "'$username' is a system account name; pick another."
    ;;
esac

# An empty password is not a password. The interactive path already refuses
# one; an answers file that omits the key must not quietly produce a machine
# whose only account cannot be logged into (or worse, can be without one).
if [ -z "$OUT_ONLY" ] && [ "$RESTORE_PW_FROM_SECRETS" = 0 ] && [ "$RESTORE_PW_DECLARED" = 0 ] \
  && [ -z "$(get_answer "identity:password")" ]; then
  die "no password was given for '$username'. Add identity:password to the answers file."
fi

[ -n "$OUT_ONLY" ] || [ -n "$layout" ] || die "no disk layout chosen."

# The encrypted case, checked before any disk is touched: a passphrase typed
# on a console whose layout could not be set will not be the passphrase the
# initrd asks for, and the result is a machine nobody can unlock.
# A disko config may well encrypt its disk too, and nothing here can tell
# without reading its layout, so it gets the same refusal.
if [ -z "$OUT_ONLY" ] && { [ "$layout" = "luks" ] || [ "$layout" = "disko" ]; } && [ "$keymap_failed" = 1 ]; then
  die "the console could not be switched to the '$(get_answer "system:keyboard.layout")' layout, so an encrypted install would take its passphrase on the wrong keyboard. Nothing was touched."
fi

if [ -z "$OUT_ONLY" ]; then
  [ "$(id -u)" = 0 ] || die "installing needs root. Try: sudo wabisabi-install"
  [ -d /sys/firmware/efi ] || die "this machine did not boot in UEFI mode. wabisabi's shipped layouts are UEFI-only; use the manual layout for BIOS."
fi

# ── secrets: settled before any disk is touched ──────────────────────────

# The age key is obtained HERE, before the summary, so that someone who is
# shown a new key and decides they cannot save it right now can still abort
# with nothing partitioned.
if [ "$install_mode" = restore ]; then
  # The repo's secrets already exist and the key was checked against them
  # in restore_prepare.
  secrets_mode=restore
else
  secrets_mode=$(get_answer "secrets:mode")
  case "$secrets_mode" in generate|import|skip) ;; *) die "secrets:mode must be generate, import or skip (got '$secrets_mode')." ;; esac
fi
if [ -n "$OUT_ONLY" ]; then
  # --out-only writes the flake as the template renders it; secrets are a
  # step on the machine, run with `wabisabi-secrets init` in the result.
  secrets_mode=skip
fi

if [ "$secrets_mode" = import ]; then
  valid_age_key "$(get_answer "secrets:ageKey")" || die "secrets:ageKey is not a valid age secret key."
  (umask 077; printf '%s\n' "$(get_answer "secrets:ageKey")" > "$WORK/age.key")
elif [ "$secrets_mode" = generate ]; then
  keygen_args=(keygen --out "$WORK/age.key")
  if [ -n "$ANSWERS_IN" ] || [ "$ASSUME_YES" = 1 ]; then keygen_args+=(--yes); fi
  heading "Your age key"
  wabisabi-secrets "${keygen_args[@]}"
fi

if [ "$secrets_mode" = generate ] || [ "$secrets_mode" = import ]; then
  # The password's hash, which is what goes in the encrypted file. Computed
  # now, while the password is in memory anyway, and kept on tmpfs.
  xtrace=0
  case "$-" in *x*) xtrace=1; set +x ;; esac
  (umask 077; printf '%s' "$(get_answer "identity:password")" | mkpasswd -m yescrypt --stdin > "$WORK/password.hash")
  [ "$xtrace" = 1 ] && set -x
  [ -s "$WORK/password.hash" ] || die "could not hash the password."
fi

# ── emit the flake ────────────────────────────────────────────────────────

answers_json > "$WORK/answers.json"

if [ -n "$OUT_ONLY" ]; then
  bash "$WABISABI_EMIT" \
    --questions "$WABISABI_QUESTIONS" --answers "$WORK/answers.json" \
    --template "$WABISABI_TEMPLATE" --out "$OUT_ONLY" \
    --state-version "$WABISABI_STATE_VERSION" --wabisabi-url "$WABISABI_URL"
  # install, not cp: the lock comes from the store at mode 0444, and a plain
  # copy leaves a read-only file that a second run cannot overwrite and that
  # `nix flake update` in the resulting tree cannot rewrite.
  install -m 0644 "$WABISABI_LOCK" "$OUT_ONLY/flake.lock"
  bold "Wrote the flake to $OUT_ONLY. No disk was touched."
  exit 0
fi

# Where the repo goes on the target, and which of its machines to build.
if [ "$install_mode" = restore ]; then
  REPO_PATH="$RESTORE_REPO_PATH"
  FLAKE_ATTR="$RESTORE_HOST"
else
  REPO_PATH="/home/$username/nixos"
  FLAKE_ATTR="$hostname"
fi

# ── summary and the point of no return ────────────────────────────────────

heading "Summary"
printf '  %-16s %s\n' \
  "hostname" "$hostname" \
  "user" "$username" \
  "disk" "$(if [ "$layout" = disko ]; then echo "${RESTORE_DISKS[*]} (as the config declares)"; else echo "${device:-(already mounted at $TARGET)}"; fi)" \
  "layout" "$layout" \
  "installing" "$([ "$install_mode" = restore ] && echo "'$RESTORE_HOST' from $(get_answer "restore:source")" || echo "a new machine")" \
  "config repo" "$REPO_PATH (linked from /etc/nixos)" \
  "secrets" "$(case "$secrets_mode" in generate) echo "sops, with the new key" ;; import) echo "sops, with your key" ;; restore) [ -s "$WORK/age.key" ] && echo "the repo's, with your key" || echo "none in the repo" ;; *) echo "not set up (wabisabi-secrets init, later)" ;; esac)" \
  "packages from" "$([ "$WABISABI_OFFLINE" = 1 ] && echo "this medium, offline" || echo "cache.nixos.org, over the network")"
echo
# Only true when the options were NOT reviewed. Walking through them records
# what you chose, including choices that match today's default, and recorded
# values are exactly the ones that stop tracking the project.
if [ "$reviewed" = 0 ] && [ -z "$ANSWERS_IN" ]; then
  note "Options you did not set are left out of the config, so they keep following wabisabi."
fi
jq -r 'to_entries[] | select(.key | startswith("identity:") or startswith("disk:") | not) | "  \(.key | sub("^[a-z]+:"; "")) = \(.value)"' "$WORK/answers.json" 2>/dev/null || true

if [ "$ASSUME_YES" != 1 ]; then
  gum confirm "Install now?" || die "aborted; no disk was touched."
fi

# ── partition ─────────────────────────────────────────────────────────────

if [ "$layout" = "manual" ]; then
  mountpoint -q "$TARGET" || die "layout is 'manual' but nothing is mounted at $TARGET."
  note "Manual layout: using the filesystems already mounted at $TARGET."
elif [ "$layout" = "disko" ]; then
  # The config's own disk declaration, through disko's --flake, which reads
  # nixosConfigurations.<host>.config.disko. Every declared disk gets the
  # same safety checks and the same typed confirmation as the installer's
  # own layouts. A LUKS passphrase, if the layout has one, is asked for by
  # disko itself unless the config names a file for it.
  device="${RESTORE_DISKS[*]}"
  for d in "${RESTORE_DISKS[@]}"; do
    check_device_safe "$d"
    confirm_destruction "$d"
  done
  heading "Partitioning as the config declares"
  DISK_TOUCHED=1
  disko --mode "destroy,format,mount" --yes-wipe-all-disks \
    --root-mountpoint "$TARGET" --flake "$RESTORE_CLONE#$RESTORE_HOST"
else
  check_device_safe "$device"
  confirm_destruction "$device"

  # Quoted because the comma-separated mode is one argument to disko, not
  # three array elements (shellcheck SC2054 is right to ask).
  #
  # --root-mountpoint, because disko otherwise mounts at its own default of
  # /mnt regardless of --target: the disk would be wiped and formatted and the
  # install would then abort saying nothing is mounted where it expected.
  disko_args=(
    --mode "destroy,format,mount"
    --yes-wipe-all-disks
    --root-mountpoint "$TARGET"
    --argstr device "$device"
  )
  if [ "$layout" = "luks" ]; then
    passfile="$WORK/luks.key"
    (umask 077; printf '%s' "$(get_answer "disk:passphrase")" > "$passfile")
    [ -s "$passfile" ] || die "the LUKS layout needs a passphrase."
    disko_args+=(--argstr passphraseFile "$passfile")
  fi

  heading "Partitioning $device"
  DISK_TOUCHED=1
  disko "${disko_args[@]}" "$WABISABI_DISKO/$layout.nix"
fi

mountpoint -q "$TARGET" || die "nothing is mounted at $TARGET after partitioning."

# ── the config repo ───────────────────────────────────────────────────────

# The flake lives in the owner's home, as a git repo they own, and
# /etc/nixos is a link to it that the flake itself declares
# (template/configuration.nix). Nothing is written to $TARGET/etc/nixos: a
# real directory there would stop that link from being created.
REPO="$TARGET$REPO_PATH"
mkdir -p "$(dirname "$REPO")"

heading "Detecting hardware"
# Printed rather than written, so no /etc/nixos directory appears and no
# scaffold configuration.nix has to be thrown away.
nixos-generate-config --root "$TARGET" --show-hardware-config > "$WORK/hardware-configuration.nix"

if [ "$install_mode" = restore ]; then
  # The repo as it is, in the place its config says it lives, with ONE
  # change: the hardware file, because new partitions have new UUIDs and the
  # old file names disks that no longer exist. Committed, so the tree is
  # clean, and so the owner can see and push what the reinstall changed.
  heading "Restoring $REPO_PATH"
  cp -a "$RESTORE_CLONE" "$REPO"
  # A disko config describes its disks itself and has no hardware file to
  # regenerate: the repo goes back exactly as it was.
  if [ "$RESTORE_DISKO" = 0 ]; then
    install -m 0644 "$WORK/hardware-configuration.nix" "$REPO/hardware-configuration.nix"
    git -C "$REPO" add hardware-configuration.nix
  fi
  if ! git -C "$REPO" diff --cached --quiet; then
    git -C "$REPO" \
      -c user.name=wabisabi-install -c user.email=installer@localhost \
      commit -q -m "Reinstall $RESTORE_HOST on new disks

hardware-configuration.nix regenerated by wabisabi-install for the disks this
reinstall partitioned (new UUIDs). Nothing else in the repo was changed."
  fi
  # THE KEY GOES ONLY WHERE THE CONFIG READS IT. A config set up by
  # wabisabi-secrets uses one key for owner and machine, so it gets both
  # copies. Anything else gets the machine's copy only if the config names a
  # key file (sops.age.keyFile), and never the owner's: for a fleet repo the
  # key that opens everything is the ADMIN key, and leaving it on one laptop
  # is a decision, not a side effect of reinstalling it.
  if [ -s "$WORK/age.key" ]; then
    key_args=(install-key --root "$TARGET" --user "$username" --key-file "$WORK/age.key" --yes)
    [ -z "$RESTORE_KEYFILE_PATH" ] || key_args+=(--machine-key "$RESTORE_KEYFILE_PATH")
    if [ "$RESTORE_TEMPLATE_SECRETS" = 1 ]; then
      heading "Putting your age key in place"
      wabisabi-secrets "${key_args[@]}"
    elif [ -n "$RESTORE_KEYFILE_PATH" ]; then
      heading "Putting the machine's age key in place"
      wabisabi-secrets "${key_args[@]}" --no-user-copy
    else
      note "Your age key was used for this restore only; the config does not read one from disk, so it was not copied there."
    fi
  fi

  # The files the config asked for (wabisabi.restore.files), decrypted
  # before partitioning, placed now, before activation first needs them.
  while IFS=$'\t' read -r idx path mode; do
    install -D -m "$mode" -o root -g root "$WORK/files/$idx" "$TARGET$path"
    note "Placed $path (from the repo, mode $mode)."
  done < "$WORK/files.tsv"
else
  heading "Writing ~/nixos"
  bash "$WABISABI_EMIT" \
    --questions "$WABISABI_QUESTIONS" --answers "$WORK/answers.json" \
    --template "$WABISABI_TEMPLATE" --out "$WORK/flake" \
    --state-version "$WABISABI_STATE_VERSION" --wabisabi-url "$WABISABI_URL"

  install -m 0644 "$WABISABI_LOCK" "$WORK/flake/flake.lock"
  install -m 0644 \
    "$WORK/flake/flake.nix" \
    "$WORK/flake/configuration.nix" \
    "$WORK/flake/.gitignore" \
    "$WORK/flake/flake.lock" \
    "$WORK/hardware-configuration.nix" \
    -t "$REPO/"

  # The pinned lock is the difference between installing what was tested and
  # installing whatever is current. If it did not land, stop now rather than
  # letting nix quietly resolve something else.
  [ -f "$REPO/flake.lock" ] || die "internal: the pinned flake.lock did not reach $REPO."

  # A record of what was answered. Nothing reads it back: it is there so that
  # "how was this machine installed" has an answer a year from now. Secrets are
  # never in it (answers_json drops them).
  jq '.' "$WORK/answers.json" > "$REPO/installer-answers.json"
  chmod 0644 "$REPO/installer-answers.json"

  # git first, and committed, so that the flake is a clean tree from the moment
  # it exists -- and because an uncommitted git repo would hide these very files
  # from nix, which does not see untracked files in a git tree.
  if [ ! -d "$REPO/.git" ]; then
    git -C "$REPO" init -q -b main
    git -C "$REPO" add -A
    git -C "$REPO" \
      -c user.name=wabisabi-install -c user.email=installer@localhost \
      commit -q -m "Install $hostname with wabisabi

  Generated by wabisabi-install from template/ plus the answers in
  installer-answers.json. This is an ordinary NixOS flake that rebuilds this
  machine: edit it, then
    sudo nixos-rebuild switch
  (/etc/nixos links here), or walk away from wabisabi entirely by removing the
  module imports."
  fi

  # The second commit: sops, with the password's hash as the first secret.
  # Same tool, same code the owner runs later by hand if they skipped this.
  if [ "$secrets_mode" = generate ] || [ "$secrets_mode" = import ]; then
    heading "Setting up secrets"
    wabisabi-secrets init --repo "$REPO" --root "$TARGET" --user "$username" \
      --key-file "$WORK/age.key" --password-hash-file "$WORK/password.hash" --yes
  fi
fi

# ── install ───────────────────────────────────────────────────────────────

heading "Building and installing the system"
note "This is the long part. It is building your actual configuration, not unpacking an image."

# TWO ROUTES TO THE SAME PLACE, because "offline" is not a flag nixos-install
# can pass on.
#
# Networked: `nixos-install --flake` builds with `--store /mnt`, so everything
# it downloads lands straight on the target disk. That matters, because the
# ISO's own /nix/store is a squashfs with a tmpfs overlay -- building there
# would download several gigabytes into RAM.
#
# Offline: nix needs `--offline` to resolve a locked github input from a store
# path instead of fetching the tarball, and `nixos-install` accepts neither
# that flag nor an equivalent `--option` (there is no `offline` setting). So
# the toplevel is built explicitly here, where the flag can be given, and
# handed over as a prebuilt system. Everything it needs is already on the
# medium, so this builds only the handful of tiny derivations that depend on
# the answers, and RAM is not at risk.
if [ "$WABISABI_OFFLINE" = 1 ]; then
  note "Building from this medium, with the network explicitly disabled."
  if ! toplevel=$(nix build --offline --no-link --print-out-paths --no-update-lock-file \
      "path:$REPO#nixosConfigurations.$FLAKE_ATTR.config.system.build.toplevel"); then
    warn "Could not build the system from this medium."
    toplevel=""
  fi
  install_args=(--root "$TARGET" --system "$toplevel" --no-root-password)
  [ -n "$toplevel" ] || install_args=()
else
  install_args=(--root "$TARGET" --flake "path:$REPO#$FLAKE_ATTR" --no-root-password --no-update-lock-file)
fi

# RETRY THE NETWORKED BUILD, because what fails it most is the network. A
# wabisabi system builds packages that no public binary cache carries (the
# agent layer's pi, wherever, webveil, memonaut, anonctl), and those builds
# fetch hundreds of npm tarballs; one dropped HTTP/2 stream fails the whole
# install AFTER the disk has been wiped. Measured in the VM install test
# (2026-09-26): `Stream error in the HTTP/2 framing layer` on pi-webveil's
# npm dependencies. Everything already built or downloaded stays in the
# target's store, so a retry resumes rather than starts over, and a genuine
# error (a stale lock, a bad option) simply fails three times the same way.
install_ok=0
if [ "${#install_args[@]}" -gt 0 ]; then
  attempts=1
  [ "$WABISABI_OFFLINE" = 1 ] || attempts=3
  for attempt in $(seq 1 "$attempts"); do
    if nixos-install "${install_args[@]}"; then
      install_ok=1
      break
    fi
    if [ "$attempt" -lt "$attempts" ]; then
      warn "The build failed (attempt $attempt of $attempts). Downloads are the usual cause; retrying, keeping everything already fetched."
      sleep 10
    fi
  done
fi

if [ "$install_ok" != 1 ]; then
  # The most likely way for this to fail is the pinned lock being rejected,
  # and "requires lock file changes" does not say WHICH changes. Ask nix, on a
  # scratch copy so nothing on the target is modified, and show the diff.
  warn "nixos-install failed. Checking whether the pinned lock is the reason."
  if cp -r "$REPO" "$WORK/lockdiag" 2>/dev/null; then
    chmod -R u+w "$WORK/lockdiag"
    rm -rf "$WORK/lockdiag/.git"
    if (cd "$WORK/lockdiag" && nix flake lock --extra-experimental-features 'nix-command flakes' 2>&1 | head -20); then
      echo "--- what nix wanted to change in flake.lock ---"
      diff <(jq -S . "$REPO/flake.lock") <(jq -S . "$WORK/lockdiag/flake.lock") | head -60 || true
      echo "--- end ---"
    fi
  fi
  die "the system could not be built. Nothing was written to the bootloader."
fi

# ── password ──────────────────────────────────────────────────────────────

heading "Setting the password"
# With secrets, activation already set it from the encrypted file (NixOS
# applies a declared hash when it creates the account). Check that it did,
# rather than trust it: this is the first time the key, the file and
# sops-nix meet, and a machine nobody can log into is the failure mode.
#
# Without secrets: straight into the target's /etc/shadow, so no password
# material is written into the flake, which therefore stays publishable.
#
# chpasswd is resolved out of the TARGET's store rather than called by name:
# a freshly installed system has no `chpasswd` on its system path (shadow is
# there as a dependency, not as an installed program), so calling it by name
# gets "command not found" after a perfectly good install.
set_target_password() {
  local user="$1" secret="$2" chpasswd

  local xtrace=0
  case "$-" in *x*) xtrace=1; set +x ;; esac

  chpasswd=$(find "$TARGET/nix/store" -maxdepth 3 -type f -path '*-shadow-*/bin/chpasswd' 2>/dev/null | head -1)
  if [ -z "$chpasswd" ]; then
    [ "$xtrace" = 1 ] && set -x
    return 1
  fi

  printf '%s:%s\n' "$user" "$secret" | nixos-enter --root "$TARGET" -c "${chpasswd#"$TARGET"}"
  local rc=$?
  [ "$xtrace" = 1 ] && set -x
  return $rc
}

shadow_hash=$(awk -F: -v u="$username" '$1 == u { print $2 }' "$TARGET/etc/shadow" 2>/dev/null || true)
# The hash we expect is there exactly when the password travels through the
# secrets: a fresh install that set them up, or a restore whose repo holds it.
if [ -s "$WORK/password.hash" ] && [ -n "$shadow_hash" ] && [ "$shadow_hash" = "$(cat "$WORK/password.hash")" ]; then
  note "Password set for $username, from the encrypted config."
elif [ "$RESTORE_PW_DECLARED" = 1 ]; then
  # The config sets the password its own way; all that can be checked is
  # that it did not leave the account locked.
  case "$shadow_hash" in
    ""|"!"*|"*"*)
      warn "$username's account is LOCKED after activation: the config's declared password is empty or a placeholder."
      warn "Fix it in the repo, or from this medium before rebooting:"
      warn "  nixos-enter --root $TARGET -c 'passwd $username'"
      ;;
    *) note "Password set for $username, as the config declares it." ;;
  esac
elif [ -s "$WORK/password.hash" ] && [ "$install_mode" = restore ]; then
  # No typed password to fall back on: the repo was the only source.
  warn "The password did not come through from the repo's secrets."
  warn "The system IS installed, but log in may fail. From this medium, before rebooting:"
  warn "  nixos-enter --root $TARGET -c 'passwd $username'"
elif [ -s "$WORK/password.hash" ]; then
  warn "The password did not come through from the encrypted config; setting it directly."
  warn "The machine will still boot; check 'wabisabi-secrets' after logging in."
  set_target_password "$username" "$(get_answer "identity:password")" \
    || die "could not set the password for $username by either route. From this medium: nixos-enter --root $TARGET -c 'passwd $username'"
elif set_target_password "$username" "$(get_answer "identity:password")"; then
  note "Password set for $username."
else
  # NOT "log in as root": the install ran with --no-root-password and the
  # template sets none, so root is locked and no account on that machine has
  # a usable password. The only way in is from this medium.
  warn "Could not set the password for $username."
  warn "The system IS installed but NOBODY CAN LOG INTO IT YET, including root."
  warn "Fix it from this installer medium, before rebooting:"
  warn "  mount /dev/... $TARGET   # the root filesystem you just installed to"
  warn "  nixos-enter --root $TARGET -c 'passwd $username'"
fi

# The home was made here, as root, before the account existed: the repo and
# the owner's copy of the age key are in it. Hand all of it over. Read the
# ids out of the target's own passwd rather than asking the running system,
# whose accounts have nothing to do with the installed machine's.
ids=$(awk -F: -v u="$username" '$1 == u { print $3":"$4 }' "$TARGET/etc/passwd" || true)
if [ -n "$ids" ]; then
  chown -R "$ids" "$TARGET/home/$username"
  # A restored config may keep its repo outside the home.
  case "$REPO_PATH" in
    "/home/$username"/*) ;;
    *) chown -R "$ids" "$REPO" ;;
  esac
else
  warn "could not find $username in the installed passwd; ~/nixos stays root-owned (edit with sudo)."
fi

# The link the flake declares. Created by activation during the install; a
# missing one means a bare `nixos-rebuild` will not find the flake.
# Only the link itself is checked: its target is absolute (/etc/static/...),
# so resolving it from here would follow the INSTALLER's /etc, not the
# target's.
if [ ! -L "$TARGET/etc/nixos" ]; then
  warn "/etc/nixos does not link to $REPO_PATH on the installed system; rebuild with --flake $REPO_PATH#$FLAKE_ATTR."
fi

# ── the restore kit, which holds your keys ────────────────────────────────

if [ -n "$KIT_DEVICE" ]; then
  heading "The restore kit"
  if [ "$WIPE_KIT" = 1 ]; then
    wipe_kit "$KIT_DEVICE" || true
  elif [ "$ASSUME_YES" != 1 ] && gum confirm --default=true "Erase the restore kit from $KIT_DEVICE now? It holds your age key; the machine no longer needs it."; then
    wipe_kit "$KIT_DEVICE" || true
  else
    warn "The restore kit is still on $KIT_DEVICE, with your keys in it. Erase it when you are done: wabisabi-usb wipe <stick>."
  fi
fi

# ── done ──────────────────────────────────────────────────────────────────

heading "Done"
gum style --border rounded --padding "1 3" --border-foreground 141 \
  "$(gum style --bold "$hostname is installed.")" \
  "" \
  "Log in as $username." \
  "Your config is $REPO_PATH$([ -L "$TARGET/etc/nixos" ] && echo " (/etc/nixos links to it)"): a git repo" \
  "that rebuilds this machine. Edit it, then:" \
  "  sudo nixos-rebuild switch$([ -L "$TARGET/etc/nixos" ] || echo " --flake $REPO_PATH#$FLAKE_ATTR")" \
  "$(if [ "$install_mode" = restore ]; then
      if [ "$RESTORE_DISKO" = 1 ]; then
        echo "Restored exactly as it was: its own disko layout, no new commit."
      else
        echo "Restored as it was, plus one commit with this machine's new"
        echo "hardware-configuration.nix. Push it (git push) to keep it."
      fi
    else
      echo "Push it somewhere (git remote add ...) and it can also"
      echo "rebuild this machine after a wipe$([ "$secrets_mode" != skip ] && echo ", with your age key")."
    fi)" \
  "" \
  "Secrets: wabisabi-secrets --help" \
  "Options: nixos-option wabisabi, or modules/options.nix upstream."

# A machine-readable line, so an automated install can be checked for success
# rather than for the absence of an error message.
echo "WABISABI_INSTALL_OK host=$hostname user=$username layout=$layout secrets=$secrets_mode mode=$install_mode"

if [ "$NO_REBOOT" = 1 ]; then
  note "Leaving the machine running (--no-reboot)."
elif [ "$ASSUME_YES" = 1 ]; then
  note "Rebooting now."
  systemctl reboot
elif gum confirm "Reboot now?"; then
  systemctl reboot
fi
