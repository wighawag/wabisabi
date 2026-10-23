#!/usr/bin/env bash
# Regenerates the committed boot artwork (see generate.mjs). The fonts come
# from this flake's own nixpkgs, so the output does not depend on what is
# installed on the machine running it.
set -euo pipefail
cd "$(dirname "$0")"

root=$(cd .. && pwd)
nixpkgs=$(nix eval --raw --impure --expr "(builtins.getFlake \"$root\").inputs.nixpkgs.outPath")
fraunces=$(nix build --no-link --print-out-paths "path:$nixpkgs#legacyPackages.x86_64-linux.fraunces")

export WABISABI_FONT_SERIF="$fraunces/share/fonts/truetype/Fraunces72ptSoft-Light.ttf"
exec node generate.mjs
