# SpectArk — Roadmap / TODO

The core is complete: realtime + scheduled backups with the history engine (every change
protected within seconds, a restore point at most every 15 minutes, Time Machine thinning —
[`docs/INCREMENTAL_ENGINE_DESIGN.md`](docs/INCREMENTAL_ENGINE_DESIGN.md)), local + NAS
destinations, optional encryption, restore, retention, crash recovery of interrupted passes,
open at login (quietly, in the menu bar), menu-bar metrics, in-app auto-update, and notarized
distribution.

Below is what's intentionally left for later, roughly in priority order. Nothing here
is a known bug — these are enhancements.

## P2 — Deepest data integrity

- **Source APFS local snapshot for consistent reads** (torn-file prevention).
  Reading a file while it's being written can capture a half-written version. The
  fully-correct fix is to snapshot the source volume (`fs_snapshot_*`) and read from the
  frozen view. That call needs root, so it requires a privileged helper (`SMAppService`
  daemon). The engine already abstracts this behind `SourceReadSession` (currently a
  coordinated read + quiet-window), so swapping in a real snapshot session later is not a
  rewrite.

## P3 — Encrypted repo completeness

- **Journal-driven passes and checkpoint cadence for encrypted jobs.** Plaintext jobs use the
  history engine; encrypted jobs still walk the whole source and write a repo snapshot on every
  pass (DedupEngine) — the O(tree)-per-change cost the history engine removed. Give them the same
  FSEvents journal (compare only dirty folders against the parent snapshot's tree) and at most one
  snapshot per 15 minutes (design §3.9).
- **Partial (file-tree) restore** for encrypted jobs. Restore is currently all-or-nothing
  for encrypted repos; the plaintext path already has a file picker.
- **Prune / GC retention** for the encrypted repo (reclaim unreferenced blobs/packs).
  Retention thinning exists for plaintext backups but not for the dedup repo.
- **Password change** for an encrypted repo (re-wrap the key slots).

## P3 — NAS completeness

- **A writer lock another Mac left behind blocks this one for good.** The image's lock records the
  writer's host UUID; a lock from another Mac is always respected, since its process cannot be checked
  from here. If that Mac crashed or lost the share mid-pass, every pass from this Mac fails as "in use by
  another Mac" until the lock file is removed by hand. Give the lock a heartbeat (the holder rewrites it
  while attached) and treat one not refreshed for well past the lease's idle time as stale. Related: Macs
  sharing one destination folder share one image, so an open restore window on one Mac (it holds the
  image, and so the lock) keeps the others' passes waiting; one image per Mac, as Time Machine does,
  would remove that contention altogether.
- **Compact NAS images after retention.** APFS inside a sparsebundle returns no bands to the share
  on its own (measured: deleting 300 MB inside an image left it at 325 MB until `hdiutil compact`,
  which took it to 21 MB). Removing a job's backups or migrating them to the encrypted repo already
  compacts (or removes) the image (`SparsebundleManager.detach(_:reclaim:)`); versions retention drops
  inside the image are not given back yet. Track what retention freed in the image and compact when the
  lease detaches an idle image after enough was freed — under the writer lock, like the other reclaims.

## P4 — Robustness / nice-to-have

- **Bit-rot scrub** — periodically re-hash stored backups (current/ and versions/) to detect silent
  corruption.
- **Battery / sleep gating** — option to skip or defer passes on battery; resume on wake.
- **NAS link-speed metric** — show throughput as a % of the NIC link speed for NAS jobs.
