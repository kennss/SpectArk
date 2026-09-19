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

- **Source APFS local snapshot for consistent reads.** A single file is no longer recorded torn
  (every copy is checked against its source and dropped if the source moved while it was copied),
  but files that must agree with each other — a SQLite database and its `-wal`, a Git operation in
  progress — are still copied one after another, not at one instant. The fully-correct fix is to
  snapshot the source volume (`fs_snapshot_*`) and read from the frozen view. That call needs root, so it requires a privileged helper (`SMAppService`
  daemon). The engine already abstracts this behind `SourceReadSession` (currently a
  coordinated read + quiet-window), so swapping in a real snapshot session later is not a
  rewrite.

## P3 — Encrypted repo completeness

The repo is the encrypted job's only record (RepoTimeline; no catalog at the destination). Left:

- **Remove a damaged encrypted restore point.** A snapshot object that cannot be decrypted (bit rot,
  tampering) is left alone — never deleted on its own, since it may only be unreadable for now — and while
  it is kept, garbage collection and the space rules stop (the job shows a warning). Offer the user a way to
  remove it (after a re-read confirms the damage), so a quota or free-space rule works again.
- **Partial (file-tree) restore** for encrypted jobs. Restore is currently all-or-nothing
  for encrypted repos; the plaintext path already has a file picker.
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

## P4 — Robustness / nice-to-have

- **Plaintext retention when the disk is full.** A capture pass that fails for lack of space (ENOSPC) leaves
  intents behind, and maintenance waits while intents are pending; recovery runs only at the start of the
  next pass, which fails the same way. Free space before capturing when the destination is short (seal and
  thin first, or recover then run retention), as encrypted jobs now do after a failed pass.

- **Bit-rot scrub** — periodically re-hash stored backups (current/ and versions/) to detect silent
  corruption.
- **Battery / sleep gating** — option to skip or defer passes on battery; resume on wake.
- **NAS link-speed metric** — show throughput as a % of the NIC link speed for NAS jobs.
