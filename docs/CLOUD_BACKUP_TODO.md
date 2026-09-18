# Cloud Backup (iCloud / Google Drive) — Design Notes & TODO

**Status: NOT IMPLEMENTED.** Design captured from an adversarial review; frozen pending two open
decisions (below). The local engine (the history engine — a mirror plus a version store,
docs/INCREMENTAL_ENGINE_DESIGN.md) is done, and NAS jobs run it inside a sparsebundle. Cloud needs a
**separate content-addressed chunk-dedup engine** (restic/Arq style): the history engine relies on
atomic rename, fsync and a local SQLite catalog on the destination, none of which iCloud or Google
Drive offer.

---

## Confirmed
- Cloud backup must keep **version history** (not a plain mirror) → chunk-dedup engine.
- Targets: **Google Drive**, **iCloud**; plus **local** and an **S3-compatible** backend as the
  engine's reference target.

## Open decisions (need owner sign-off before Phase 0)
1. **Backend priority:** S3-compatible (Cloudflare R2 / Backblaze B2) reference **first**
   (recommended — strong consistency isolates engine bugs from backend bugs) vs Google Drive first
   vs freeze-format-only.
2. **Encryption:** **ON + recovery key** (recommended — cloud is an untrusted store) vs OFF.

---

## Critical design requirements (must be settled before any code)

1. **Pack files + repo-resident, rebuildable index.** Never upload one object per chunk — millions
   of tiny objects kill Drive (per-folder/file caps, API quotas, 750 GB/day) and iCloud
   (NSMetadataQuery / sync). Aggregate encrypted blobs into ~16–64 MB **packs** under
   `data/<aa>/<packID>`, each with an **encrypted trailer** listing its blobs (type, blobID, offset,
   ciphertext len, plaintext len). `index/<indexID>` maps `blobID → (packID, offset, length)`. The
   repo is then self-describing: `rebuild-index` re-reads pack trailers; local SQLite is a pure cache.
2. **Crypto (replace naive design).** Do **not** use random-nonce AES-GCM with one master key
   (nonce reuse across devices = catastrophic). Use **per-object derived key** `objectKey =
   HKDF(masterEncKey, info=blobID)` with a deterministic nonce (no cross-device coordination needed),
   **or** AES-CTR+Poly1305 with a 128-bit random IV. Use **keyed chunk IDs** `HMAC-SHA256(repoKey,
   plaintext)` + a **per-repo random chunker seed** (prevents the provider fingerprinting content).
   **Encrypt per-blob, then pack** (so a Range read of one blob is independently decryptable).
   Store the **wrapped master key as a repo object** (`keys/<keyID>`, unlocked by an argon2id/scrypt
   password key) + **multiple key slots** + a **forced recovery key**. Keychain may *cache* the key
   for unattended runs (with a `SecAccessControl` trusting the backup helper's signing identity),
   **never the only copy** — key loss = total unrecoverable loss.
3. **GC / prune safety.** Naive mark-sweep deletes live data (a chunk unreferenced at sweep time may
   be needed by an in-flight backup; and with packs you can't raw-delete one blob anyway). Require:
   single-writer invariant (advisory repo lock `locks/<host>-<pid>-<ts>` + local lock), a **grace
   period** (never delete packs newer than `prune_start − margin` or newer than the oldest running
   backup), **repack instead of raw-delete** (rewrite live blobs into a new pack, then delete old),
   and **two-phase quarantine** delete. The **snapshot object is written LAST**, only after every
   referenced pack+index is **durably readable by ID** (not by `list`). Build prune **last** — it is
   the most dangerous code.
4. **Repo is the source of truth; local SQLite is a rebuildable cache.** Drive `list`/`exists` are
   eventually consistent (and Drive allows duplicate names + opaque fileIDs); iCloud "exists" is
   local sync state, not cloud truth. Never ground dedup/commit on `list()` — ground it on committed
   index objects, and **bias every uncertainty toward re-upload, never toward skip** (a false
   "exists" loses data; a false "absent" only re-uploads). Ship `check` + `rebuild-index`; store
   **redundant copies** of the tiny critical objects (`config`, `keys/`, `snapshots/`, `index/`).

---

## Engine details
- **Chunking:** FastCDC (gear-based — faster/simpler than Rabin/buzhash in Swift), avg ~1 MB
  (512 KB–8 MB). Stream large files in bounded windows; never load a whole file into memory.
- **Layout:** `config`, `keys/<keyID>`, `data/<aa>/<packID>` (+encrypted trailer), `index/<indexID>`
  (blobID→pack/offset/len), `trees/<treeID>` (dir tree: children + per-file ordered blob list),
  `snapshots/<snapID>` (root tree + meta: time, jobID, host).
- **Compression:** LZFSE (Apple `Compression` framework — system has **no zstd**) for v1; add zstd
  later via a per-blob compression-type byte. Skip compression for incompressible blobs.
- **Parent-snapshot fast path:** skip re-chunking unchanged files by comparing size+mtime to the
  parent snapshot's tree (the size+mtime rule the history engine uses) — big win and respects the
  750 GB/day Drive cap.
- **Consistent source read:** reuse `SourceReadSession` quiet-window deferral; large files can still
  tear across chunks (documented v1 limitation). APFS source snapshot = shared future work with the
  local engine's M3 (privileged helper).

## Backend protocol (richer than put/get/exists/list/delete)
- `putObject(key,data)` idempotent + internally resumable; `statObject(key) → {size, serverChecksum}`
  (this **is** "exists", read-your-writes by ID); `getObject(key, range?)`; `deleteObject(key)`;
  `listObjects(prefix, page) → (keys, mayBeStale)`.
- `BackendCapabilities` struct (mirror `Models/DestinationCapabilities.swift`): `supportsRange`,
  `isStronglyConsistent`, `maxObjectSize`, `dailyUploadCap`, `permanentDeleteRequired`. Engine
  degrades gracefully (e.g. whole-pack download when `!supportsRange`).

## Backend-specific notes

### S3-compatible (Cloudflare R2 / Backblaze B2) — recommended reference
Strong read-after-write, Range reads, real API, cheap (free tiers). Exactly what restic/borg assume.
Best target to prove engine correctness first.

### Google Drive (write path is net-new; whiplay is read-only)
- **Reuse:** `GoogleTokenProvider`, `GoogleDriveAccountStore` (Keychain refresh tokens), PKCE auth.
- **Net-new:** resumable upload (`uploadType=resumable`, `Content-Range`, resume via `bytes */*`),
  Range download, delete, **scope change** (whiplay uses `drive.readonly`).
- Prefer **appDataFolder** (`drive.appdata`, hidden/app-private → user can't corrupt repo in Finder)
  or `drive.file`. Avoid full `drive` scope (heavy Google verification). Avoid shared drives.
- **Rate limits:** 403 `userRateLimitExceeded`/`rateLimitExceeded`, 429 — exponential backoff +
  jitter, honor `Retry-After`; token bucket; upload concurrency 4–8.
- **750 GB/day** upload cap → initial seeding takes days; surface in UI, throttle (don't look hung).
- **Permanent delete** for pruned objects (default trash bills quota 30 days).
- Opaque fileIDs; keep a local `key → fileID` map. `create → get-by-ID` is read-your-writes;
  `list` is not.

### iCloud — Drive container is the WRONG primitive
- iCloud Drive: **no server API**, **no Range read** (proven by whiplay's `iCloudMaterializer` —
  full-file download only), `list`/`exists` reflect local sync state not cloud truth, "Optimize Mac
  Storage" can evict the repo to dataless placeholders, conflict copies, no locking, 5 GB free tier.
- **Recommendation:** use **CloudKit** (private DB, custom zone, `CKRecord` metadata + `CKAsset`
  blobs) for a real server API, atomic per-zone saves, and change tokens. Otherwise mark iCloud-Drive
  support **phase 3, best-effort, whole-file restore only** — do not pretend it's an object store.

## Phasing
- **Phase 0 — freeze format (paper, not code):** repo layout, object formats incl. pack trailer,
  crypto construction, chunker seed, version/feature flags. Cheapest place to fix the above.
- **Phase 1 — engine on LocalBackend + S3-compatible:** FastCDC, packs, per-blob AEAD, dedup grounded
  in committed index, snapshot/tree/restore, `check`/`rebuild-index`. **Fault-injection tests**
  (crash mid-pack, partial/aborted upload, delayed & reordered `list`, duplicate names). **Stub
  prune/GC** — ship append-only + "forget snapshot" first.
- **Phase 2 — GoogleDriveBackend:** resumable upload, jittered backoff, `drive.file`/appDataFolder,
  get-by-ID durability check, cheap server-checksum scrub. Reuse `GoogleTokenProvider`.
- **Phase 3 — prune/GC** (locked, repacking, grace + quarantine), key rotation/recovery, **iCloud via
  CloudKit** (or labeled best-effort), APFS source snapshot (shared privileged helper).

## restic/Arq features to carry over
pack files + blob index; keyed chunk IDs + per-repo chunker seed; safe AEAD nonce strategy; prune
locking (exclusive prune / shared backup) + repacking + grace; `check`/`rebuild-index`/`repair` +
scrub; wrapped key as repo object + slots + recovery + rotation; repo format version + migration
(carry the `ConfigCompatTests` / format-versioning discipline); read-your-writes handling for
eventually-consistent backends; parent-snapshot metadata fast path.

## Reusable existing assets (this repo + whiplay)
- `Services/Backup/FileWalker.swift`, `SourceReadSession.swift` — source walk + consistent-read.
- `Services/Catalog/CatalogStore.swift` — "repo is truth, SQLite is rebuildable cache" pattern + format versioning.
- `Models/DestinationCapabilities.swift` — template for `BackendCapabilities`.
- `Services/History/CaptureEngine.swift` — commit discipline (intents logged first, data durable
  before the catalog commit, recovery decided from what is on disk) to translate into the cloud
  "snapshot written last, after durable-by-ID" protocol.
- whiplay `Services/Network/GoogleTokenProvider.swift` / `GoogleDriveAccountStore.swift` — OAuth/Keychain reusable.
- whiplay `Services/Library/iCloudMaterializer.swift` — evidence iCloud Drive forces full-file downloads.
