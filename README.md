# Kage

**A native macOS command center for running coding agents in parallel.**

Run several coding agents side by side from one window: each task gets its own git worktree and
its own real terminal. Sessions persist in the background, so quitting the app or dropping an SSH
connection loses nothing.

Kage is a fork of [Supacode](https://github.com/supabitapp/supacode) by
[supabit](https://supacode.sh). Everything Supacode does, Kage does — this fork tracks upstream
closely and adds a docked file explorer and viewer, sidebar workspaces, and no telemetry. Credit
for the app and the great majority of its code belongs upstream.

## Install

Download the latest `.dmg` from [Releases](https://github.com/ninjaappsnet/kage/releases) and drag
Kage to `/Applications`. Builds are signed and notarized. Sparkle keeps the app up to date on one
of two channels, selectable in Settings → Updates:

- **Stable** — tagged releases.
- **Tip** — a nightly pre-release cut from `main`.

Or build from source; see [Quick start](#quick-start).

## What this fork adds

### File explorer and file viewer

A docked file tree for the selected worktree, toggled with **⌥⌘E** (View → Toggle File Explorer).
It re-roots itself to the focused terminal's working directory, so `cd` in the terminal moves the
tree with you, and it refreshes live as files change on disk.

Clicking a file opens it in an adjacent viewer pane that is a real editor, not a preview: text
files get syntax highlighting, native find, and ⌘S to save, with an unsaved-changes indicator,
reload-from-disk, and a banner when the file changes underneath you. Markdown and HTML render, with
a Rendered / Raw toggle to drop into the source. Images and PDFs get read-only previews; anything
binary or oversized offers **Open in Default App**. Close the pane with **Esc**.

### Sidebar workspaces

A workspace is a named filter over your projects. Assign repos and folders to one from the section
menu (**Move to Workspace**), then switch with the picker above the sidebar to hide everything else.
**All Projects** is the default and filters nothing. Each workspace remembers its own last
selection, and a repo added while a filter is active joins that workspace automatically.

### No telemetry

The analytics and crash-reporting SDKs are unlinked in this fork. Kage phones home only for Sparkle
update checks, and only to this repository's appcast.

## Features

### Worktree-first workflow

Each task gets its own git worktree and terminal, so agents run in parallel without colliding.
Create one from the sidebar, a hotkey, the command palette, the CLI, or a deeplink. The sidebar
refreshes branch, file, and pull request state live, nests rows by branch, and hoists the
worktrees that need you (an agent awaiting input, a running script) to the top. Pin, archive,
auto-delete after N days, and jump to any with ⌃1 to ⌃9.

### Background session persistence

Sessions run inside [zmx](https://zmx.sh), a lightweight session daemon, not as children of the
app. Quit and relaunch, and every session reattaches exactly where you left it, scrollback
included. On by default; a quit option tears everything down when you want a clean start.

### Remote SSH repositories (Beta)

Point Kage at a repository on a remote host over SSH and it manages that repo's worktrees like a
local one. Every git probe and the terminal share one multiplexed SSH connection, so you
authenticate (or touch your security key) once. When the host has zmx, remote sessions survive
dropped connections and laptop sleep: the connection retries and reattaches instead of
restarting. Beta, with some local-only features reduced.

### Folders and repositories

Git repositories and plain folders are both first-class in the sidebar. A folder gets a real
persistent terminal rooted there, with the same tabs, scripts, pinning, and appearance as a repo,
minus the git-only tools. You can also clone a remote URL straight into a folder.

### Coding agent presence

Kage detects the agent in each pane and shows a live badge: busy, awaiting input, or idle. It
supports the common agents (Claude, Codex, Copilot) through hooks it installs, works locally and
over SSH, and drives notifications so you know the moment an agent needs you.

### The CLI and deeplinks

Drive the app from any terminal, script, or other tool. The `supacode` CLI manages worktrees,
tabs, splits, and repos, and every session exports its repo, worktree, tab, and surface IDs, so
commands default to the session you run them in. Deeplinks (`supacode://...`) mirror the CLI, so
you can bind an action to a hotkey or fire it from another app. The CLI name and URL scheme are
deliberately unchanged from upstream, so existing scripts and hooks keep working.

### More

- **A real terminal.** libghostty renders every session, with tabs, horizontal and vertical
  splits, per-surface backgrounds, and theme sync with the app's appearance.
- **Command palette.** Fuzzy-search and run any action without the mouse: jump to a worktree, open
  or clone a repo, manage worktrees, run scripts, and drive the full set of pull request actions.
- **Pull request tracking.** With GitHub integration on, each worktree's PR state, checks, and
  merge readiness show in the sidebar and refresh live, with configurable merge strategy.
- **Notifications and bells.** In-app and optional system notifications, a selectable sound,
  per-surface muting, and an option to float a notified worktree to the top.
- **Custom scripts.** Named commands with an icon and tint, per repository or global, that run in
  their own tab and appear in the Script Menu, the palette, and as deeplinks. Repositories also
  get setup and archive scripts.
- **Auto-updates** through Sparkle, with a selectable update channel.

## Requirements

- macOS 26.0+
- [mise](https://mise.jdx.dev/) for the pinned toolchain. Add `~/.local/bin` to your `PATH`.
- git submodules: `git submodule update --init --recursive`
- **Xcode 26.3** if you are on macOS 26.4+ (see [below](#building-on-macos-264-tahoe)).

## Quick start

```bash
git clone --recursive git@github.com:ninjaappsnet/kage.git
cd kage
mise install
make doctor    # check every build prerequisite and print fixes for anything missing
make run-app   # build and launch the Debug app
```

`make doctor` verifies mise, submodules, a Zig-linkable Xcode, the Metal Toolchain, and the
pinned tools, and prints the exact command to fix anything that is missing. The build targets
run it automatically as a quiet preflight.

The Xcode project, target, and source directories are still named `supacode`; only the product is
branded Kage. Renaming them would conflict with every upstream merge.

## Building

```bash
make build-ghostty-xcframework   # build GhosttyKit from Zig source (slow, cached)
make build-app                   # build the macOS app (Debug)
make run-app                     # build and launch
```

### Building on macOS 26.4+ (Tahoe)

GhosttyKit is built with a pinned Zig (`0.15.2`, required exactly by ghostty) whose linker
cannot link the macOS 26.4+ SDK: that SDK dropped the `arm64-macos` slice from `libSystem.tbd`
([ziglang/zig#31658](https://github.com/ziglang/zig/issues/31658)), so the build fails with a
wall of `undefined symbol` errors. Install [Xcode 26.3](https://developer.apple.com/download/all/?q=Xcode%2026.3),
which ships the macOS 26.2 SDK that still has `arm64-macos`. You do not need to switch it
globally: the build auto-detects a Zig-linkable Xcode and pins it for that build only. After
installing Xcode 26.3 once:

```bash
sudo DEVELOPER_DIR=/Applications/Xcode_26.3.app/Contents/Developer xcodebuild -license accept
sudo DEVELOPER_DIR=/Applications/Xcode_26.3.app/Contents/Developer xcodebuild -runFirstLaunch
sudo DEVELOPER_DIR=/Applications/Xcode_26.3.app/Contents/Developer xcodebuild -downloadComponent MetalToolchain
```

See [AGENTS.md](AGENTS.md) for the full rationale and the rest of the architecture, and
[docs/kage-fork-operations.md](docs/kage-fork-operations.md) for this fork's release, CI, and
signing setup.

## Development

```bash
make check   # swift-format + swiftlint
make test    # run the tests
make format  # swift-format only
```

## Technical stack

- [The Composable Architecture](https://github.com/pointfreeco/swift-composable-architecture)
- [libghostty](https://github.com/ghostty-org/ghostty)
- [zmx](https://zmx.sh) for session persistence

## Relationship to upstream

This fork syncs from `supabitapp/supacode` regularly and aims to stay mergeable rather than
diverge. Fork changes are written to minimize conflict surface: new features live in their own
files, and integration into upstream files is kept to thin, appended edits. The rules are in
[AGENTS.md](AGENTS.md#minimizing-upstream-merge-conflicts).

If you hit a bug that is not specific to the features listed under
[What this fork adds](#what-this-fork-adds), it is most likely an upstream bug — report it
upstream, where it will help everyone.

## Contributing

Contributions are reviewed personally, line by line, and a clear issue is worth more than a
large pull request. Start by opening an issue, wait for the `ready` label, then open a focused
pull request that links it. The full process, including the rule that a human (never an AI
agent) is the accountable author, is in the [Contributing guide](CONTRIBUTING.md).

- [Contributing guide](CONTRIBUTING.md)
- [Code of Conduct](CODE_OF_CONDUCT.md)
- [Security policy](SECURITY.md)

## License

Functional Source License 1.1 with an Apache 2.0 future license, inherited unchanged from
upstream. See [LICENSE](LICENSE).
