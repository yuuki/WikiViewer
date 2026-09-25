# WikiViewer threat model

Scope: the host indexer/publisher (`wikiindex`), the published artifact
directory, the transports, and the iOS app. Out of scope: Obsidian Desktop,
Obsidian Sync and their credentials.

## Assets

| Asset | Where | Sensitivity |
|---|---|---|
| Obsidian vault (plaintext notes, attachments) | Mac mini, vault folder | High — source of truth; must never be modified or lost |
| `builder.sqlite` | `--state` dir on the Mac mini | High — full plaintext copy of note text; disposable |
| Published artifacts (DB generations, chunks, image blobs) | `--publish` dir; iCloud Drive or HTTP server if used | High — full plaintext copy of note text |
| On-device generations | App container, Application Support | High — protected by iOS data protection and the app sandbox |
| Obsidian account / Sync credentials / E2E password | Obsidian only | Never touched by WikiViewer |

The iPhone needs **no** Obsidian credentials, Sync credentials, encryption
password, or write access to the vault. Delivery is one-way:
builder → artifacts → viewer.

## Trust boundaries

1. Vault → indexer: the indexer trusts file *contents* only as data. It never
   executes anything from the vault (no plugins, no JavaScript, no Dataview).
2. Indexer → publish directory: written only by the indexer.
3. Publish directory → transport → device: **untrusted** until validated on
   the device (a synced folder, a network or a server can be tampered with or
   deliver partial data).
4. Note content → rendered UI: untrusted text (it may come from web clippings
   or shared notes).

## Threats and mitigations

### T1 Accidental modification of the vault (integrity, availability)
- All vault reads use `open(O_RDONLY | O_NOFOLLOW | O_CLOEXEC)`; no write API
  is ever called on vault paths. Walk uses `fts(3)` with `FTS_PHYSICAL`.
- `IndexerConfiguration.validate()` refuses state/publish directories inside
  the vault (and the vault inside them), resolving symlinks with `realpath(3)`
  even for not-yet-existing paths.
- `wikiindex synth` and `wikiindex bench` only write into directories marked
  with `.wikiviewer-synthetic` / `.wikiviewer-bench-work` (or empty ones), and
  `bench` refuses vaults without the synthetic marker.
- Test `indexesFixtureWithoutTouchingVault` snapshots size, mtime and SHA-256
  of every fixture file before and after indexing + publishing.

### T2 Symlink / path escape from the vault (confidentiality)
- Symlinks inside the vault are ignored (never followed), so a symlink to
  `~/.ssh` cannot be indexed and published.
- After opening a file, its real path (`F_GETPATH`) must be inside the vault
  and equal the requested path; a directory component swapped for a symlink
  to an outside folder is therefore not read (regression test).
- Hidden directories (`.obsidian`, `.trash`, `.git`, …) are skipped.

### T2b Removed text persisting in published files (confidentiality)
- `PRAGMA secure_delete=ON` on the builder and snapshots: content removed
  from a note (e.g. a pasted password) or a deleted note is overwritten with
  zeros rather than surviving in free pages/cells that the backup copies into
  published generations and chunks (regression test greps the published file).
- Residual: FTS5 (`detail='none'`) keeps "row contains trigram" entries for
  deleted content until segments merge; this reveals only which trigram set
  a row once contained, not the text. Retained old generations (3 by default)
  still contain the old text until they are garbage-collected.

### T3 Tampered or partial artifacts (integrity, availability)
- `manifest.json` ≤ 64 KiB, strict JSON decoding, structural validation:
  supported format/schema versions, generation range, exact expected file
  names (`generations/viewer-<N>.sqlite`, `.chunks`), 64-hex digests, sane
  sizes and chunk counts.
- Downloads go to `staging/` with hard size caps (HTTP streams are cancelled
  once they exceed the announced size; folder copies are bounded).
- Every chunk and every asset blob is verified against its SHA-256 before
  use; the whole database file is verified against the manifest's size and
  SHA-256 (mandatory, also after delta assembly).
- The untrusted SQLite file is then opened read-only (not `immutable`) and
  checked: `PRAGMA quick_check`, `user_version`, `meta.schema_version`,
  `meta.generation`, required tables, note count.
- Only after all checks is the staging directory renamed into
  `generations/`, and only then is `current` switched (atomic rename).
  Failures leave the current and previous generations untouched; tests cover
  malformed manifest, unsupported schema, wrong hash, truncated/oversized
  download, missing database (partial iCloud sync), corrupt SQLite with a
  matching hash, generation mismatch, missing tables, tampered chunks and
  tampered chunk lists, and interrupted staging.
- Asset blobs and chunks are addressed by digest; names are validated
  (`^[0-9a-f]{64}(\.[a-z0-9]{1,8})?$`) before any path is built.

Only one indexer may use a state directory at a time (`flock`), preventing
two publishers from racing on generation numbers or garbage collection.

**Residual risk:** hashes protect against corruption and partial sync, not
against an attacker who can rewrite *both* the manifest and the data (e.g.
someone with write access to the publish folder or the HTTP server). Such an
attacker can serve arbitrary *content* (it will still be a structurally valid
SQLite database opened read-only). Mitigation available later: Ed25519
signatures over the manifest with the private key kept outside the repository
(e.g. in the Mac mini's Keychain) and the public key compiled into the app.
Not implemented in this version.

### T4 Malicious SQLite content (integrity of the app)
- Databases are opened with `SQLITE_OPEN_READONLY`, `PRAGMA query_only` and
  `PRAGMA trusted_schema=OFF`; the app never writes to them, so triggers
  cannot fire.
- Before installation the untrusted file's schema must match, object by
  object, the schema this build creates (views, extra triggers, altered
  constraints are rejected); `quick_check` then also verifies NOT NULL
  constraints, so rows decode safely. `meta` is read without trapping on
  duplicates/NULLs (regression tests). Queries are parameterized; user search input is bound as
  parameters (LIKE wildcards escaped, GLOB metacharacters escaped).
- Extremely large rows or notes cost memory proportional to the displayed
  note only; embedded-note excerpts are capped at 256 KiB.

### T5 Link / URL injection from note content
- Rendered links use an internal `wikiviewer://` scheme resolved by the app;
  only `http`, `https` and `mailto` become links at all. `tel:`, `file:`,
  `javascript:`, `shortcuts:` and other schemes are rendered as plain text
  (not merely blocked at tap time), so text selection/long-press cannot open
  them either. Tests: `urlRoundTrip`, `unsafeSchemesAreNotLinks`.
- Remote images are **not** fetched automatically (no tracking pixels, no
  network access triggered by viewing a note).
- No WKWebView; HTML blocks are shown as inert text.

### T6 Exposure in transit / at rest
- **iCloud Drive folder**: artifacts are plaintext SQLite and images inside
  the user's iCloud Drive (encrypted in transit and at rest by Apple; standard
  iCloud Drive is not end-to-end encrypted unless Advanced Data Protection is
  enabled on the Apple account). This is a copy of the vault's plaintext,
  comparable to syncing the vault itself through iCloud.
- **HTTP**: `wikiindex serve` has no authentication and no TLS. It binds to
  `127.0.0.1` by default and serves only `manifest.json`, `generations/`,
  `assets/`, `chunks/` (no dotfiles, traversal rejected). For real use put
  it behind HTTPS on a private network (e.g. Tailscale / WireGuard) or a
  reverse proxy with authentication. Plain HTTP to a LAN host additionally
  requires an App Transport Security exception in the app, which this
  version does not add; HTTPS works without changes.
- On device: generations live in the app container (iOS Data Protection,
  sandbox) and are excluded from iCloud device backups (re-downloadable).

### T7 Denial of service / resource exhaustion
- Host: bounded parse and image concurrency; files over 8 MiB (notes) are
  skipped; very large media are identified by metadata instead of hashing.
- Device: capped manifest/chunk-list/blob sizes, bounded queries (LIMIT ≤ 500),
  bounded image cache, display-size image decoding.
- HTTP server: one request per connection, 16 KiB header limit, 10 s deadline
  for the request headers, at most 64 concurrent connections.
- Updates require free space ≥ 2 × the database size before downloading.
- Destructive helper commands (`synth` overwriting a directory, `bench`
  editing notes) require the synthetic marker file *and* an `.obsidian`
  folder containing nothing but the generated `app.json`, so a real vault
  that happens to contain a copied marker is still refused.

### T8 Secrets in the repository
- No secrets, certificates, private keys, tokens or personal vault contents
  are committed. `Fixtures/vault` is synthetic test content written for this
  repository. Generated benchmark vaults live in git-ignored `bench-work/`.
- No signing, provisioning, entitlement, Bundle ID or Team settings were
  changed.

## Assumptions

- The Mac mini account running Obsidian and `wikiindex` is trusted.
- The user's Apple ID / iCloud Drive (if used as transport) is trusted for
  confidentiality at Apple's standard level.
- iOS app sandbox and Data Protection work as documented.
