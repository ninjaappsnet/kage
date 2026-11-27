# Remote Kage hosts

Status: built 2026-11-22 on `feat/remote-kage-hosts` (phases 1–8, merged to `main`), released in 1.3.2 on 2026-11-23 (1.3.0 and 1.3.1 tags failed CI, never published). See "Outcome" at the end.

## Goal

See and drive the Claude Code sessions that Kage runs on other Macs (the Mac
minis) from this Mac's Kage. In Settings you enter each host as name +
username + DNS name / IP. Kage polls each host, shows its projects in the
sidebar grouped by that host's own workspaces, shows live agent status, raises
notifications, and lets you attach to any running session as a full terminal
(see output, type prompts), answer simple prompts without attaching, and start
new tabs on the host.

The existing "Remote SSH repositories" feature stays as it is. This feature is
separate: here the remote Mac runs its own Kage, and this Mac is a viewer.

## Decisions (2026-11-22, with Ahmet)

- Data source: a new versioned snapshot on the remote Kage
  (`kage host snapshot`), not parsing remote files. Every host must run
  the new build; it ships to the minis through a normal Sparkle release (only
  when Ahmet asks for one).
- Sidebar: one collapsible section per host. Inside: that host's workspaces →
  repos → worktrees → tabs. Never mixed with local workspaces.
- Tabs: flat (one local tab per remote tab, no split mirroring).
- Attach on open: a tab attaches (ssh + zmx stream) only when opened; others
  show polled status only. Closing the tab detaches; the session keeps running.
- Host fields: name, username (defaults to this Mac's user), address.
- v1 scope: attach/detach, live status badges, notifications, quick answer,
  new remote tabs.

## Evidence from the first mini (2026-11-22)

- `ssh ahmetcetin@ahmets-mac-mini.tail96d5dd.ts.net` works with key auth.
- Remote Kage bundles zmx at `/Applications/Kage.app/Contents/Resources/zmx/zmx`
  and the CLI at `/Applications/Kage.app/Contents/Resources/bin/supacode`;
  neither is on the ssh PATH.
- An ssh session sees the same zmx socket dir as the remote Kage
  (`$TMPDIR/zmx-<uid>`), and the CLI finds the app socket by itself.
- zmx session name = `supa-<content UUID lowercased>`
  (`ZmxSessionID.make`, `ZmxClient.swift:329`).
- `zmx history <s> --screen` reads the screen without attaching;
  `zmx send` injects input; `zmx attach` from a second client works
  (`clients=2`).
- Open: whether a second client resizes the session for the remote window.
  Phase 4 checks this before shipping attach.
- Open: ctrl+\\ did not detach inside a Kage tab. The in-app attach must not
  depend on it (closing the tab detaches).

## Design

### Remote side (runs inside the host's Kage)

- New socket query resource `host-snapshot` in `handleQuery`
  (`supacodeApp.swift`). The wire format is flat `[[String: String]]`, so
  the response is one row `{"json": "<HostSnapshot JSON>"}`; no transport
  change, CLI parser untouched.
- `HostSnapshot` (new file, Codable, `schemaVersion: 1`): kage version,
  remote zmx path and CLI path (from `Bundle.main`), workspaces
  `{id, name}` in order, repos `{id, displayName, rootPath, workspaceID,
  isGit, color}`, worktrees `{id, repoID, name, branch, isMain}`, tabs
  `{id, worktreeID, title, focused, surfaces: [{id, zmxSession, agent:
  {kind, activity}?}]}`.
- Built by a pure `HostSnapshotBuilder` from repositories state, sidebar
  state, layouts, tab titles (`TabTitle.resolved`) and agent presence
  (`AgentPresenceFeature` by surface). Agent status comes from the remote
  Kage's own presence tracking: no screen scraping.
- New CLI subcommand `kage host snapshot` prints the JSON.
- `kage` is a second name for the existing CLI, not a new binary:
  `Resources/bin/kage` is a symlink to `bin/supacode`, and Settings →
  Developer → Install CLI links both into `/usr/local/bin`. Every command
  works under both names; `supacode` stays for upstream script/hook
  compatibility. Help text shows the name it was invoked as (argv[0]).

### Local side (this Mac)

- `RemoteKageHost {id, name, username, address}` in
  `~/.config/kage/remote-hosts.json` (`RemoteKageHostsFileKey`, same
  pattern as `ClaudeAccountsFileKey`). Address and username are validated
  (no leading `-`, no whitespace or shell metacharacters) so they can never
  become ssh options.
- `RemoteKageClient`: runs commands through `ShellClient.ssh` with
  `SSHCommand.backgroundProbeOptions` and the shared ControlMaster, so
  polling and attached tabs share one connection per host. Calls the remote
  CLI by absolute path (from the snapshot after the first call; the default
  path before that).
- `RemoteKageFeature` reducer: polls each host (every 5 s while the app is
  active, backoff while offline; `TestClock` in tests). Per-host state:
  connecting / online(snapshot) / offline(error) / needsUpdate (old build
  answers "Unknown resource"). Snapshot diffs drive notifications:
  a surface turning `awaitingInput` posts one notification.
- Sidebar: a `RemoteKageSidebarSections` view appended after the local
  sections in `SidebarListView`, one `Section` per host. Rows tag a new
  `SidebarSelection.remoteKage(...)` case. Remote rows never enter
  `SidebarStructure` / `sidebarItems`, so local invalidation rules are
  unaffected; the remote section reads its own feature state.
- Detail: one early branch in `WorktreeDetailView.detailContent` for the
  remote selection → `RemoteKageWorktreeView`: a flat tab strip of the
  remote worktree's tabs with status badges, a screen preview
  (`zmx history --screen`) for unopened tabs, quick-answer buttons when
  awaiting input, and an attached terminal for opened tabs.
- Attached terminal: a local Ghostty surface whose command is
  `ssh -tt <shared control opts> user@host '<remote zmx path> attach
  supa-<id>'` with `bypassZmx` (no local zmx wrapper; this Mac must not
  keep its own persistent copy). Wrapped in `SSHReconnectLoop` so a dropped
  link reattaches. How to host a surface outside a local worktree's
  `LayoutFeature` is the Phase 4 spike.
- Quick answer: `zmx send supa-<id> <keys>` for the choices shown on the
  awaiting-input screen (1/2/3, Esc, Enter).
- New remote tab: `supacode tab new -w <id> --id <uuid> [--command claude]`
  on the host, then attach to the new tab.

## Phases (each test-first; app built and exercised against the mini)

1. Snapshot: `HostSnapshot` + builder tests, `host-snapshot` query, CLI
   `host snapshot`, `kage` alias (bundle symlink + CLI install). Verify by
   running `kage host snapshot` locally.
2. Hosts in Settings: model + validation tests, file key, Settings pane.
3. Polling: `RemoteKageClient` + `RemoteKageFeature` (TestClock tests for
   polling, backoff, needsUpdate, offline).
4. Sidebar + detail, read-only: host sections, selection case, screen preview.
5. Attach: spike surface hosting, check the two-viewer resize on the mini,
   then attach/detach tabs.
6. Status badges + notifications from snapshot diffs.
7. Quick answer + new remote tab.
8. Docs: README section, CLAUDE.md fork-feature section.

## Upstream files touched (all small, appended)

- `supacodeApp.swift`: one `case "host-snapshot"` in `handleQuery`.
- `supacode-cli/SupacodeCLI.swift`: register `HostCommand`; command name from argv[0].
- `Project.swift`: one appended line for the `bin/kage` symlink.
- CLI install reducer: link `kage` next to `supacode`.
- `SettingsSection.swift` + `SettingsView.swift`: one case, one row, one
  detail arm.
- `AppFeature.swift`: state / action / scope / launch task.
- `SidebarSelection.swift`: one case (enum case: unavoidable landmine).
- `SidebarListView.swift`: one appended view after the local sections.
- `WorktreeDetailView.swift`: one early branch in `detailContent`.
- `WorktreeMenuSnapshot.swift`: one arm if the exhaustive switch needs it.

Everything else lives in `supacode/Features/RemoteKage/`.

## Outcome (2026-11-22)

- All phases built test-first by five parallel slices (snapshot, settings,
  polling, sidebar, attach), merged into `feat/remote-kage-hosts`, then `main`.
  Full `make test` green (4661 tests), `make check` and `make build-app` green.
- Checked against the mini at component level: `zmx history --screen` and
  `zmx send` quoting (throwaway sessions), the old CLI's `host snapshot` error
  classifies as needsUpdate, attach in a temporary in-app harness (typing,
  resize, real ctrl+\\ detaches, unmount detaches, missing session is not
  recreated, killed ssh master reconnects). Not yet exercised end to end in
  the shipped UI; the mini needs 1.3.2 first.
- Two-viewer resize (resolved): zmx 0.8.1 has one leader client, the one that
  last sent keyboard input; only its size applies. Our view shows the session
  at the mini's size until the first keystroke here, then the mini's window
  follows ours. Accepted for v1; a later fix needs a zmx patch letting focus-in
  claim leadership, shipped on the host too.
- ctrl+\\ (resolved): a real key press detaches; text sent via `sendText`
  does not, because bash wraps it in bracketed paste.

## Follow-up: paste uploads (2026-11-27)

- Asked by Ahmet: a screenshot pasted into an attached remote terminal pasted
  this Mac's path, which the host's Claude Code can't open. Now files and
  clipboard images are uploaded to the host first and the host path pasted;
  Claude Code there shows `[Image #N]` (checked by hand on mini-1 with a probe
  path before building: it showed `[Image #2]`).
- Decisions: plain `ssh -T` with stdin over the ControlMaster, not the
  `host serve` `write` op (no delete op for the 7-day prune, no folder mode,
  needs a held session and 1.4.1 on the host). Folder `/tmp/kage-<user>`, not
  `/tmp/kage`: `/tmp` is shared, so a fixed name could belong to someone else.
  `/tmp` is only swept at boot on macOS 27 (`/etc/periodic` is gone), so each
  upload prunes files older than 7 days itself.
- Checked: unit tests for the plan, names, script (run in a local `/bin/sh`),
  controller and hook; a real Ghostty surface receiving the pasted path in its
  child process; a live upload to mini-1 through the real ssh code (0.17 s).
  On 2026-11-27 Ahmet checked Cmd+V and drag-and-drop in an attached mini-1
  tab in the dev sandbox: both showed `[Image #N]`, and two CleanShot PNGs
  landed in mini-1's `/tmp/kage-ahmetcetin/` as `-rw-------` files with
  sanitized names.
- Not covered: a custom Ghostty key binding for paste other than Cmd+V.
