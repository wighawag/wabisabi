# The flake.lock (and matching input URL) the installer writes into the user's
# new flake.
#
# WHY THIS IS SYNTHESISED RATHER THAN RESOLVED ON THE TARGET. If the installed
# flake arrived unlocked, the machine's first `nixos-rebuild` would resolve
# `nixos-unstable` to whatever is current that day, download a second nixpkgs
# and rebuild the world -- from a different revision than the one that was
# just installed and tested. Worse, an offline install could not resolve it at
# all. So the ISO ships a lock pinned to exactly the inputs it was built from:
# the machine you booted is the machine you get, and `nix flake update` later
# is a decision its owner makes rather than a side effect of first boot.
#
# It is derived from this repo's own flake.lock by promoting the root node to
# a `wabisabi` node and giving the user's flake a new root over the same input
# nodes. Same revisions, same narHashes, so the store paths the medium carries
# are exactly the ones the target flake asks for. (A GitHub tarball and a
# clean local checkout of the same revision produce an identical narHash and
# an identical store path, which is what makes this work offline.)
#
# TWO MODES, and the difference is visible in the installed flake rather than
# hidden:
#
#   committed tree -> wabisabi is pinned as github:wighawag/wabisabi at that
#                     revision. The normal case, and an ordinary flake that
#                     `nix flake update` can move forward.
#
#   dirty tree     -> wabisabi is pinned as a path: into the medium's own
#                     store. The installed machine is then self-contained and
#                     reproduces the exact tree the ISO was built from,
#                     including uncommitted edits, which is what you want when
#                     testing an installer and never what you want to hand to
#                     someone else. The generated flake says so in its input
#                     URL rather than pretending to be a release.
#
# The second mode is also the mechanism that would serve a PRIVATE repository,
# where `github:` is not fetchable by the person installing.

{
  lib,
  runCommand,
  jq,
  self,
}:

let
  rev = self.rev or null;
  dirty = rev == null;

  url = if dirty then "path:${self}" else "github:wighawag/wabisabi";

  lockedNode =
    if dirty then
      {
        type = "path";
        path = "${self}";
        narHash = self.narHash;
      }
    else
      {
        type = "github";
        owner = "wighawag";
        repo = "wabisabi";
        inherit rev;
        narHash = self.narHash;
        lastModified = self.lastModified or 1;
      };

  originalNode =
    if dirty then
      {
        type = "path";
        path = "${self}";
      }
    else
      {
        type = "github";
        owner = "wighawag";
        repo = "wabisabi";
      };
in

runCommand "wabisabi-target-lock"
  {
    nativeBuildInputs = [ jq ];
    ourLock = ../flake.lock;
    templateFlake = ../template/flake.nix;
    locked = builtins.toJSON lockedNode;
    original = builtins.toJSON originalNode;
    inherit url;
    passthru = {
      inherit dirty url;
      rev = if dirty then "dirty" else rev;
    };
  }
  ''
    mkdir -p $out
    printf '%s' "$url" > $out/url

    # THE TEMPLATE AND THIS FILE DESCRIBE THE SAME INPUT GRAPH IN TWO PLACES,
    # and nothing else ties them together. Add an input to template/flake.nix,
    # drop nixos-hardware, or change which inputs follow, and the lock written
    # below becomes one nix considers stale -- which, because the install runs
    # with --no-update-lock-file, fails AFTER the disk has been partitioned,
    # and on offline media fails always. Catch it at build time instead.
    declared=$(sed -n '/^  inputs = {/,/^  };/p' "$templateFlake" \
      | grep -oE '^    [a-zA-Z0-9_-]+' | tr -d ' ' | sort -u | tr '\n' ' ')
    expected="home-manager nixos-hardware nixpkgs wabisabi "
    if [ "$declared" != "$expected" ]; then
      echo "lock.nix: template/flake.nix declares inputs [$declared]" >&2
      echo "          but this file writes a lock for      [$expected]" >&2
      echo "          Update the root inputs in lock.nix to match, or the installed" >&2
      echo "          machine gets a lock nix rejects after its disk is already wiped." >&2
      exit 1
    fi

    for follow in nixpkgs home-manager nixos-hardware; do
      grep -q "inputs.$follow.follows = \"$follow\";" "$templateFlake" || {
        echo "lock.nix: template/flake.nix no longer makes wabisabi follow '$follow'." >&2
        echo "          The lock written here says it does, which makes it stale." >&2
        exit 1
      }
    done

    # NODE NAMES ARE ARBITRARY, and assuming otherwise is a trap worth naming:
    # nix disambiguates duplicates by appending _2, so in this repo's own lock
    # the root's nixpkgs is "nixpkgs_2" while plain "nixpkgs" belongs to
    # nixos-hardware. Hardcoding the obvious names silently pinned installed
    # machines to a DIFFERENT nixpkgs revision than the one that was built and
    # tested. So every reference below is resolved through the root's actual
    # input map instead of guessed.
    jq \
      --argjson locked "$locked" \
      --argjson original "$original" \
      '
        .nodes.root as $ourRoot
        | $ourRoot.inputs as $ours

        # The template collapses wabisabi'"'"'s nixpkgs, home-manager and
        # nixos-hardware onto its own with `follows`. The lock has to say the
        # same thing, or nix calls it stale and re-resolves -- which on an
        # offline install is a failed install, and on a networked one silently
        # installs something other than what was tested.
        | .nodes.wabisabi = {
            inputs: ($ours | with_entries(
              if (.key == "nixpkgs" or .key == "home-manager" or .key == "nixos-hardware")
              then .value = [.key]
              else .
              end
            )),
            locked: $locked,
            original: $original
          }
        | .nodes.root = {
            inputs: {
              nixpkgs: $ours.nixpkgs,
              "home-manager": $ours["home-manager"],
              "nixos-hardware": $ours["nixos-hardware"],
              wabisabi: "wabisabi"
            }
          }
      ' "$ourLock" > $out/flake.lock

    # A lock that points at a node which is not there is a machine that cannot
    # rebuild. Catch it here rather than in a VM an hour later.
    jq -e '.nodes as $nodes | .nodes.root.inputs | to_entries | all($nodes[.value] != null)' \
      $out/flake.lock > /dev/null \
      || { echo "lock.nix: produced a lock with a dangling root input" >&2; exit 1; }

    jq -e '.version == 7 and .nodes.wabisabi.locked.narHash != null' $out/flake.lock > /dev/null \
      || { echo "lock.nix: produced a lock without a pinned wabisabi" >&2; exit 1; }
  ''
