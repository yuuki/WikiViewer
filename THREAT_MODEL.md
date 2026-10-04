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
| Reading history (#42) | The device; on the Mac in `--signals DIR` if sharing is on | What was read, when, how long — a private record of interest |

The iPhone needs **no** Obsidian credentials and **no** write access to the
vault. Notes flow one way, from the builder to the viewer. The one way back
is a **request** (a question about a note): data the app puts in a queue
outside the vault, which the Mac hands to Claude Code running in the vault
(see "Requests from the app" below).

## Trust boundaries

1. **Vault → indexer.** Note contents are data only. The indexer does not
   execute anything from the vault: no plugins, scripts or queries.
2. **Publish folder → phone.** Anything that arrives through a transport is
   untrusted until the phone has verified it. This applies to synced folders,
   networks and servers alike.
3. **Note content → screen.** Note text is untrusted, since it may come from
   web clippings or shared notes.
4. **Device → Mac (requests).** A request is untrusted until the Mac has
   checked it: who sent it (HTTP: a bearer token; folder: whoever can write
   the synced folder), its size and its fields. Its text is the reader's
   own words, but it reaches Claude, which can write to the vault.

## Threats and responses

**Damage to the vault.** Neither the app nor `wikiindex` has a path that
writes to the vault. (Requests, below, are answered by Claude Code, which
writes only under `wiki/`.)
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
- folders the user excludes with `--exclude` / `--exclude-file`.
- when the user selects folders with `--include` / `--include-file`, every
  file outside them. An include file that lists no folder is refused, so
  emptying it never publishes the whole vault.

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
- SHA-256 of the whole database and of every chunk — or, when the database
  was patched from an installed generation with a delta pack, SHA-256 of
  every chunk the pack touched against the chunk list named by the manifest
  (the other chunks are byte-for-byte the already verified base);
- SHA-256 and size of every pack part before it is decoded; decoding is
  bounded (at most 8 MiB per part) and rejects truncated or malformed parts;
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
- a corrupt pack, and a well-formed pack that writes wrong pages under a
  forged manifest (both fall back to chunks and still verify);
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
  device backups, because they can be downloaded again. Background app
  refresh uses the same source and the same checks as a foreground update.
- **On the Mac:** to compute delta packs, the state directory keeps copies of
  the last three published databases. They are as sensitive as the builder
  database and are replaced as new generations are published.

**Requests from the app.** The app can ask Claude on the Mac about a note
(#34); the answer is a note Claude writes under `wiki/`. What could go
wrong, and the responses:
- *Someone else sends requests.* Over HTTP, `wikiindex serve` takes
  `POST /requests` only when started with `--token-file` (a secret of 16 or
  more characters in a file only the owner can read), compares the bearer
  token in constant time, and refuses everything else (401/405). The token
  is kept in the device's Keychain. Over iCloud Drive, only devices of the
  same Apple account can write the folder. Keep `tailscale serve` (never
  `funnel`) in front of the server, as for the snapshots.
- *Malformed or oversized requests.* Bodies over 512 KiB are refused before
  being read; every request is decoded and validated (known kind, required
  fields, text of at most 16,000 characters, note paths relative, without
  `..` or hidden components) by the server and again by the worker, which
  never acts on a file name other than `<uuid>.json`.
- *Claude doing more than answering.* The worker runs a runner, not Claude;
  `scripts/claude-request.py` starts `claude -p` in the vault with an
  allow-list: reading, the Skill tool, the vault's own `scripts/`, `rg`,
  the git status, diff, add and commit commands, and Write/Edit only on
  `wiki/**`. Web fetch and search are disallowed (so vault text cannot be
  sent out), other shell commands are denied, and the spend per request is
  capped (`--max-budget-usd`). The prompt quotes the reader's text in a
  fence, as data. The worker accepts an answer path only if it is an
  existing `.md` file under `wiki/`, reached without symbolic links.
- *Prompt injection from note text.* Claude reads vault notes, which may
  contain clipped web text. With the allow-list above, the worst outcome is
  a wrong or unwanted page under `wiki/` (the vault is a git repository, so
  it can be reverted); nothing leaves the Mac and the primary layer
  (`papers/`, `notes/`, …) cannot be edited.
- *Exposure.* Requests carry the chosen paragraphs and the question. They
  wait in `<PUBLISH>/inbox/` (as private as the snapshots) and are deleted
  once handled; status files in `<PUBLISH>/requests/` carry no request
  text and are deleted after 30 days. `--log` keeps a copy on the Mac.
- *Resource use.* One request runs at a time, each for at most 30 minutes
  (`--timeout`); runner output read back is capped at 1 MiB.

**Reading history.** Sharing it is off until the reader turns it on in
Settings; until then nothing is collected. When on, the device keeps at
most 2,000 readings (note path, title, time opened, seconds on screen,
how far, pinned) and sends them through the request queue about once an
hour; turning sharing off deletes what is waiting. On the Mac,
`wikiindex requests --signals DIR` keeps them outside the vault and
outside the publish folder (so they never reach other devices), in a
directory only the user can read (0700, files 0600), and deletes months
older than `--signal-days` (180 by default). The worker never passes them
to Claude; the vault's skills read `summary.json` only if the user runs
`scripts/reading-signals.py` from them. A signals request goes through
the same token and validation as any request (paths relative, at most
5,000 readings and 1,000 pins).

**Resource exhaustion.** Everything the phone accepts from a transport has a
size limit, including manifests, chunk lists, pack parts and images. An update
needs free space before it starts. Downloads stop as soon as they exceed the
announced size. The development HTTP server limits connections, request time
and idle time of persistent connections; a long-poll request is held for at
most 55 seconds and only re-reads the manifest while it waits.

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
