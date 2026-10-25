#!/usr/bin/env bash
# Publish, list and delete wabisabi's downloadable ISOs.
#
# The ISOs live in a Cloudflare R2 bucket, served at $DOWNLOADS (a custom
# domain on the bucket), one folder per version, never changed once written:
#
#   v0.1.0/wabisabi-offline.iso
#   v0.1.0/wabisabi-netinstall.iso
#   v0.1.0/SHA256SUMS
#   releases.json            what is downloadable, newest first; the website
#                            reads it, so publishing needs no site rebuild
#
#   scripts/release.sh publish 0.1.0 [--keep N] [--dry-run]
#       Build both ISOs from the v0.1.0 tag (on GitHub, so what is published is
#       what anyone can rebuild), upload them with their checksums, put the
#       version first in releases.json, and write the checksums into the
#       GitHub release's notes (a second channel: a tampered bucket cannot
#       also rewrite GitHub). The netinstall ISO is also attached to the
#       GitHub release, as the website's fallback download, and the website is
#       rebuilt to pick it up. Then keep only the newest N versions, default 1:
#       older ones are deleted from the bucket. Anything deleted can be rebuilt
#       from its tag (`nix build github:wighawag/wabisabi/vX.Y.Z#iso-offline`).
#   scripts/release.sh delete 0.1.0 [--dry-run]
#       Remove one version: its folder, and its entry in releases.json.
#   scripts/release.sh list
#       What releases.json says, and what the bucket actually holds.
#
# Credentials: an R2 API token with Object Read & Write on the bucket, as
# R2_ACCOUNT_ID, R2_ACCESS_KEY_ID and R2_SECRET_ACCESS_KEY, from the
# environment or from ~/.config/wabisabi/r2.env (keep it mode 600). rclone
# does the uploads because a single R2 upload stops at 5 GiB and the offline
# ISO is bigger: the S3 API's multipart upload has no such limit.
set -euo pipefail

# The bucket keeps the project's earlier name: R2 cannot rename a bucket, and
# only the domain in front of it is public.
BUCKET="${WABISABI_BUCKET:-wasisabi-releases}"
DOWNLOADS="${WABISABI_DOWNLOADS:-https://downloads.wabisabi.computer}"
REPO="wighawag/wabisabi"
# The website, rebuilt after a release so its baked-in fallback follows.
SITE_REPO="wighawag/wabisabi-website"
SITE_WORKFLOW="pages.yml"
ISOS=(offline netinstall)

here="$(cd "$(dirname "$0")/.." && pwd)"

die() { echo "release: $*" >&2; exit 1; }
say() { echo "== $*" >&2; }

# rclone and jq from this flake's own nixpkgs, if they are not on PATH.
if ! command -v rclone > /dev/null || ! command -v jq > /dev/null; then
  nixpkgs=$(nix eval --raw --impure --expr "(builtins.getFlake \"$here\").inputs.nixpkgs.outPath")
  exec nix shell "path:$nixpkgs#rclone" "path:$nixpkgs#jq" --command "$0" "$@"
fi

# ── arguments ──────────────────────────────────────────────────────────────
cmd="${1:-}"; shift || true
version=""; keep=1; dry=0
while [ $# -gt 0 ]; do
  case "$1" in
    --keep) keep="$2"; shift 2 ;;
    --dry-run) dry=1; shift ;;
    -*) die "unknown option $1" ;;
    *) [ -z "$version" ] || die "one version at a time"; version="${1#v}"; shift ;;
  esac
done
case "$cmd" in publish|delete) [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]] || die "usage: $0 $cmd X.Y.Z" ;; list) ;; *)
  sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;; esac
[[ "$keep" =~ ^[1-9][0-9]*$ ]] || die "--keep takes a number of versions, at least 1"

# ── R2 through rclone, configured from the environment (no config file) ────
creds="${XDG_CONFIG_HOME:-$HOME/.config}/wabisabi/r2.env"
# shellcheck disable=SC1090
[ -f "$creds" ] && . "$creds"
if [ "$dry" = 0 ] || [ "$cmd" = list ]; then
  for v in R2_ACCOUNT_ID R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY; do
    [ -n "${!v:-}" ] || die "$v is not set (environment, or $creds)"
  done
fi
export RCLONE_CONFIG_R2_TYPE=s3 RCLONE_CONFIG_R2_PROVIDER=Cloudflare \
  RCLONE_CONFIG_R2_ACCESS_KEY_ID="${R2_ACCESS_KEY_ID:-}" \
  RCLONE_CONFIG_R2_SECRET_ACCESS_KEY="${R2_SECRET_ACCESS_KEY:-}" \
  RCLONE_CONFIG_R2_ENDPOINT="https://${R2_ACCOUNT_ID:-none}.r2.cloudflarestorage.com" \
  RCLONE_CONFIG_R2_NO_CHECK_BUCKET=true
r2="r2:$BUCKET"

# Mutating calls go through here, so --dry-run shows exactly what would run.
run() { if [ "$dry" = 1 ]; then echo "would run: $*" >&2; else "$@"; fi; }

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT

# The current list, straight from the bucket (the public URL may be cached).
# `rclone cat` on a missing object succeeds with no output (it treats the path
# as an empty directory), so an empty result means "no index yet", not "broken".
fetch_index() {
  if [ -n "${R2_ACCESS_KEY_ID:-}" ] && rclone cat "$r2/releases.json" > "$work/releases.json" 2> /dev/null \
     && [ -s "$work/releases.json" ]; then
    jq -e '.releases | type == "array"' "$work/releases.json" > /dev/null || die "releases.json in the bucket is malformed; fix it by hand"
  else
    echo '{"releases":[]}' > "$work/releases.json"
  fi
}

put_index() {
  jq . "$work/releases.json" > "$work/releases.out"
  if [ "$dry" = 1 ]; then echo "would write releases.json:" >&2; cat "$work/releases.out" >&2; return; fi
  # no-cache: the site reads this live, and a stale list is a broken link.
  rclone copyto "$work/releases.out" "$r2/releases.json" \
    --header-upload "Content-Type: application/json" --header-upload "Cache-Control: no-cache"
}

delete_version() {
  say "deleting v$1 from the bucket"
  run rclone purge "$r2/v$1"
  jq --arg v "$1" '.releases |= map(select(.version != $v))' "$work/releases.json" > "$work/r" && mv "$work/r" "$work/releases.json"
}

case "$cmd" in
  list)
    fetch_index
    say "releases.json"; jq -r '.releases[] | "v\(.version)  \(.date)  \([.files[] | "\(.name) \(.size)"] | join(", "))"' "$work/releases.json"
    say "bucket"; rclone lsf "$r2" --dirs-only
    ;;

  delete)
    fetch_index
    delete_version "$version"
    put_index
    say "done. The GitHub release v$version (notes, tag) is untouched: 'gh release delete v$version -R $REPO' if it should go too."
    ;;

  publish)
    git -C "$here" ls-remote --exit-code --tags origin "refs/tags/v$version" > /dev/null \
      || die "tag v$version is not on GitHub: tag and push it first, so the ISOs come from a pinned, public revision"
    fetch_index

    say "building both ISOs from github:$REPO/v$version"
    for kind in "${ISOS[@]}"; do
      nix build "github:$REPO/v$version#iso-$kind" --out-link "$work/iso-$kind" --print-build-logs
    done

    say "checksums"
    files_json='[]'
    : > "$work/SHA256SUMS"
    for kind in "${ISOS[@]}"; do
      iso=$(echo "$work/iso-$kind"/iso/*.iso)
      name="wabisabi-$kind.iso"
      [ "$(basename "$iso")" = "$name" ] || die "expected $name, the build made $(basename "$iso")"
      sum=$(sha256sum "$iso" | cut -d' ' -f1)
      size=$(stat -Lc %s "$iso")
      echo "$sum  $name" >> "$work/SHA256SUMS"
      files_json=$(jq --arg n "$name" --arg k "$kind" --arg s "$sum" --argjson z "$size" \
        '. + [{name: $n, kind: $k, size: $z, sha256: $s}]' <<< "$files_json")
    done
    cat "$work/SHA256SUMS" >&2

    say "uploading to $r2/v$version"
    for kind in "${ISOS[@]}"; do
      iso=$(echo "$work/iso-$kind"/iso/*.iso)
      # Immutable: a version's files never change, so caches may keep them.
      run rclone copyto "$iso" "$r2/v$version/wabisabi-$kind.iso" --progress \
        --s3-chunk-size 64M --s3-upload-concurrency 4 \
        --header-upload "Content-Type: application/x-iso9660-image" \
        --header-upload "Cache-Control: public, max-age=31536000, immutable"
    done
    run rclone copyto "$work/SHA256SUMS" "$r2/v$version/SHA256SUMS" --header-upload "Content-Type: text/plain"

    # This version first; drop any older entry for it (a re-publish).
    jq --arg v "$version" --arg d "$(date -u +%F)" --argjson f "$files_json" \
      '.releases = ([{version: $v, date: $d, files: $f}] + (.releases | map(select(.version != $v))))' \
      "$work/releases.json" > "$work/r" && mv "$work/r" "$work/releases.json"

    # Keep the newest N; everything after that is deleted.
    for old in $(jq -r --argjson k "$keep" '.releases[$k:][] .version' "$work/releases.json"); do
      delete_version "$old"
    done
    put_index

    say "the GitHub release's notes"
    {
      echo "Downloads (checksums below, and in [SHA256SUMS]($DOWNLOADS/v$version/SHA256SUMS)):"
      echo
      for kind in "${ISOS[@]}"; do echo "- [wabisabi-$kind.iso]($DOWNLOADS/v$version/wabisabi-$kind.iso)"; done
      echo
      echo '```'
      cat "$work/SHA256SUMS"
      echo '```'
      echo
      echo "Build either one yourself: \`nix build github:$REPO/v$version#iso-offline\` (or \`#iso-netinstall\`)."
    } > "$work/notes.md"
    if gh release view "v$version" -R "$REPO" > /dev/null 2>&1; then
      run gh release edit "v$version" -R "$REPO" --notes-file "$work/notes.md"
    else
      run gh release create "v$version" -R "$REPO" --verify-tag --prerelease --title "wabisabi $version" --notes-file "$work/notes.md"
    fi

    # The netinstall ISO also goes on the GitHub release: it is the website's
    # fallback, which has to outlive the bucket's deletions. (The offline ISO
    # is over GitHub's 2 GiB asset limit, so it is only in the bucket.)
    say "attaching the netinstall ISO to the GitHub release"
    mkdir "$work/gh"
    cp "$(echo "$work/iso-netinstall"/iso/*.iso)" "$work/gh/wabisabi-netinstall.iso"
    grep '  wabisabi-netinstall\.iso$' "$work/SHA256SUMS" > "$work/gh/SHA256SUMS"
    run gh release upload "v$version" -R "$REPO" --clobber "$work/gh/wabisabi-netinstall.iso" "$work/gh/SHA256SUMS"

    # The website bakes that fallback in at build time: rebuild it.
    say "rebuilding the website ($SITE_REPO)"
    if [ "$dry" = 1 ]; then
      echo "would run: gh workflow run $SITE_WORKFLOW -R $SITE_REPO" >&2
    elif ! gh workflow run "$SITE_WORKFLOW" -R "$SITE_REPO"; then
      echo "release: could not start the website build; its download card falls back to the previous release until 'gh workflow run $SITE_WORKFLOW -R $SITE_REPO'" >&2
    fi
    say "published v$version (keeping $keep version(s))"
    ;;
esac
