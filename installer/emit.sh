#!/usr/bin/env bash
# Render the user's flake from template/ plus an answers file.
#
# THIS SCRIPT CONTAINS NO CONFIGURATION TEXT, and that is the point. Every
# line it writes comes either from template/ (which is also what
# `nix flake new -t github:wighawag/wabisabi` scaffolds by hand) or from the
# answers, whose names, types and defaults come from the option declarations
# via installer/questions.nix. There is no second copy of the config to drift.
#
# It is a separate entry point from install.sh so that the emit step can be
# run, diffed and evaluated without a disk, which is what the flake check
# `emit-roundtrip` does.
#
#   emit.sh --questions Q.json --answers A.json --template DIR --out DIR
#
# Answers are a flat JSON object of "layer:path" keys, matching questions.json:
#   { "identity:hostname": "kestrel", "system:tor.enable": "false", ... }

set -euo pipefail

QUESTIONS="" ANSWERS="" TEMPLATE="" OUT="" STATE_VERSION="" WABISABI_URL=""

# What template/flake.nix says by default, and therefore the only URL that
# needs no rewriting.
DEFAULT_URL="github:wighawag/wabisabi"

while [ $# -gt 0 ]; do
  case "$1" in
    --questions) QUESTIONS="$2"; shift 2 ;;
    --answers) ANSWERS="$2"; shift 2 ;;
    --template) TEMPLATE="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    --state-version) STATE_VERSION="$2"; shift 2 ;;
    --wabisabi-url) WABISABI_URL="$2"; shift 2 ;;
    *) echo "emit.sh: unknown argument '$1'" >&2; exit 2 ;;
  esac
done

for required in QUESTIONS ANSWERS TEMPLATE OUT; do
  if [ -z "${!required}" ]; then
    echo "emit.sh: --${required,,} is required" >&2
    exit 2
  fi
done

answer() { jq -r --arg k "$1" '.[$k] // ""' "$ANSWERS"; }

HOSTNAME_ANS=$(answer "identity:hostname")
USERNAME_ANS=$(answer "identity:username")

if [ -z "$HOSTNAME_ANS" ] || [ -z "$USERNAME_ANS" ]; then
  echo "emit.sh: answers are missing identity:hostname or identity:username" >&2
  exit 2
fi

# Validated HERE as well as in install.sh, because this is its own entry point
# (`wabisabi-emit`) and both values are about to be interpolated into a sed
# replacement and then into a Nix file. A value containing "/" alone would
# terminate the s/// command.
if ! [[ "$HOSTNAME_ANS" =~ ^[[:alnum:]]([[:alnum:]_-]{0,61}[[:alnum:]])?$ ]]; then
  echo "emit.sh: '$HOSTNAME_ANS' is not a valid hostname" >&2
  exit 2
fi
if ! [[ "$USERNAME_ANS" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
  echo "emit.sh: '$USERNAME_ANS' is not a valid Linux username" >&2
  exit 2
fi

# The state version is a property of the installer media, not of an answer:
# it records the release this machine was first installed from.
if [ -z "$STATE_VERSION" ]; then
  echo "emit.sh: --state-version is required" >&2
  exit 2
fi

mkdir -p "$OUT"
cp "$TEMPLATE/flake.nix" "$TEMPLATE/configuration.nix" "$TEMPLATE/.gitignore" "$OUT/"
chmod u+w "$OUT/flake.nix" "$OUT/configuration.nix" "$OUT/.gitignore"

# Render the Nix lines for one block ("system" or "home"), in the order the
# questions were asked. Values are typed from questions.json rather than
# guessed from how the answer looks, so the string "true" stays a string when
# the option is a string.
render_block() {
  local block="$1"
  jq -r --slurpfile answers "$ANSWERS" --arg block "$block" '
    # Backslash first, then "$", then the quote. Missing the "$" pass leaves
    # any answer containing ${...} as a LIVE NIX INTERPOLATION in the
    # generated config, which is a broken flake at best.
    def nixstr: "\"" + (tostring
      | gsub("\\\\"; "\\\\")
      | gsub("\\$"; "\\$")
      | gsub("\""; "\\\"")) + "\"";
    [ .groups[].items[]
      | select(.emit != null and .emit.block == $block)
      | . as $item
      | ($answers[0][$item.key] // null) as $value
      | select($value != null and $value != "")
      # tostring, because an answers file written by hand naturally contains
      # real JSON booleans, and comparing those to the STRING "true" silently
      # emitted the opposite of what was asked for.
      | if $item.kind == "bool"
        then "\($item.emit.attr) = \(($value | tostring) == "true");"
        elif $item.kind == "strlist"
        then "\($item.emit.attr) = [ " +
             ([$value | split(" ") | .[] | select(. != "") | nixstr] | join(" ")) +
             " ];"
        else "\($item.emit.attr) = \($value | nixstr);"
        end
    ] | .[]
  ' "$QUESTIONS"
}

# Splice rendered lines between the `# >>> wabisabi:<block>` and
# `# <<< wabisabi:<block>` markers in template/configuration.nix, keeping the
# markers and matching the indentation of the opening one.
splice_block() {
  local block="$1" file="$2" lines="$3"
  awk -v block="$block" -v linesfile="$lines" '
    BEGIN { inblock = 0 }
    {
      if ($0 ~ ("^[[:space:]]*# >>> wabisabi:" block "$")) {
        print
        match($0, /^[[:space:]]*/)
        indent = substr($0, 1, RLENGTH)
        while ((getline line < linesfile) > 0) print indent line
        close(linesfile)
        inblock = 1
        next
      }
      if (inblock && $0 ~ ("^[[:space:]]*# <<< wabisabi:" block "$")) { inblock = 0; print; next }
      if (!inblock) print
    }
    END {
      if (inblock) { print "emit.sh: unterminated marker for " block > "/dev/stderr"; exit 1 }
    }
  ' "$file" > "$file.new"
  mv "$file.new" "$file"
}

for block in system home; do
  tmp=$(mktemp)
  render_block "$block" > "$tmp"
  if ! grep -q "# >>> wabisabi:$block\$" "$OUT/configuration.nix"; then
    echo "emit.sh: template/configuration.nix has no '# >>> wabisabi:$block' marker" >&2
    exit 1
  fi
  splice_block "$block" "$OUT/configuration.nix" "$tmp"
  rm -f "$tmp"
done

# Identity, which is substitution rather than splicing.
for file in "$OUT/configuration.nix" "$OUT/flake.nix"; do
  sed -i \
    -e "s/CHANGEME_HOSTNAME/$HOSTNAME_ANS/g" \
    -e "s/CHANGEME_USERNAME/$USERNAME_ANS/g" \
    -e "s/CHANGEME_STATE_VERSION/$STATE_VERSION/g" \
    "$file"
done

# Point the flake at whatever wabisabi this medium actually carries. Normally
# that is the public URL already in the template and nothing happens here; an
# installer built from an uncommitted tree pins its own store path instead, so
# that the installed machine reproduces the tree it came from rather than
# silently tracking a different one. See installer/lock.nix.
if [ -n "$WABISABI_URL" ] && [ "$WABISABI_URL" != "$DEFAULT_URL" ]; then
  if ! grep -q "url = \"$DEFAULT_URL\";" "$OUT/flake.nix"; then
    echo "emit.sh: template/flake.nix no longer declares '$DEFAULT_URL', so the wabisabi input cannot be repointed" >&2
    exit 1
  fi
  escaped=${WABISABI_URL//\//\\/}
  sed -i "s/url = \"${DEFAULT_URL//\//\\/}\";/url = \"$escaped\";/" "$OUT/flake.nix"
fi

# The password is deliberately not written into the flake in the clear: its
# hash goes into the sops-encrypted secrets file (wabisabi-secrets init), or,
# without secrets, into the target's /etc/shadow with chpasswd. Either way
# this file can be pushed to a public repository as it stands.
python3 - "$OUT/configuration.nix" <<'PYTHON'
import re, sys

path = sys.argv[1]
text = open(path).read()
replacement = """    # Password: never in this file. With secrets set up (see
    # wabisabi.secrets below) its hash is in secrets/secrets.yaml, encrypted,
    # and `wabisabi-secrets password` changes it. Without, it was set at
    # install time straight into /etc/shadow and `passwd` changes it.
"""
text, count = re.subn(
    r'^[ \t]*initialPassword = "CHANGEME_PASSWORD";[ \t]*\n', replacement, text, flags=re.M
)
if count != 1:
    sys.exit(f"emit.sh: expected exactly one CHANGEME_PASSWORD line, found {count}")
open(path, "w").write(text)
PYTHON

# No placeholder may survive into a config that is about to be installed.
if grep -n "CHANGEME_" "$OUT/configuration.nix" "$OUT/flake.nix"; then
  echo "emit.sh: unsubstituted placeholders remain (above)" >&2
  exit 1
fi
