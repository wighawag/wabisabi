#!/usr/bin/env bash
# Unpack a searchcast recipe-set archive into a flat directory, refusing
# anything `searchcast install-recipes` would refuse.
#
#   unpack-recipe-set.sh <archive.tar.gz> <out-dir>
#
# The format (searchcast's README, "Release archive format"): a gzipped tar of
# regular files named *.mjs, *.js or *.json, all at the archive's root or all
# under ONE top-level directory, with no deeper directories, no hidden files,
# no links. The set may carry a manifest.json; it is kept, and webveil skips
# it, since a code-recipe directory loads only *.js and *.mjs.
#
# Run at build time by modules/agents.nix (on the archive fetchurl checked
# against the owner's sha256) and by the flake's checks (on a fixture). It is
# strict for the same reason install-recipes is: what lands in the output is
# code webveil will run, so an archive that is not exactly a recipe set fails
# here, naming the entry, rather than being half-loaded later.

set -euo pipefail

archive="$1"
out="$2"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

fail() {
  echo "recipe set: $*" >&2
  exit 1
}

# List before extracting, so links and devices are refused by type rather
# than discovered on disk.
while IFS= read -r line; do
  case "${line:0:1}" in
    -|d) ;;
    *) fail "only regular files and directories are allowed: $line" ;;
  esac
done < <(tar -tvzf "$archive")

tar -xzf "$archive" -C "$work" --no-same-owner --no-same-permissions

src="$work"
shopt -s nullglob dotglob
entries=("$work"/*)
if [ "${#entries[@]}" -eq 1 ] && [ -d "${entries[0]}" ]; then
  src="${entries[0]}"
  case "$(basename "$src")" in .*) fail "hidden top-level directory: $(basename "$src")" ;; esac
fi

mkdir -p "$out"
count=0
for path in "$src"/*; do
  name=$(basename "$path")
  case "$name" in .*) fail "hidden file: $name" ;; esac
  [ -d "$path" ] && fail "nested directory: $name (a set is flat)"
  [ -f "$path" ] || fail "not a regular file: $name"
  case "$name" in
    *.mjs|*.js|*.json) ;;
    *) fail "not a recipe file (*.mjs, *.js, *.json): $name" ;;
  esac
  install -m 0444 "$path" "$out/$name"
  count=$((count + 1))
done

[ "$count" -gt 0 ] || fail "the archive holds no files"
