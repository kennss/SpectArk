# Changelog

All notable changes to SpectArk are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/), and the project uses
[Semantic Versioning](https://semver.org/).

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
