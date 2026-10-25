---
title: A fleet restore ran out of memory in the 8 GB install VM
type: observation
status: spotted
spotted: 2026-10-25
---

# A fleet restore ran out of memory in the 8 GB install VM

Seen while building the restore-kit VM test (2026-10-25, `./scripts/test-install-vm.sh --restore-kit`, netinstall autotest ISO, the test fleet's `laptop`). After the kit was opened, the key proved, the host key placed and the disk partitioned by disko, `nixos-install` was killed by the kernel's OOM killer 791 s in: `Out of memory: Killed process (nix) anon-rss:1954536kB`, while it was copying and building the system (chromium, webhands, wherever's pnpm deps). The install stopped with the disk already formatted. The same run with `INSTALL_MEM=16384` completed (1146 s, kit erased, `WABISABI_INSTALL_OK`).

Why it matters: the live system's store is tmpfs, so everything the install fetches and evaluates on the live side is RAM, on top of nix's own evaluation (about 2 GB RSS here). An 8 GB laptop installing from the netinstall ISO may hit the same wall, and it hits it AFTER partitioning, which is the worst place to fail. The installed closure grew on 2026-10-25 (reading apps and scanning on by default, the new tool groups in the offline payloads), which may be what pushed this over; the restore-fleet variant was last run at 8 GB on 2026-09-28 and passed.

Not established: whether the plain and restore variants now fail at 8 GB too, and how much of the RAM is the tmpfs store versus nix itself. Options to weigh: a swap file on the target once it is mounted (the target disk has room, and it exists before nixos-install runs), building with `--store /mnt` so fetched paths land on the target, or a lower `max-jobs` on the live side. The harness default stays 8192 so the problem stays visible; `INSTALL_MEM` overrides it.
