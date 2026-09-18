# History Engine — Continuous Protection + 15-Minute Checkpoints

Status: **approved 2026-09-18 · implemented (phases 1–5) — the app backs up with this engine** ·
Author: Kennt Kim

## 1. Intent

SpectArk behaves like Time Machine — a timeline of past states of the backed-up folders, thinned over
time — except that a backup is triggered by **changes in the watched folders**, not by a schedule.

## 2. Why the current engine cannot deliver that

Time Machine's unit of work is "a complete point-in-time copy of everything". Once an hour that is
affordable. SpectArk 1.1.4 kept the same unit but runs it on every change, so saving one file pays for
a complete copy of the tree:

- Each pass clones the previous snapshot tree (APFS has no directory hard links, so a new tree costs
  one entry per file), walks the source, walks the new tree for deletions, and deletes the whole tree
  again when nothing changed.
- Measured 2026-09-18: 722 k entries in ~/Desktop/Developments, > 30 s for the clone alone, passes
  back to back (~43 % CPU sustained, 7.6 CPU-hours in two days), 94 M inodes on the backup disk.
- The realtime-trigger work of 2026-09-18 (ChangeFilter, PassScheduler, artifact exclusion) removed
  needless passes and shrank the tree 7–16×, but a pass is still O(size of tree).

Modern Time Machine avoids this by snapshotting the backup volume (APFS) instead of copying the tree.
The deeper fix for a change-triggered app is to **split what Time Machine does in one step**:

| | Protection | History |
|---|---|---|
| Question it answers | "Is my latest work safe?" | "Can I go back to how it was?" |
| Trigger | every relevant change (seconds) | at most one checkpoint per 15 minutes |
| Cost | the changed files only | recording a number — no copying |

## 3. Design

### 3.1 Layout at the destination (per job)

```
<destination>/SpectaBackup/<job-id>/
  current/<source-name>/…     the mirror: an exact, browsable copy of the source, updated in place
  versions/<shard>/<name>     superseded file versions, moved (never copied) out of current/
  history.sqlite              catalog: entries, versions, checkpoints, intents, cursor
  snapshots/…, catalog.sqlite legacy (1.1.x) per-snapshot trees — read-only after migration (§6)
```

The engine itself needs only `rename` within one volume — no clonefile, hard links or volume
snapshots. **NAS destinations keep the APFS sparsebundle** (decided 2026-09-18): the engine runs inside
the mounted image exactly as on a local disk. Writing to the SMB share directly would put
`history.sqlite` on a network filesystem (SQLite and Apple both warn against it: locking and cache
coherence) and lose metadata SMB does not carry (xattrs, BSD flags, permissions) — the reasons Time
Machine uses sparsebundles on NAS too. The cost: `current/` of a NAS job is browsable in Finder only
while the image is mounted.

### 3.2 Generations and checkpoints

- The catalog keeps a **pending generation** `g` (starts at 1). A **checkpoint** seals generation `g`
  at a moment when `current/` exactly matched the source (the end of a successful pass); then `g += 1`.
- Every present item (`entries`) has `born` = the generation in which this version entered
  `current/`. Every retired item (`versions`) has `[born, died)`: it belongs to checkpoints
  `born … died-1`.
- When a capture pass replaces or deletes an item:
  - `born < g` (it is part of at least one checkpoint) → move its file into `versions/` and record
    `[born, g)`;
  - `born == g` (it appeared after the last checkpoint and is superseded before the next) → unlink
    it. Intermediate versions between checkpoints are not history, exactly like Time Machine.
- The state at checkpoint `c` is `entries(born ≤ c) ∪ versions(born ≤ c < died)` — reconstructed from
  the catalog, never materialised unless restored.

### 3.3 When checkpoints are sealed

`spacing = 15 min`. A generation is sealed only if it contains changes:

1. At the **end** of a pass: if `now − lastCheckpoint ≥ spacing` → seal at `now`.
2. At the **start** of a pass, before applying anything: if the previous pass left unsealed changes and
   `now − lastCheckpoint ≥ spacing` → seal them at the end time of that previous pass. This preserves
   a state that stood unchanged for a long time (edited at 10:05, next edit at 11:00) without a timer.
3. "Back Up Now" seals at the end of its pass regardless of spacing — an explicit restore point.

Result: at most one checkpoint per 15 minutes while you keep working, plus one for each state that was
then left alone; nothing is recorded while nothing changes.

### 3.4 Capture pass

1. **Discover** what to compare: the whole source (full scan) or only the directories FSEvents reported
   (§3.7). The source walk reuses FileWalker (exclusions, vanished-entry tolerance, root-identity
   check) and the quiet-window rule (SourceReadSession).
2. **Plan** by comparing source items with catalog entries (kind, size, mtime): add directory,
   put file (new or changed), remove item (deepest first). Items the job now excludes are removed from
   `current/` (and kept in `versions/` if a checkpoint contains them).
3. **Apply** in batches (§3.5), then seal (§3.3). Cost: the listings of the reported directories plus
   work proportional to the changes; no tree is cloned, walked twice or deleted. A full scan walks the
   source once (2.5–4.5 s for Developments after exclusions).

### 3.5 Crash safety

Filesystem changes cannot join an SQLite transaction, so each operation is logged as an **intent**
before it touches `current/` and resolved after:

1. Commit intents for a batch (e.g. 500 operations).
2. For each: copy the new file to a temp name beside its target, `fsync` it; move the old file to
   `versions/` (or unlink it); rename the temp over the target.
3. One `F_FULLFSYNC`, then one transaction that updates `entries`/`versions` and deletes the intents.

At the start of the next pass, leftover intents are resolved one by one from what is on disk (temp present? old moved? target
matches the old metadata?) — rolled forward when the new file is fully in place, rolled back otherwise.
A catalog row never points at data that is not on stable storage. Durable cost: two full syncs per
batch, not per file.

### 3.6 Retention

- Checkpoints: Time Machine thinning — all within 24 h (≤ 96 at 15-minute spacing), the newest per day
  for 30 days, the newest per week after that; the existing space rules (minimum free space, quota)
  drop the oldest first. The newest checkpoint and `current/` are never pruned.
- A version is deleted when no kept checkpoint lies in its `[born, died)`.

### 3.7 Change discovery (FSEvents journal)

- `history.sqlite` stores a cursor per source: the FSEvents UUID of the source volume + the last event
  ID whose changes are in `current/`. Each pass replays the journal from its cursor on a short-lived
  stream (`sinceWhen = cursor`, until `HistoryDone`, then one `FlushSync`), so changes made while
  SpectArk was not running are found without a full scan. The live watcher only decides *when* a pass
  runs; *what* it compares always comes from the replay.
- The next cursor is the last event ID actually received — never "now". An event that had not reached
  fseventsd when the pass started has a larger ID and is replayed by the next pass (which the watcher
  schedules for it anyway), so nothing is lost to that race.
- Replayed events go through the job's ChangeFilter first: churn inside excluded folders (e.g.
  `node_modules`) makes nothing dirty, but still advances the cursor.
- Events become dirty directories: the parent of each changed item (its listing changed), plus the
  item itself for a directory event; `MustScanSubDirs` marks a recursive rescan. A pass lists each
  dirty directory one level deep; a directory that vanished or changed kind is resolved from its
  parent's listing (so a rename is a removal plus a new folder).
- **The journal says where to look, never what is there.** A reported directory is compared as itself
  only if its path reaches it without a symlink and in the letter case stored on disk (its realpath is
  exactly `<source>/<path>`), it is a directory, nothing on the path is excluded, and the pass is not
  removing it; otherwise its parent's listing decides. Event paths carry the names of the moment the
  event happened, so after a rename, a case-only rename or a folder replaced by a symlink they name
  something else now.
- **Directory identity.** Each catalog directory stores the source directory's inode as of the last
  pass that compared its whole subtree and finished (0 = never). A directory is compared whole when it
  is new or its inode differs: another directory now carries the name (`mv a tmp; mv b a`, package
  safe-saves, app updates — FSEvents reports only the swapped paths, not their contents), or an
  interrupted pass added it but never finished it (the retry replays the same span, so without this it
  would see the folder as known and never descend). The source folder's own inode is checked before
  every journal pass: replacing it, or a folder above it, leaves no event under its path.
- **Rule markers.** Every content-based artifact rule declares its marker files and the folder a change
  to them affects (`ArtifactRules.markerReach`): a CACHEDIR.TAG or SwiftPM `workspace-state.json` →
  the listing of the tagged folder's parent; Xcode's `Build/Intermediates.noindex` → Build's parent
  (Build and the caches beside it); `pyvenv.cfg` → the whole venv (site-packages is two levels down).
  Marker events are read before filtering, since the marker's own event is hidden by the folder it
  excludes.
- A file deferred by the quiet window produces no further event, so its directory is **carried**: stored
  in the catalog and compared again by the next pass.
- **Full scan** when there is no cursor, the volume UUID changed (journal reset), the source folder is
  not the verified directory, events were dropped, IDs wrapped, a volume was mounted or unmounted
  beneath the source, an event lies outside every spelling of the source folder (as configured,
  realpath, and without the `/System/Volumes/Data` firmlink prefix), the replay did not finish within
  30 s, the job's settings (sources, exclusions) or the app's built-in rules (`rulesVersion`) changed —
  no file event announces a newly included folder — and once a day as a safety net. A source on a
  volume without an FSEvents journal (e.g. a network share) is fully scanned every pass. Time Machine
  likewise falls back to a "deep traversal" when the journal cannot be trusted.
- **Nothing is written through a symlink inside `current/`.** Before each operation the parent's
  realpath must be the parent itself; the plan never produces such a path, the check covers the source
  changing between planning and applying, and recovery rolls back an intent that fails it.
- Measured 2026-09-18 (real repos, 3–4 k entries): unchanged pass 0.08–0.21 s, one-file change
  0.05–0.19 s, one directory listed. A full walk of Developments (107 k entries) is 2.5–4.5 s.

### 3.8 Restore and browse

- Latest: `current/` is a normal folder — Finder, or the app.
- Any checkpoint: the app lists a directory from the catalog (`entries`/`versions` valid at `c`) and
  restores by copying from `current/` or `versions/`. Restore never applies exclusions.

### 3.9 Encryption

Encrypted jobs keep the content-addressed repo (DedupEngine). They adopt the same journal and
checkpoint cadence later; their storage format is unchanged.

## 4. Alternatives considered

- **APFS volume snapshots of the destination** (how Time Machine stores history since Big Sur). O(1)
  snapshots, but `fs_snapshot_create` needs an Apple-granted entitlement and a root helper; snapshots
  are per volume, so every job on the disk — and any unrelated files on it — share them; older states
  need a mount to browse; NAS needs an APFS sparsebundle. The version store gives the same timeline
  with none of these requirements.
- **Per-snapshot trees** (1.1.x). Browsable in Finder, but O(tree) per snapshot — the problem itself.
- **Dedup repo for plaintext jobs.** O(changed directories), but not browsable at all; kept for
  encryption.

## 5. Known limits (deliberate, revisit later)

- Change detection is size + mtime, as in 1.1.x: a metadata-only change (permissions, xattrs) is not
  captured until the content changes.
- Hard links inside a source are stored as independent files (content preserved, link not).
- A file written continuously is captured at most once per settle pass (quiet window); a consistent
  read of such files needs source snapshots (TODO P2).

## 6. Migration from 1.1.x

Per job, on the first pass of the new engine (`HistorySeeder`, then a normal pass):

1. **Seed** `current/` from the newest legacy snapshot, walked with the job's *current* exclusions:
   1.1.x trees predate the artifact rules (Developments: ~722 k entries vs ~107 k backed up now), and
   seeding them whole would make the first pass remove the difference one intent at a time. Each item is
   cloned (APFS, locally and inside a NAS sparsebundle — no extra space), else hard-linked, else copied;
   rows come from lstat of the seeded items (legacy trees keep size and mtime, which is what the pass
   compares), every item is fsynced, and the catalog commit comes last. Measured: ~0.3 ms per entry on
   the internal SSD (~Working, 75 k entries: 21 s), then a first full pass that copies nothing.
2. The seed runs only on a pristine catalog; an interrupted seed leaves a pristine catalog, and the
   engine clears anything under a pristine catalog before a pass, so no untracked leftovers survive.
   A seed is an optimisation: if it fails, the first pass copies the whole source.
3. The seeded state is **not** an unsealed change — the legacy snapshot already is that restore point.
   Checkpoint 1 is sealed by the first pass that changes something (or by Back Up Now after a change).
4. Legacy snapshot trees are no longer written. They stay browsable and restorable in the app and share
   one timeline with the checkpoints: the retention policy thins legacy snapshots and checkpoints
   together ("keep 10" keeps the ten newest restore points of either kind), space pressure drops the
   oldest first — the legacy ones — and the newest restore point is always kept. `.inprogress-*`
   partials of the old engine are discarded.
5. Turning encryption on re-encrypts every plaintext restore point into the repo — legacy snapshots, then
   each checkpoint and the unsealed latest state, rebuilt as a cloned folder tree
   (`HistoryMaterializer`) — and deletes the plaintext only after all of them succeeded.

## 7. Phases

1. **Engine core** — `history.sqlite` store, capture pass (full scan), generations and sealing,
   intents and recovery. *(done)*
2. **Retention and pruning; restore/browse API** over checkpoints. *(done)*
3. **FSEvents journal cursor and dirty-directory scans.** *(done)*
4. **Migration, UI (timeline, browse checkpoints and legacy snapshots), switch jobs to the new
   engine.** *(done)* NAS jobs run the engine inside their sparsebundle; listing and restoring their
   history in the app needs the image attached for browsing (TODO).
5. **Remove the per-snapshot writing path** (SnapshotEngine and its retention planner); legacy trees
   remain readable until they age out. *(done)*

## 8. To verify during implementation

- Throughput of the batched intent scheme on the external SSD and over SMB (target: an initial seed of
  Developments in minutes, a one-file pass in well under a second after the walk).
- FSEvents replay limits (how long the journal keeps history; behaviour on removable source volumes).
- Replay time after a long absence (days of volume-wide events since the cursor) against the 30 s
  timeout; only short spans have been measured so far.
