---
title: A username that is a common word fails the anon-home content check, after the disk is wiped
type: observation
status: spotted
spotted: 2026-09-28
---

# A username that is a common word fails the anon-home content check

Seen while building the restore VM test (2026-09-28). A config whose owner is `wabisabi.user = "owner"` does not build: nixos-modules' `anonHome` assertion reports that `.bash_profile` for an anon home "contains \"owner\"". The check (nixos-modules `modules/anon-home*.nix`) scans the files it places into anon homes for the operator's username as a plain substring, and the literal word "owner" occurs in that file's text (most likely a comment). So the collision is with prose, not with anything that leaks the account.

Why it matters:

- Any username that is an ordinary English word appearing in those files (`owner` confirmed; `user`, `home`, `admin` are candidates, not tested) makes the machine unbuildable, with an error that tells the person their own name leaked into an anon home.
- On a **fresh install** it fails at the build step, AFTER partitioning: the installer's username validation (installer/install.sh, the system-account `case`) knows nothing about it, and the fresh path does not evaluate the whole system before touching the disk. The restore path now does (`restore_prepare` evaluates `system.build.toplevel.drvPath` first), which is how this was confirmed to be caught pre-disk there.

Possible directions, none decided: match whole words / identifier boundaries rather than substrings; strip comments before scanning; have the installer evaluate the generated config (or at least run this assertion) before partitioning on the fresh path too, as restore does.

Refs: `.vm/install-test/restore-install.log` of the first restore run; fixture changed from `owner` to `mira` in flake.nix (`restoreFixture`) to get past it.
