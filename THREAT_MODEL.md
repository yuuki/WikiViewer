# WikiViewer threat model

What needs protecting, from what, and which design choices address it. For
how each protection is implemented, see the code and its tests.

## What is being protected

| Asset | Where it lives | Why it matters |
|---|---|---|
| The Obsidian vault | Mac mini | The source of truth. It must never be modified or lost. |
| Builder database | Mac mini, outside the vault | A full plaintext copy of the notes. It can be deleted and rebuilt. |
| Published artifacts | A publish folder: local, iCloud Drive, or behind HTTPS | A full plaintext copy of the notes, readable by anyone who can read the folder |
| On-device snapshots | App container on the iPhone | A plaintext copy, protected by the iOS sandbox and Data Protection |
| Obsidian account, Sync credentials, encryption password | Obsidian only | WikiViewer never needs or touches them |

The iPhone needs **no** Obsidian credentials and **no** write access to the
vault. Data flows one way, from the builder to the viewer.

## Trust boundaries

1. **Vault → indexer.** Note contents are data only. The indexer does not
   execute anything from the vault: no plugins, scripts or queries.
2. **Publish folder → phone.** Anything that arrives through a transport is
   untrusted until the phone has verified it. This applies to synced folders,
   networks and servers alike.
3. **Note content → screen.** Note text is untrusted, since it may come from
   web clippings or shared notes.

## Threats and responses

**Damage to the vault.** The system has no path that writes to the vault.
- The indexer reads vault files only and never follows links out of the vault.
- It refuses output locations inside the vault.
- Helper commands that create or edit notes work only on synthetic test
  vaults, and refuse a folder that looks like a real vault.
- A test checks that indexing and publishing leave every file in the fixture
  vault unchanged.

**Leaking files that are not notes.** The following are never indexed or
published:
- files reached through symbolic links, including a folder replaced by a link
  that points outside the vault;
- hidden folders such as `.obsidian` and `.trash`, and `node_modules` folders.

**Deleted text surviving in published snapshots.** Text removed from a note,
such as an accidentally pasted password, is erased from the builder. It is not
carried into later snapshots.

Residual risks:
- Older retained snapshots still contain the old text until they are garbage
  collected.
- The search index can keep an entry saying that a note once contained certain
  three-character sequences. The text itself is not kept.

**Corrupt, partial or tampered artifacts.** An update is installed only after
all of the following checks pass:
- size;
- SHA-256 of the whole database and of every chunk;
- SQLite's integrity check;
- the schema version, and a schema identical to the one the app expects.

If any check fails, the current snapshot stays in place and the previous one
remains available as a fallback. Tests cover each of these cases:
- a malformed manifest;
- an unsupported schema;
- a wrong hash;
- a truncated or oversized download;
- a partially synced folder;
- a corrupt database with a matching hash;
- an altered schema;
- interrupted staging.

**An attacker who controls the publish folder or server.** Hashes detect
corruption. They cannot detect a replacement where the manifest and the
database were forged together. Such an attacker can make the phone show
arbitrary note content. It is still read-only data, checked against the
expected schema, and cannot execute code.

Mitigation for now: keep the publish location private (your own iCloud Drive,
or HTTPS on a private network). Planned: manifest signatures, with the private
key kept on the Mac and never in this repository.

**Malicious content inside a note.**
- Links are followed only if they point inside the app or are `http`, `https`
  or `mailto`. Other schemes (`file:`, `tel:`, custom apps) are shown as plain
  text.
- Remote images are not loaded, so opening a note causes no network request.
- There is no web view, and HTML is shown as inert text.

**Exposure in transit and at rest.**
- **iCloud Drive transport:** the snapshot is a plaintext copy of the vault in
  your iCloud Drive. That is the same exposure as syncing the vault itself
  through iCloud. It is end-to-end encrypted only with Advanced Data
  Protection.
- **HTTP transport:** the built-in server is meant for local testing. It has no
  authentication and no TLS, and it listens only on localhost by default. For
  real use, put it behind HTTPS on a private network. The app does not permit
  plain HTTP to LAN hosts.
- **On device:** snapshots live in the app container and are excluded from
  device backups, because they can be downloaded again.

**Resource exhaustion.** Everything the phone accepts from a transport has a
size limit, including manifests, chunk lists and images. An update needs free
space before it starts. Downloads stop as soon as they exceed the announced
size. The development HTTP server limits connections and request time.

**Two indexers on the same state.** Only one indexer can use a state directory
at a time. This prevents races on generation numbers and cleanup.

**Secrets in the repository.** The repository contains no credentials, keys,
certificates or personal vault content. The fixture vault is synthetic, and
generated benchmark vaults are git-ignored. Signing, provisioning, bundle ID
and entitlements were not changed.

## Assumptions

- The macOS account running Obsidian and the indexer is trusted.
- If iCloud Drive is used as transport, the Apple account is trusted at
  Apple's standard level.
- The iOS sandbox and Data Protection work as documented.
