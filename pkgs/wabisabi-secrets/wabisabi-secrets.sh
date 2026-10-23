#!/usr/bin/env bash
# wabisabi-secrets: the owner's side of sops in their machine's flake.
#
# One age key per config repo, used both by the owner (to edit secrets with
# sops) and by the machine (to decrypt them at activation). The repo holds
# only ciphertext and the PUBLIC key, so it can be pushed anywhere; the
# private key lives outside it, in two places, plus a backup the owner keeps.
# With the repo and the key, a wiped machine is reinstalled as it was.
#
#   wabisabi-secrets init       set up sops in the config repo and commit it
#   wabisabi-secrets password   change the login password, in the repo AND now
#   wabisabi-secrets edit       open the secrets file decrypted, in $EDITOR
#   wabisabi-secrets backup     show the key again, to save another copy
#   wabisabi-secrets keygen     make a new key (used by the installer)
#   wabisabi-secrets install-key put a key you have where the machine and you need it
#
# Options:
#   --repo DIR                config repo (default: where /etc/nixos points, else ~/nixos)
#   --user NAME               the owner (default: you, or whoever ran sudo)
#   --root DIR                act on a system mounted at DIR, not this one (the installer)
#   --key-file FILE           init: use this age key rather than your existing one or a new one
#   --password-hash-file FILE init: store this crypt hash rather than your current password's
#   --out FILE                keygen: where to write the new key
#   --machine-key PATH        where the machine reads its key (default /var/lib/sops-nix/key.txt)
#   --no-machine-copy         install-key: skip the machine's copy
#   --no-user-copy            install-key: skip the owner's copy
#   --yes                     no prompts: skip the backup walk-through
#   --no-commit               init: leave the changes staged, uncommitted
#
set -euo pipefail

SECRETS_REL="secrets/secrets.yaml"
ENABLE_LINE="wabisabi.secrets.sopsFile = ./$SECRETS_REL;"

cmd="${1:-}"
[ $# -gt 0 ] && shift

REPO="" OWNER="" ROOT="" KEY_IN="" HASH_IN="" OUT="" ASSUME_YES=0 COMMIT=1
MACHINE_KEY_PATH=/var/lib/sops-nix/key.txt
MACHINE_COPY=1 USER_COPY=1
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO="$2"; shift 2 ;;
    --user) OWNER="$2"; shift 2 ;;
    --root) ROOT="${2%/}"; shift 2 ;;
    --key-file) KEY_IN="$2"; shift 2 ;;
    --password-hash-file) HASH_IN="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    --machine-key) MACHINE_KEY_PATH="$2"; shift 2 ;;
    --no-machine-copy) MACHINE_COPY=0; shift ;;
    --no-user-copy) USER_COPY=0; shift ;;
    --yes|-y) ASSUME_YES=1; shift ;;
    --no-commit) COMMIT=0; shift ;;
    *) echo "wabisabi-secrets: unknown argument '$1'" >&2; exit 2 ;;
  esac
done

usage() { sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; }

# ── output ────────────────────────────────────────────────────────────────

interactive() { [ "$ASSUME_YES" = 0 ] && [ -t 0 ] && [ -t 1 ]; }
bold() { gum style --bold -- "$*"; }
note() { gum style --foreground 244 -- "$*"; }
warn() { gum style --foreground 214 -- "$*"; }
die() { gum style --foreground 196 --bold -- "wabisabi-secrets: $*" >&2; exit 1; }

# Key material only ever goes to a tmpfs: $XDG_RUNTIME_DIR for a user, /run
# for root. A key written to a real disk and then unlinked is still a key
# written to a real disk.
WORK=$(mktemp -d -p "${XDG_RUNTIME_DIR:-/run}" 2>/dev/null || mktemp -d)
chmod 700 "$WORK"
trap 'rm -rf "$WORK"' EXIT

# Under --root the target is a directory tree, and whatever access we have to
# it is the access we use: the installer is root already, and the flake check
# that runs `init` in the build sandbox is not root and needs no sudo.
as_root() {
  if [ "$(id -u)" = 0 ] || [ -n "$ROOT" ]; then "$@"; else sudo "$@"; fi
}

# ── who and where ─────────────────────────────────────────────────────────

if [ -z "$OWNER" ]; then
  OWNER="${SUDO_USER:-$(id -un)}"
fi

if [ -n "$ROOT" ]; then
  # The target's accounts may not exist yet (the installer runs this before
  # nixos-install creates them), so its homes cannot be looked up.
  OWNER_HOME="$ROOT/home/$OWNER"
else
  OWNER_HOME=$(getent passwd "$OWNER" | cut -d: -f6)
  [ -n "$OWNER_HOME" ] || die "no account named '$OWNER' on this machine."
fi

if [ -z "$REPO" ]; then
  if [ -z "$ROOT" ] && [ -e /etc/nixos/flake.nix ]; then
    REPO=$(readlink -f /etc/nixos)
  else
    REPO="$OWNER_HOME/nixos"
  fi
fi

USER_KEYS="$OWNER_HOME/.config/sops/age/keys.txt"
MACHINE_KEY="$ROOT$MACHINE_KEY_PATH"

# ── keys ──────────────────────────────────────────────────────────────────

# The first secret key in a file. keys.txt may hold several, and age-keygen
# writes comment lines above each.
first_key() { grep -m1 -E '^AGE-SECRET-KEY-1[0-9A-Z]+$' "$1" 2>/dev/null || true; }

valid_key() {
  [[ "$1" =~ ^AGE-SECRET-KEY-1[0-9A-Z]{58}$ ]] && age-keygen -y <(printf '%s\n' "$1") >/dev/null 2>&1
}

# Walk the owner through keeping a copy, and make them prove it. Without a
# copy, the day this disk dies is the day the secrets in the repo become
# unreadable noise, and nothing at that point can bring them back.
backup_walkthrough() {
  local key="$1" typed
  if ! interactive; then
    note "Public key: $(age-keygen -y <(printf '%s\n' "$key"))"
    warn "Back up the private age key. On the machine it is in /var/lib/sops-nix/key.txt (root only) and ~/.config/sops/age/keys.txt; 'wabisabi-secrets backup' shows it."
    return 0
  fi

  clear
  gum style --bold --foreground 141 -- "── Save your age key ──"
  echo
  note "This key unlocks the secrets in your config. The repo on its own cannot:"
  note "if this disk is lost and you have no copy of the key, those secrets are gone."
  note "Save it now, somewhere that is NOT this machine: a password manager, or paper."
  echo
  gum style --border rounded --padding "1 2" --border-foreground 214 -- "$key"
  if command -v qrencode >/dev/null; then
    echo
    note "Or scan it into a password manager on your phone:"
    qrencode -t ansiutf8 -m 1 -- "$key" || true
  fi
  echo

  while true; do
    note "Type the LAST 6 characters of the key, from your copy, to confirm you have one."
    typed=$(gum input --placeholder "last 6 characters")
    if [ "${typed^^}" = "${key: -6}" ]; then
      break
    fi
    if [ -z "$typed" ]; then
      if gum confirm --default=false "Continue WITHOUT a saved copy? You can show it again later with 'wabisabi-secrets backup'."; then
        warn "No copy confirmed. Run 'wabisabi-secrets backup' soon."
        break
      fi
      continue
    fi
    warn "That does not match the end of the key. Check your copy."
  done
  # Do not leave the key sitting on the screen.
  clear
}

generate_key() {
  local out="$1"
  (umask 077; age-keygen -o "$out" 2>/dev/null)
}

# Put the key where both parties need it, without duplicating it in either.
install_key() {
  local keyfile="$1" key
  key=$(first_key "$keyfile")

  # The machine's copy: root only, read by sops-nix at activation.
  if [ "$MACHINE_COPY" = 1 ] && [ "$(as_root cat "$MACHINE_KEY" 2>/dev/null | first_key /dev/stdin)" != "$key" ]; then
    if as_root test -s "$MACHINE_KEY"; then
      as_root cp "$MACHINE_KEY" "$MACHINE_KEY.replaced-$(date +%s)"
      warn "$MACHINE_KEY held a different key; kept it beside the new one as .replaced-*."
    fi
    as_root install -d -m 0755 "$(dirname "$MACHINE_KEY")"
    if [ "$(id -u)" = 0 ]; then
      install -m 0600 -o root -g root "$keyfile" "$MACHINE_KEY"
    else
      as_root install -m 0600 "$keyfile" "$MACHINE_KEY"
    fi
  fi

  [ "$USER_COPY" = 1 ] || return 0

  # The owner's copy, which is where `sops` looks by default. Appended, not
  # overwritten: the file may already hold keys for other repos.
  mkdir -p "$(dirname "$USER_KEYS")"
  if ! grep -qxF "$key" "$USER_KEYS" 2>/dev/null; then
    local sep=""
    [ -s "$USER_KEYS" ] && sep=$'\n'
    (umask 077; printf '%s%s\n' "$sep" "$key" >> "$USER_KEYS")
  fi
  chmod 700 "$(dirname "$USER_KEYS")"
  chmod 600 "$USER_KEYS"

  # A user running this owns what it wrote in their home. Under --root, the
  # account may not exist yet, and the installer chowns the home afterwards.
  if [ -z "$ROOT" ] && [ "$(id -u)" = 0 ]; then
    chown -R "$OWNER": "$OWNER_HOME/.config/sops"
  fi
}

# ── the repo ──────────────────────────────────────────────────────────────

git_repo() { git -C "$REPO" "$@"; }

commit() {
  local message="$1"
  # The owner's git identity if they have one, otherwise a stand-in that
  # still says who and where.
  local -a ident=()
  if [ -z "$(git_repo config user.name || true)" ]; then
    ident=(-c "user.name=$OWNER" -c "user.email=$OWNER@$(hostname 2>/dev/null || echo localhost)")
  fi
  git_repo "${ident[@]}" commit -q -m "$message"
}

require_repo() {
  [ -d "$REPO/.git" ] || die "$REPO is not a git repo. Pass --repo with your config's directory."
  [ -f "$REPO/configuration.nix" ] || die "$REPO has no configuration.nix."
}

require_secrets() {
  require_repo
  [ -f "$REPO/$SECRETS_REL" ] || die "no $SECRETS_REL in $REPO yet. Run 'wabisabi-secrets init' first."
  [ -n "$(first_key "$USER_KEYS")" ] || die "no age key in $USER_KEYS. Put your saved key there (one line, AGE-SECRET-KEY-1...)."
}

# A crypt hash for a new password, asked twice.
new_password_hash() {
  local a b
  while true; do
    a=$(gum input --password --placeholder "new password")
    b=$(gum input --password --placeholder "again")
    [ -n "$a" ] && [ "$a" = "$b" ] && break
    warn "They did not match, or were empty. Again."
  done
  printf '%s' "$a" | mkpasswd -m yescrypt --stdin
}

# Uncomment the line the template ships, so the flake starts using the file.
enable_in_config() {
  local conf="$REPO/configuration.nix"
  if grep -qE "^[[:space:]]*${ENABLE_LINE//./\\.}" "$conf"; then
    return 0
  fi
  if grep -qE "^[[:space:]]*#[[:space:]]*${ENABLE_LINE//./\\.}" "$conf"; then
    sed -i -E "s|^([[:space:]]*)#[[:space:]]*(${ENABLE_LINE//./\\.})|\1\2|" "$conf"
    return 0
  fi
  return 1
}

# ── commands ──────────────────────────────────────────────────────────────

cmd_keygen() {
  [ -n "$OUT" ] || die "keygen needs --out FILE."
  [ ! -e "$OUT" ] || die "$OUT already exists; refusing to overwrite a key."
  generate_key "$OUT"
  backup_walkthrough "$(first_key "$OUT")"
}

# A key the owner already has (a restore): put it in place, touch no repo.
cmd_install_key() {
  [ -n "$KEY_IN" ] || die "install-key needs --key-file FILE."
  local key
  key=$(first_key "$KEY_IN")
  valid_key "$key" || die "$KEY_IN holds no valid age secret key."
  (umask 077; printf '%s\n' "$key" > "$WORK/age.key")
  install_key "$WORK/age.key"
}

cmd_init() {
  require_repo
  [ ! -e "$REPO/$SECRETS_REL" ] || die "$REPO already has $SECRETS_REL. Use 'wabisabi-secrets edit' or 'password'."
  grep -qE "${ENABLE_LINE//./\\.}" "$REPO/configuration.nix" \
    || die "configuration.nix has no '$ENABLE_LINE' line, commented or not. Add it (inside the top-level attribute set) and run this again."

  # The key: the one given, else the owner's existing one, else a new one.
  local keyfile="$WORK/age.key" key fresh=0
  if [ -n "$KEY_IN" ]; then
    key=$(first_key "$KEY_IN")
    [ -n "$key" ] || die "$KEY_IN holds no AGE-SECRET-KEY-1 line."
  elif [ -n "$(first_key "$USER_KEYS")" ]; then
    key=$(first_key "$USER_KEYS")
    note "Using your existing age key from $USER_KEYS."
  else
    generate_key "$keyfile"
    key=$(first_key "$keyfile")
    fresh=1
  fi
  valid_key "$key" || die "that is not a valid age secret key."
  (umask 077; printf '%s\n' "$key" > "$keyfile")
  local pub
  pub=$(age-keygen -y "$keyfile")

  # The password hash: given, else the account's current one, else a new one.
  local hash=""
  if [ -n "$HASH_IN" ]; then
    hash=$(tr -d '\n' < "$HASH_IN")
  elif [ -z "$ROOT" ]; then
    hash=$(as_root getent shadow "$OWNER" | cut -d: -f2 || true)
    case "$hash" in
      '$'*) note "Moving your current password into the encrypted config (its hash; the password itself is not known here)." ;;
      *)
        hash=""
        interactive || die "'$OWNER' has no password hash to move and there is nobody to ask. Pass --password-hash-file."
        bold "'$OWNER' has no usable password yet. Choose one:"
        hash=$(new_password_hash)
        ;;
    esac
  fi
  [[ "$hash" == '$'* ]] || die "the password hash is not a crypt hash (expected it to start with '\$')."

  # .sops.yaml: which key new secrets files are encrypted to. The public key
  # only, which is why this file can be committed.
  cat > "$REPO/.sops.yaml" <<EOF
# Which age keys the secrets in this repo are encrypted to. Written by
# wabisabi-secrets. Only the PUBLIC key is here; the private one is in
# ~/.config/sops/age/keys.txt and /var/lib/sops-nix/key.txt, never in the repo.
#
# To give another key access (a second machine, a backup key), add it below
# and run: sops updatekeys $SECRETS_REL
keys:
  - &owner $pub
creation_rules:
  - path_regex: secrets/[^/]+\.(yaml|json|env|ini)\$
    key_groups:
      - age:
          - *owner
EOF

  # The plaintext exists only on tmpfs, and only until sops has read it.
  mkdir -p "$REPO/secrets"
  (umask 077; printf 'owner-password: %s\n' "'$hash'" > "$WORK/plain.yaml")
  (cd "$REPO" && SOPS_AGE_KEY_FILE="$keyfile" sops encrypt \
    --filename-override "$SECRETS_REL" "$WORK/plain.yaml" > "$WORK/enc.yaml")
  rm -f "$WORK/plain.yaml"
  install -m 0644 "$WORK/enc.yaml" "$REPO/$SECRETS_REL"

  # Prove the round trip before anything depends on it.
  [ "$(SOPS_AGE_KEY_FILE="$keyfile" sops decrypt --extract '["owner-password"]' "$REPO/$SECRETS_REL")" = "$hash" ] \
    || die "internal: the secrets file does not decrypt back to what was written."

  enable_in_config || die "internal: could not uncomment '$ENABLE_LINE' in configuration.nix."

  [ "$fresh" = 1 ] && backup_walkthrough "$key"
  install_key "$keyfile"

  git_repo add .sops.yaml "$SECRETS_REL" configuration.nix
  if [ "$COMMIT" = 1 ]; then
    commit "Set up sops secrets

The owner's password hash is now in $SECRETS_REL, encrypted to the age key
in .sops.yaml. Only its public half is in this repo. With this repo and the
private key, a reinstall comes back with the same password."
  fi

  bold "Secrets are set up in $REPO."
  note "Public key: $pub"
  if [ -z "$ROOT" ]; then
    note "Apply it with: sudo nixos-rebuild switch"
    note "Change the password later with 'wabisabi-secrets password', not plain 'passwd'."
  fi
}

cmd_password() {
  require_secrets
  interactive || die "password is interactive."
  local hash
  bold "New login password for $OWNER"
  hash=$(new_password_hash)

  printf '%s' "$hash" | jq -Rs . \
    | (cd "$REPO" && sops set --value-stdin "$SECRETS_REL" '["owner-password"]')

  # NixOS applies a declared password when the account is CREATED; this
  # machine's account exists, so set the live one too. Both halves, or the
  # repo and the machine disagree about what the password is.
  printf '%s:%s\n' "$OWNER" "$hash" | as_root chpasswd -e

  git_repo add "$SECRETS_REL"
  commit "Change the owner's password"
  bold "Password changed, here and in $REPO (committed)."
}

cmd_edit() {
  require_secrets
  cd "$REPO"
  exec sops edit "$SECRETS_REL"
}

cmd_backup() {
  local key
  key=$(first_key "$USER_KEYS")
  [ -n "$key" ] || key=$(as_root cat "$MACHINE_KEY" 2>/dev/null | first_key /dev/stdin)
  [ -n "$key" ] || die "no age key found in $USER_KEYS or $MACHINE_KEY."
  interactive || die "backup is interactive: it shows the key on screen."
  backup_walkthrough "$key"
  bold "Done."
}

case "$cmd" in
  init) cmd_init ;;
  password) cmd_password ;;
  edit) cmd_edit ;;
  backup) cmd_backup ;;
  keygen) cmd_keygen ;;
  install-key) cmd_install_key ;;
  -h|--help|help|"") usage ;;
  *) echo "wabisabi-secrets: unknown command '$cmd'" >&2; usage >&2; exit 2 ;;
esac
