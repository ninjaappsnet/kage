# Remote files and sidebar machine groups

Status: planned 2026-11-25, in progress on `feat/remote-files`. Merged there on
2026-11-25: A (`kage host serve`, fb7224ea), C (sidebar groups, 89316f82),
D (tab working directory, fbb484b1), B (viewer seam, 8f89ded7). E in progress on
`feat/rf-remote`. Sidebar checked in the dev sandbox (d4ad86f6; Remote Hosts
band changed to purple so it reads apart from This Mac). Follows
`docs/plans/remote-kage-hosts.md` (released in 1.3.2).

## Goal

1. For a remote Kage host's worktree, show the same docked file explorer
   (⌥⌘E) and the same right-hand file viewer / editor as a local worktree:
   browse, preview (text, markdown, HTML, images, PDF), edit, ⌘S save, the
   "changed on disk" banner, following the focused tab's folder. (The docked
   panel has no git status colors locally either; `gitStatus` is in the
   protocol for when it gets them, and costs nothing unless requested.)
2. Sidebar: when at least one remote host is configured, show two
   independent accordion groups, **This Mac** and **Remote Hosts** (each opens
   and closes on its own, state persisted). Inside Remote Hosts each host is a
   section and each of the host's workspaces is collapsible. With no remote
   hosts the sidebar stays exactly as today.

Hard requirement from Ahmet: as performant as possible, least resources on
both Macs and on the link.

## Evidence (2026-11-25)

- The mini runs Kage 1.3.2. Its repos live on `/Volumes/SSD/Developer`:
  APFS, PCI-Express (Thunderbolt), "Removable Media: Fixed". `ls` over ssh
  works there, so no TCC prompt is involved (repos are not in ~/Documents,
  ~/Desktop or ~/Downloads). FSEvents works on local APFS volumes.
- Local explorer/viewer are fork code (`supacode/Features/FileExplorer/`:
  `FileExplorerModel` 209 lines, `FileViewerModel` 234, FSEvents in
  `FileSystemEventWatcher`), hard-wired to `FileManager` / `Data(contentsOf:)`.
  Refactoring them costs no upstream conflicts.

## Design: one persistent channel per host

`kage host serve` is a new CLI subcommand on the host. The viewer starts it
over the shared ssh ControlMaster (`ssh -T … '<cli> host serve'`) and talks
NDJSON over its stdin/stdout. One process and one ssh channel per host
(sshd allows 10 sessions per connection; attached tabs and polling share it).

Why this is the cheap path:
- No per-request ssh exec (each costs a channel open, a process spawn and CLI
  start). Requests are lines on an open pipe.
- Push, not poll: the host runs FSEvents and sends only what changed in the
  directories the viewer has expanded. Idle cost is zero CPU, zero traffic.
- The CLI process does the work itself; the host's Kage app is not involved,
  so files work even while Kage is not running there.
- Lifecycle: the process exits on stdin EOF (no tty, so no SIGHUP otherwise).
  The viewer opens the channel when a remote explorer/viewer becomes visible
  and closes it 30 s after the last one goes away, or when the app goes
  inactive for 5 minutes.

### Protocol v1 (NDJSON, UTF-8, one JSON object per line)

Paths are absolute POSIX strings. Times are milliseconds since 1970 (Int64).

Requests (viewer → host): `{"id": <Int>, "op": "<name>", ...args}`.
Responses: `{"id": N, "ok": true, "result": {...}}` or
`{"id": N, "ok": false, "error": {"code": "...", "message": "...", ...}}`.
Events (host → viewer, no id): `{"event": "<name>", ...}`.

| op | args | result |
|----|------|--------|
| `hello` | – | `{protocolVersion: 1, kageVersion}` |
| `list` | `path, showHidden` | `{entries: [{name, kind: file\|dir\|symlink, size, mtime, targetKind?}]}` (unsorted; the viewer sorts) |
| `stat` | `path` | `{kind, size, mtime}` |
| `read` | `path, maxBytes` | `{data: <base64>, size, mtime}`; error `tooLarge` with `size` |
| `write` | `path, data: <base64>, expectedMtime?` | `{mtime}`; error `conflict` with current `mtime` |
| `watch` | `paths: [dir]` (replaces the set) | `{}` |
| `gitStatus` | `root` | `{porcelain: <output of git -C root --no-optional-locks status --porcelain=v2 -z --untracked-files=all --ignored=matching --no-renames>}` or error `notGit` (same argv as `GitClient.fileStatus`, so the app's `GitStatusSnapshot.parse(porcelainV2:)` reads it unchanged) |

Error codes: `notFound`, `permission`, `tooLarge`, `conflict`, `notGit`,
`badRequest`, `io`.

Events:
- `{"event": "changed", "paths": [dir]}`: listings of these watched dirs (or
  a watched file's parent) changed. Coalesced over 200 ms. Only dirs in the
  watch set are reported.
- `{"event": "treeChanged", "root": r}`: something under a watched root
  changed (drives the viewer's git status refresh), at most once per 1 s per root.
- `{"event": "rescan", "path": p}`: FSEvents dropped events
  (MustScanSubDirs, root changed, volume unmounted); re-list everything under p.

Host rules:
- One FSEventStream over the watched set, directory-level events (no
  `kFSEventStreamCreateFlagFileEvents`), latency 0.2 s, `WatchRoot`;
  rebuilt (debounced) when the set changes. `.git/` internals ignored
  except `HEAD` and `index` (they feed `treeChanged`).
- `write` compares `expectedMtime` against the file, writes a temp file
  in the same directory, keeps the mode, renames over the target, writes
  through a symlink to its target (same as the local writer).
- `read` refuses above `maxBytes` without reading the file.
- Requests are handled off the main thread; a slow read never blocks events.

Viewer rules:
- Lazy: list only expanded dirs; cache listings per path; events invalidate.
- Git status requested on open and on `treeChanged`, at most once per 2 s.
- A reconnect re-sends `watch` and re-lists everything visible (events
  during the gap are lost). A slow safety re-list every 60 s while visible.
- An older host answers "unknown subcommand": the pane says the host needs
  an update (same classifier as snapshots).

### Viewer seam

`FileSystemSource` (app side): list / stat / read / write / watch / git
status. `LocalFileSystemSource` wraps today's `FileManager` + FSEvents code
(no behavior change), `RemoteFileSystemSource` speaks protocol v1 through a
per-host `RemoteKageServeSession`. `FileExplorerModel`, `FileViewerModel`
and the HTML preview's scheme handler take a source instead of touching the
disk, so remote HTML pages load their relative assets too.

### Remote worktree view

`RemoteKageWorktreeView` gets the same ⌥⌘E toggle and docked
`FileExplorerPanel` (with the remote source, rooted at the selected tab's
working directory, falling back to the worktree root), and the file viewer
opens as a right-hand pane beside the attached terminal, like locally.

The focused tab's folder comes from a new optional `workingDirectory` on each
`HostSnapshot` surface (no `schemaVersion` bump: older viewers ignore it).

## Phases (each test-first)

1. In parallel:
   - A. Host: `kage host serve` with protocol v1 (CLI, FSEvents, NDJSON).
   - B. Viewer seam: `FileSystemSource` + `LocalFileSystemSource`; explorer,
     viewer and HTML preview moved onto it, local behavior unchanged.
   - C. Sidebar: This Mac / Remote Hosts accordions, collapsible host
     workspaces, persisted expansion, auto-expand on reveal.
   - D. Snapshot: `workingDirectory` per surface.
2. E. Remote: `RemoteKageServeSession` (one per host, lifecycle above),
   `RemoteFileSystemSource`, explorer + right-hand viewer in
   `RemoteKageWorktreeView`.
3. Verify against the mini (after a release that ships `host serve`):
   browse, preview each type, edit + save, conflict banner, live refresh,
   CPU / traffic idle check.
4. Later: `host serve` also pushes snapshot changes (`subscribeSnapshot`),
   making the 5 s ssh poll a fallback for older hosts.
