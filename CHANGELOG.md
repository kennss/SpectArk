# Changelog

All notable changes to SpectArk are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/), and the project uses
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Changed
- **A new backup engine: every change protected within seconds, a restore point at most every
  15 minutes.** SpectArk used to make a complete snapshot of the whole folder on every change, so saving
  one file cost as much as backing up everything (on a large developer folder: over 30 s of cloning per
  pass, back to back). Now the backup keeps an up-to-date copy of your folders and moves the versions a
  change replaces into its history; only the changed files are copied. Which folders changed comes from
  the macOS file-system journal — including changes made while SpectArk was not running — so a pass
  that finds one edited file looks at one folder instead of walking the whole tree. Like Time Machine,
  every restore point of the last 24 hours is kept, then one per day for a month and one per week after
  that; a state you leave alone for a while always gets its own restore point, and Back Up Now always
  makes one.
- **Open at login** (Settings ▸ General, or the prompt on a realtime backup): after a restart SpectArk
  starts quietly in the menu bar — no window, no Dock icon — and realtime backup simply continues.
- The latest backed-up state is a normal folder you can open in Finder (click the destination card).
- **NAS backups show their timeline and restore in the app.** Their history lives inside the backup
  image on the NAS, which SpectArk now keeps attached while anything uses it — a backup, the timeline,
  the restore window — and detaches a few minutes after (and before the Mac sleeps, and when you quit).
  Removing a NAS backup's data gives its space back on the NAS.
- **A backup destination is found wherever macOS mounts it.** A NAS share remounted as
  `/Volumes/home-1`, or a drive that comes back as "Backup 1", used to leave its backups "not
  connected" until the job was set up again. The destination folder now carries a small hidden marker
  (`.spectark-destination`), and SpectArk follows it to wherever the folder turns up; when it comes
  back, backups resume on their own. A different share mounted under the same name is recognised as
  someone else's folder and never written to.
- **Existing backups carry over.** On the first pass the new engine starts from your newest snapshot
  (cloned, so it takes no extra space on APFS) and copies only what changed since. Your earlier
  snapshots stay on the same timeline — browsable and restorable — until the retention policy ages
  them out; a "keep N" policy counts old snapshots and new restore points together.
- Turning on encryption also converts the new engine's restore points, not just earlier snapshots.
- Automatic retention counts days in your local time, from 5 AM to 5 AM, so a late night of work is one
  day's restore point rather than two; it used to split days at midnight UTC.

### Fixed
- **A file locked in Finder no longer stops a backup**, and restoring it puts the lock back. Restoring
  over a locked file works, and a restore that fails leaves the existing file exactly as it was.
- **Turning on encryption after an interrupted attempt removes all of the plaintext.** Restore points the
  first attempt had already encrypted were skipped the second time — and so were left behind unencrypted,
  without being counted. Turning on encryption for a NAS backup now converts the backups inside its image
  too; they used to be left there as they were.
- **NAS backups no longer stop for good after a crash.** The NAS image's writer lock recorded only a
  process number; after a crash and a reboot, when a system process happened to get the same number,
  every later backup to that NAS failed as "locked by another writer". The lock now records the
  writer's start time and the Mac's hardware ID, and an old-format lock counts only while its process
  is SpectArk.
- **Realtime backup no longer runs non-stop on developer folders.** Every filesystem event started a
  full pass — including Git's `.git/index.lock`, which editors and tools create and remove every few
  seconds while polling `git status`. The watcher now ignores changes the backup would skip anyway
  (Git lock files, Finder metadata, anything excluded), so only real changes wake a pass.
- **No change is left un-backed-up any more.** Previously a change that arrived during a running pass
  was dropped; files still being written were deferred with nothing to pick them up later (a file
  written every few seconds — a database, a log — was never backed up at all); a file saved every
  second postponed all backups indefinitely; and changes made while SpectArk was not running, or
  before a backup was switched to realtime, waited for some unrelated edit. Now a busy pass is always
  followed up, deferred files get a "settle" pass that copies them regardless, a pass starts at most
  60 s after the first change, and a catch-up pass runs at launch and when a backup starts running in
  realtime or what it backs up changes. A failed pass is retried (1, 2, 4 … up to 30 minutes).
- **Automatic passes are spaced by their own duration** (at most 5 minutes), so they never take more
  than about half the time. "Back Up Now" is never delayed by this.
- **A source that is ejected mid-pass no longer produces a snapshot in which everything looks deleted**
  — the pass fails and is retried. A file or folder that a build or git deletes while a pass reads the
  source is simply absent from that snapshot instead of failing the pass.
- **Files SpectArk cannot read now fail the pass with a clear message** instead of silently dropping
  out of the backup (and out of the newest snapshot).
- **Files with a modification date in the future are backed up.** They were deferred as "still being
  written" on every pass — including manual ones — and never copied (camera clocks, extracted archives).
- Git lock files are never backed up — a stale `index.lock` restored from a backup blocks git.
  (git-annex objects, which keep a file's `.lock` extension, are still backed up.)
- Restore copies a snapshot exactly as recorded, without applying backup-time exclusions.
- Launch cleanup no longer deletes the catalog row of a pass this run has already started.

### Improved
- **Skip rebuildable files** (new setting, on by default): dependency folders, build outputs and
  caches are left out — `node_modules`, `__pycache__`, `.dart_tool`, Python `site-packages` inside a
  virtualenv, Flutter/Gradle `build`, Cargo/Maven `target`, CocoaPods `Pods`, Gradle `.gradle`, SwiftPM
  `.build`, Xcode's `Build` output, caches and package checkouts, and folders with a `CACHEDIR.TAG`. A folder is skipped
  only when the tool that owns it is recognized (its manifest beside it or its own marker inside it),
  and never when it may also hold your work: a source folder that happens to be called `build`, the
  Gradle home `~/.gradle`, Xcode `build` folders holding release archives, a project using Xcode's
  "Relative to Workspace" build location, and a project or scripts living in a virtualenv folder are
  all still backed up. The macOS "exclude from backups" flag is intentionally not used: Photos sets it
  on its library's database. On real developer folders this cut a pass's walk from 722 k entries
  (38 s) to 105 k (4.3 s).
- Encrypted backups now apply the same exclusions as plaintext ones (previously they ignored even the
  built-in exclusions).
- Error messages for SpectArk's own file operations now say what went wrong (permission, disk full,
  disconnected) instead of a generic failure.

### Development
- Running the unit tests no longer acts on the developer's real backups. The tests are hosted by the
  app itself, which used to load the real configuration, watch the real sources, clean up catalog rows
  on the real destinations, start Sparkle, and — asking for Desktop access with a debug signature —
  replace the installed SpectArk's privacy grant.

## [1.1.4] — 2026-07-05

### Improved
- **Right-click any backup** in the sidebar to reach its actions — Back Up Now, Restore,
  Settings, Remove — without having to select it first. The ⋯ button also highlights on hover.
- **Click a backup's source or destination** card to open it in Finder. The destination card
  opens straight to that backup's snapshot folders, so your point-in-time versions are one click away.

## [1.1.3] — 2026-07-01

### Fixed
- **The window opens at a sane size on every launch** (and stays freely resizable). The real cause
  was SwiftUI wiring the window's id as its AppKit *frame-autosave name*, so an out-of-bounds saved
  frame was restored over `.defaultSize` each launch — earlier attempts targeted the wrong mechanism.
  It now severs that autosave, purges the stale saved frame, and opens centered and fit to the screen.
- **Full Disk Access is detected correctly.** macOS 15/26 blocks reading the TCC database even with
  FDA granted, so the previous probe always reported "not granted." Detection now lists an ordinary
  protected folder (which FDA actually unlocks), so the onboarding card no longer shows when access is
  already granted. The card is also dismissible.
- Fixes a launch crash introduced in the withdrawn 1.1.2 (the window resize ran inside AppKit's layout pass).

## [1.1.2] — 2026-07-01 [pulled]

Withdrawn — crashed on launch. Superseded by 1.1.3.

### Fixed
- Attempted to make the 1.1.1 window fix hold by disabling frame restoration and re-fitting an
  oversized window (the previous `maxSize` cap didn't constrain SwiftUI's programmatic restore).
- Full Disk Access is now detected by really opening the TCC database (which goes through the
  permission system) instead of `access()`, which reported "not granted" even when it was. The
  onboarding card is also dismissible ("Already have access? Dismiss") so a wrong reading never
  blocks you.

## [1.1.1] — 2026-07-01

### Added
- Click the SpectArk logo (top-left) to return to the start screen.

### Fixed
- The window no longer opens larger than the screen (it's capped at the screen size and re-centered).
- A destination (NAS share or external disk) that isn't mounted now shows a "not connected" reconnect
  card instead of a misleading "grant Full Disk Access" message.
- Full Disk Access onboarding: correct app name, guidance to quit and reopen after granting, a
  "Quit & Reopen" button, and an automatic re-check so the card clears itself once access is effective.

## [1.1.0] — 2026-07-01

### Added
- **Resume interrupted backups.** If a backup stops midway (quit, crash, drive
  unplugged), the next run continues from where it left off instead of restarting
  from scratch.
- **In-app auto-update** (Sparkle). SpectArk checks a signed appcast for newer
  notarized builds and can update itself — *Check for Updates…* in the app menu and
  the menu-bar dropdown.
- **Back Up Now** button in the job detail view.

### Fixed
- NAS / network (SMB) volumes now show their real free space in the sidebar and
  menu bar instead of "Zero KB free".
- The window no longer opens larger than the screen on launch (an oversized restored
  frame is shrunk to fit and re-centered).

## [1.0.0] — 2026-06-30

First public release. Rebranded from SpectaBackup to **SpectArk** (display name only;
the bundle id and existing backups carry over).

### Added
- **Realtime or scheduled** backups per job — watch a folder live (FSEvents) and
  snapshot on change, or run on an interval.
- **Versioned snapshots** (Time Machine style), unchanged data shared via APFS
  clones / hardlinks.
- **Any source → any destination** — local disk or NAS, no dedicated backup drive
  required.
- **Optional encryption** — content-defined chunking + dedup, AES-256-GCM with
  argon2id-derived keys, and a one-time recovery key. Off by default (snapshots stay
  browsable plaintext).
- Dashboard window + menu-bar dropdown with live throughput and free space.
- Developer ID signed and notarized; universal (Apple Silicon + Intel), macOS 14+.

[1.1.4]: https://github.com/kennss/SpectArk/releases/tag/v1.1.4
[1.1.3]: https://github.com/kennss/SpectArk/releases/tag/v1.1.3
[1.1.1]: https://github.com/kennss/SpectArk/releases/tag/v1.1.1
[1.1.0]: https://github.com/kennss/SpectArk/releases/tag/v1.1.0
[1.0.0]: https://github.com/kennss/SpectArk/releases/tag/v1.0.0
