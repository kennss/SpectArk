# SpectArk — Roadmap / TODO

The core is complete: realtime + scheduled backups with the history engine (every change
protected within seconds, a restore point at most every 15 minutes, Time Machine thinning —
[`docs/INCREMENTAL_ENGINE_DESIGN.md`](docs/INCREMENTAL_ENGINE_DESIGN.md)), local + NAS
destinations, optional encryption, restore, retention, crash recovery of interrupted passes,
menu-bar metrics, in-app auto-update, and notarized distribution.

Below is what's intentionally left for later, roughly in priority order. Nothing here
is a known bug — these are enhancements.

## P1 — Always-on (core to the "realtime" promise)

- **Launch at login / background residency** (`SMAppService`).
  Today the app must be *running* to watch FSEvents. The menu-bar item keeps it alive
  after the window is closed, but a `Cmd-Q` or a reboot stops realtime backup until the
  user reopens the app. A login item that starts SpectArk in the background at boot is
  what makes "realtime" actually always-on. This is the most important next step.

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

- **Resolve NAS destinations by share identity, not `/Volumes` path.** macOS mounts an SMB
  share at `/Volumes/<share>`, but on remount it may use `/Volumes/<share>-1`, `-2`, … so an
  absolute destination path stored at setup time (e.g. `/Volumes/home-1/Backup`) breaks after
  the share re-mounts at `/Volumes/home`. Store network destinations by their `smb://server/share`
  identity and resolve the live mount point at backup time (match via `getmntinfo`), so remounts
  never orphan a job. Until then, a moved destination shows the "not connected" card and must be
  re-pointed by hand.
- **Sparsebundle history + restore.** NAS jobs back up with the history engine inside the image;
  listing their timeline and restoring still need the image attached (read-only) while browsing — and
  "Last backup" is unknown until the first pass after launch. Keeping the image attached while the app
  runs (instead of attach/detach per pass) would serve both and save the per-pass attach cost. Also call
  `hdiutil compact` periodically so pruned versions actually reclaim space.

## P4 — Robustness / nice-to-have

- **Bit-rot scrub** — periodically re-hash stored backups (current/ and versions/) to detect silent
  corruption.
- **Battery / sleep gating** — option to skip or defer passes on battery; resume on wake.
- **NAS link-speed metric** — show throughput as a % of the NIC link speed for NAS jobs.
