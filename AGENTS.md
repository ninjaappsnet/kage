## Build Commands

```bash
make doctor                      # Diagnose build prerequisites (run this first on a new machine)
make build-ghostty-xcframework  # Rebuild GhosttyKit from Zig source (requires mise)
make build-app                   # Build macOS app (Debug) via xcodebuild
make run-app                     # Build and launch Debug app
make install-dev-build           # Build and copy to /Applications
make format                      # Run swift-format only
make lint                        # Run swiftlint only (fix + lint)
make check                       # Run both format and lint
make test                        # Run all tests
make log-stream                  # Stream app logs (subsystem: net.ninjaapps.kage)
make bump-version                # Bump patch version and create git tag
make bump-and-release            # Bump version and push to trigger release
```

Run a single test class or method:
```bash
xcodebuild test -project supacode.xcodeproj -scheme supacode -destination "platform=macOS" \
  -only-testing:supacodeTests/WorktreeContentHostTests \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" -skipMacroValidation
```

Requires [mise](https://mise.jdx.dev/) for zig, swiftlint, swift-format, xcbeautify, and xcsift tooling. Run `mise install` once to fetch the pinned versions.

## Toolchain setup

GhosttyKit builds with Zig 0.16 (pinned in `mise.toml`), which links current macOS SDKs, so no particular Xcode version is required: any full Xcode with a macOS 26+ SDK works, and `scripts/select-developer-dir.sh` picks one and pins `DEVELOPER_DIR` for just that build. **Run `make doctor` first** on a new machine; it checks mise on PATH, submodules, Xcode, the Metal Toolchain and the pinned mise tools, and prints the fix for each failure. On a fresh Xcode, finish its setup once: `sudo xcodebuild -license accept`, `sudo xcodebuild -runFirstLaunch`, `sudo xcodebuild -downloadComponent MetalToolchain`.

## Architecture

Supacode is a macOS orchestrator for running multiple coding agents in parallel, using GhosttyKit as the underlying terminal.

### Core Data Flow

```
AppFeature (root TCA store)
├─ RepositoriesFeature (repos + folders, worktrees, PR state, archive/delete flows)
├─ CommandPaletteFeature
├─ SettingsFeature (general, notifications, coding agents, shortcuts, github, worktree, repo settings)
├─ TerminalsFeature
│   └─ LayoutFeature (per worktree; panes / tabs / selection / focus / zoom — topology only)
│       └─ PaneLayout (value world: Pane[] → TabItem[] → ContentID)
└─ UpdatesFeature (Sparkle auto-updates)

WorktreeTerminalManager (global @Observable terminal state)
├─ selectedWorktreeID (tracks current selection for bell logic)
└─ WorktreeContentHost (per worktree; notifications, agent presence, task status)

ContentRuntime (reference world: ContentID → live TabContent)
└─ TerminalContent (per surface) → GhosttySurfaceView

WorktreeInfoWatcherManager (global worktree watcher state)
├─ HEAD watchers per worktree
└─ debounced branch / file / pull request refresh events

GhosttyRuntime (shared runtime)
└─ ghostty_app_t (single C instance)
    └─ ghostty_surface_t[] (independent terminal sessions)
```

### TCA ↔ Terminal Communication

The terminal layer (`WorktreeTerminalManager`) is `@Observable` but outside TCA. Communication uses `TerminalClient`:

```
Reducer → terminalClient.send(Command) → WorktreeTerminalManager
                                                    ↓
Reducer ← .terminalEvent(Event) ← AsyncStream<Event>
```

- **Commands**: tab creation, initial-tab setup, blocking scripts, search, Ghostty binding actions, tab/surface closing, notification toggles, and lifecycle management
- **Events**: notifications, dock indicator count changes, tab/focus changes, task status changes, blocking-script completion, command palette requests, and setup-script consumption
- Wired in `supacodeApp.swift`, subscribed in `AppFeature.appLaunched`

Worktree metadata refresh uses `WorktreeInfoWatcherClient` in parallel:

```
Reducer → worktreeInfoWatcher.send(Command) → WorktreeInfoWatcherManager
                                                           ↓
Reducer ← .repositories(.worktreeInfoEvent(Event)) ← AsyncStream<Event>
```

- **Commands**: `setWorktrees`, `setSelectedWorktreeID`, `setPullRequestTrackingEnabled`, `stop`
- **Events**: `branchChanged`, `filesChanged`, `repositoryPullRequestRefresh`
- Wired in `supacodeApp.swift`, subscribed in `AppFeature.appLaunched`

### Key Dependencies

- **TCA (swift-composable-architecture)**: App state, reducers, side effects
- **GhosttyKit**: Terminal emulator (built from Zig source in ThirdParty/ghostty)
- **Sparkle**: Auto-update framework
- **swift-dependencies**: Dependency injection for TCA clients
- **PostHog**: Analytics
- **Sentry**: Error tracking

## Ghostty Keybindings Handling

- Ghostty keybindings are handled via runtime action callbacks in `GhosttySurfaceBridge`, not by app menu shortcuts.
- App-level tab actions should be triggered by Ghostty actions (`GHOSTTY_ACTION_NEW_TAB` / `GHOSTTY_ACTION_CLOSE_TAB`) to honor user custom bindings.
- `GhosttySurfaceView.performKeyEquivalent` routes bound keys to Ghostty first; only unbound keys fall through to the app.

## Code Guidelines

- Target macOS 26.0+, Swift 6.0
- Before doing a big feature or when planning, consult with pfw (pointfree) skills on TCA, Observable best practices first.
- Use `@ObservableState` for TCA feature state; use `@Observable` for non-TCA shared stores; never `ObservableObject`
- Always mark `@Observable` classes with `@MainActor`
- Modern SwiftUI only: `foregroundStyle()`, `NavigationStack`, `Button` over `onTapGesture()`
- When a new logic changes in the Reducer, always add tests
- In unit tests, never use `Task.sleep`; use `TestClock` (or an injected clock) and drive time with `advance`.
- Prefer Swift-native APIs over Foundation where they exist (e.g., `replacing()` not `replacingOccurrences()`)
- Avoid `GeometryReader` when `containerRelativeFrame()` or `visualEffect()` would work
- Do not use NSNotification to communicate between reducers.
- Prefer `@Shared` directly in reducers for app storage and shared settings; do not introduce new dependency clients solely to wrap `@Shared`.
- Every main-actor class declares `nonisolated deinit` (empty, or its body wrapped in `MainActor.assumeIsolated`): a synthesized isolated deinit aborts on macOS 26.3 and earlier when released in a task-local scope (#853). Enforced by `make build-app` and `make test`; drop at macOS 26.4+.
- Use `SupaLogger` for all logging. Never use `print()` or `os.Logger` directly. `SupaLogger` prints in DEBUG and uses `os.Logger` in release.
- Avoid top-level free functions. Default to `static` methods, computed properties, or instance methods on a relevant type (enum/struct/extension). Free functions pollute the module namespace, are harder to discover, and easily drift from the inline implementation a consumer ends up writing instead. If the operation is pure and stateless, make it a `static` on a caseless `enum` or the most relevant type, not a top-level `func`.
- Closure-typed focused values invalidate the AppKit menu on every body run (closures have no Equatable conformance, so SwiftUI re-publishes every time). Always wrap menu-bar action closures with `FocusedAction<Input>` and publish via `.focusedSceneAction(_:enabled:token:perform:)` / `.focusedAction(_:enabled:token:perform:)`. The wrapper dedupes on `(isEnabled, token)`, so AppKit only rebuilds the menu when something the menu actually displays changes. Token rules in `App/Models/FocusedAction.swift`: set `token` to a hashable projection of any captured state that affects behavior; leave it `nil` when the closure captures only the store / `@State` bindings. Consumers should read the action with `@FocusedValue(\.x)` and gate with `action?.isEnabled != true`, not `action == nil`.
- Sidebar rows must not fan out invalidation. Per-row state lives in `RepositoriesFeature.State.sidebarItems` so a per-leaf mutation (notification tick, agent activity, running-script update) invalidates only that leaf, not every sibling. The view renders the cached `state.sidebarStructure` (computed in the reducer's post-reduce hook), never reading `sidebarItems[id:]` from a view body; derive per-leaf data in `computeSidebarStructure(...)`, not in the view.
- Never lift content-specific (e.g. terminal-only) mechanics or state into the layout layer. `LayoutFeature` owns topology and strip mechanics only (panes, tabs, selection, focus, zoom, rename identity); anything a specific content kind produces (agent badges, progress, script locks, busyness, reported title, pwd) lives on the content side, exposed to the strip through the content's observable `TabChrome` (`Features/Terminal/Content/TabChrome.swift`), never as layout reducer state or actions. High-frequency reported signals (title, pwd, bell) are the sharp edge of this rule: an agent TUI rewrites its title several times a second, so a reported title lands on the content's chrome and reaches the layout only as one discrete commit at teardown (`titleCommitted`), never one reducer action per report. The strip and window title read the live value off `TabChrome` (`TabTitle.resolved`), and persistence pulls it into the snapshot (`TabTitle.stored`).

### Formatting & Linting

- 2-space indentation, 120 character line length (enforced by `.swift-format.json`)
- `make format` runs the mise-pinned `swift-format` (`spm:swiftlang/swift-format` in `mise.toml`), NOT the Xcode toolchain's built-in `swift format`. The pin keeps formatting reproducible across contributors' Xcodes — an unpinned toolchain formatter rewrites the whole tree (e.g. Swift call-site trailing commas) and produces spurious churn. Bump the pin in lockstep with the Swift toolchain (tag `60X.x` ↔ Swift 6.X).
- Trailing commas are mandatory (enforced by `.swiftlint.yml`)
- SwiftLint runs in strict mode; never disable lint rules without permission
- Custom SwiftLint rule: `store_state_mutation_in_views` — do not mutate `store.*` directly in view files; send actions instead

## UX Standards

- Buttons must have tooltips explaining the action and associated hotkey
- Use Dynamic Type, avoid hardcoded font sizes
- Components should be layout-agnostic (parents control layout, children control appearance)
- Never use custom colors, always use system provided ones.
- We use `.monospaced()` modifier on fonts when appropriate

## Rules

- After a task, ensure the app builds: `make build-app`
- Automatically commit your changes and your changes only. Do not use `git add .`
- Before you go on your task, check the current git branch name, if it's something generic like an animal name, name it accordingly. Do not do this for main branch
- After implementing an execplan, always submit a PR if you're not in the main branch

## Minimizing Upstream Merge Conflicts

This repo is a fork that periodically syncs from upstream `supabitapp/supacode` (`git fetch upstream`, sync against `upstream/main`). Every local change must be written to survive an upstream rebase/merge with the smallest possible conflict surface. Order of preference for any new feature:

1. **New files over edits.** A new file at a path upstream doesn't use never conflicts. Put feature code in its own files/folder (e.g. `Features/FileExplorer/`). This is the only way to get a truly zero-conflict change.
2. **Append, don't restructure.** When you must touch an upstream file, add lines at the tail of a list / end of a type / after an existing call — never re-indent or wrap an existing block. Re-indenting upstream code (e.g. wrapping a view in a new `HStack`/`VStack`) turns every upstream edit to the inner lines into a conflict. Prefer appended SwiftUI modifiers (`.safeAreaInset`, `.overlay`, `.modifier`) on an existing view over wrapping it.
3. **Move extensible plumbing into your own files.** `extension FocusedValues`, `extension` methods / computed props, `FocusedValueKey` conformances, etc. are cross-file extensible — define them in a feature-owned file, not inside the upstream type's file. (Swift `enum` cases and `switch` arms are NOT extensible; those edits are unavoidable — keep them minimal and mechanical.)
4. **Keep integration in one thin commit.** Separate "new files" commits (conflict-proof) from a single small "wire it in" commit. On rebase only that one commit can conflict, and it stays reviewable.
5. **Don't reformat upstream files.** Format churn on lines you didn't logically change is a guaranteed conflict. Touch only what the feature needs.
6. **Auto-generated locks** (`Tuist/Package.resolved`): never hand-merge. On conflict take upstream's and regenerate (`tuist install`).
7. **Sync often.** Rebase the feature branch on `upstream/main` frequently — many tiny conflicts beat one big-bang merge.
8. **Sync with `/pull-upstream`.** The skill (`.claude/skills/pull-upstream/`) runs the fetch → merge → rebrand → verify order and carries the conflict-classification rules. Upstream's user-facing copy says "Supacode"; this fork renames it, so those lines conflict by design — take upstream's side and re-run `make rebrand-fix`.

When reviewing your own diff, classify each touched **upstream** file as additive-safe vs landmine, and justify why each landmine couldn't be made additive.

## Sidebar performance

- Per-row `SidebarItemFeature` state lives in `RepositoriesFeature.State.sidebarItems: IdentifiedArrayOf<SidebarItemFeature.State>` (see commit `0a1ed578`, "Improve sidebar performance and refresh reliability"). The whole point is that a per-leaf mutation (notification tick, agent tool storm, running-script update) invalidates only that leaf's view, not every sibling.
- The sidebar view is a dumb renderer over `state.sidebarStructure` (see `Features/Repositories/BusinessLogic/SidebarStructure.swift`). The structure is computed inside the reducer's post-reduce hook so per-leaf reads stay in reducer context. `SidebarListView.body` reads only the cached `state.sidebarStructure`, never `sidebarItems[id:]` directly. If you find yourself iterating leaves from a view body to derive something, move that derivation into `computeSidebarStructure(...)` and let the cache flow back through.
- The post-reduce hook is gated by `\.sidebarStructureAutoRecompute` (default `true` in live + preview + test) so production and tests see the same fresh cache. TestStore expectations that mirror a structure-affecting action should call `$0.recomputeSidebarStructureIfChanged()` (post-reduce hook mirror) or `$0.reconcileSidebarForTesting()` (when the reducer body also calls `syncSidebar`). Legacy tests that don't care about the cache can opt out via `withDependencies { $0.sidebarStructureAutoRecompute = false }`. The set of actions that trigger recompute is enumerated in `RepositoriesFeature.Action.affectsSidebarStructure`; the `.sidebarItems` arm delegates to `SidebarItemFeature.Action.affectsSidebarStructure` so display-only per-leaf actions (diff stats, PR refresh, drag/focus/hint) skip the recompute entirely. Add new structure-affecting cases on whichever side is appropriate.
- The recompute helper uses an Equatable diff against the cached value, so a no-op rebuild (e.g. an action that touched per-leaf state in a way that didn't change classification) does NOT invalidate SwiftUI observation.
- When you need a row-level aggregator that ISN'T part of the global structure (per-group indicators inside a nested branch path, for example), extract a dedicated subview taking `parentStore: StoreOf<RepositoriesFeature>` + `leafIDs: [SidebarItemID]` and per-leaf-scope inside its own body. See `SidebarPathGroupAggregatedIndicators` in `Features/Repositories/Views/SidebarItemsView.swift`.

## Highlight Relevant Sidebar Items

- Two View-menu toggles under the "Group Relevant Sidebar Rows" submenu (see `Commands/SidebarCommands.swift`): `@Shared(.sidebarGroupPinnedRows)` and `@Shared(.sidebarGroupActiveRows)`, both default `true` so the feature is discoverable on first launch. Each is independent: turning one off hides only its hoisted section; the rows fall back into their per-repo position.
- The sections are NOT collapsible (no `Section(isExpanded:)`). Visibility is purely the toggle state plus "are there qualifying rows".
- `SidebarStructure.sections` is the single ordered list the view renders. Cases: `.highlight(kind, rowIDs)` for Pinned / Active hoists, `.repository(id, groups)` for git repos (groups are precomputed `[SidebarItemGroup]` slot payloads), `.folder(id, rowID)` for folder repos, `.failedRepository(id, rootURL, message)`, `.placeholder` for the first-launch shimmer. `SidebarListView` does one `ForEach(structure.sections)` and dispatches via a single switch in `SidebarSectionDispatcher`. Non-repo cases set `.moveDisabled(true)` so the outer `.onMove` only reorders repository sections.
- `SidebarActiveClassification` (`BusinessLogic/SidebarStructure.swift`) is a 10-bucket priority enum keyed off four leaf-local flags (`hasUnseenNotifications`, `hasAgentAwaitingInput`, `!state.agents.isEmpty`, `!runningScripts.isEmpty`). The `hasAgent` flag matches visible agent-badge presence (any tracked instance, including `.idle`) so a row with an agent badge surfaces in Active even when the agent isn't actively working. Rows that don't classify are dropped from Active and (when the Pinned section is in play) fall to the bottom of Pinned alphabetically. `SidebarHighlightOrdering` is the pure helper that owns the priority + alphabetical sort; both have direct unit coverage in `SidebarActiveClassificationTests.swift` / `SidebarHighlightOrderingTests.swift`. Terminating-lifecycle rows (`SidebarItemFeature.State.Lifecycle.isTerminating`: `.archiving`, `.deletingScript`, `.deleting`) are excluded from the Active candidate set so a row mid-wind-down doesn't surface in the rail. `.pending` stays eligible because a pending row running a setup script is exactly what Active is meant to surface.
- `SidebarStructure.hoistedRowIDs` is the union of every hoisted row across both highlight sections. `SidebarItemGroup.computeSlots(...)` filters every per-repo slot (main / pinnedTail / pending / unpinnedTail) against this set, so a hoisted row never double-renders. A `seen: Set` dedupe inside `computeSlots` also catches a pre-existing double-bucket pre-state (same id in `.pinned` and `.unpinned`) so the row appears in at most one slot regardless of bucket state.
- Highlight rows get a colored `repo · trail` subtitle. The subtitle composes inside an `HStack` with `.layoutPriority(1)` on the repo so the colored repo tag doesn't get truncated first under a narrow sidebar; the trail yields first instead. The repo color and name come from `SidebarStructure.repositoryHighlightByID`, built once per recompute, and the repo name resolves through `Repository.sidebarDisplayName(custom:fallback:)` so the highlight tag and `RepoSectionHeaderView` stay in lockstep on a customized title. `.repositoryCustomization(.presented(.delegate(.save)))` is wired into `affectsSidebarStructure` so the cache flushes immediately on save.
- Hotkey numbering (⌃1..⌃0) reads `SidebarStructure.slotByID`; the view does one trivial join with `commandKeyObserver.isPressed` + shortcut overrides to convert slot index to display string. `SidebarStructure.hotkeySlots` is the projected `[HotkeyWorktreeSlot]` published to `focusedSceneValue(\.visibleHotkeyWorktreeRows, ...)` for the menu bar.
- When `@Shared(.sidebarNestWorktreesByBranch)` is on, the view's branch-tree builder re-sorts each git bucket alphabetically before nesting. `SidebarItemGroup.computeSlots(...)` mirrors that sort (case-insensitive `localizedCaseInsensitiveCompare` on `branchName`, matching `SidebarBranchNesting.buildRows`) so `slotByID` / `hotkeySlots` line up with the visible order. Toggling the option dispatches `.sidebarNestByBranchChanged` from `SidebarListView.onChange`, which `affectsSidebarStructure` flags so the cache rebuilds.
- Folders are pinnable through the same `pinWorktree` / `unpinWorktree` actions as git worktrees. The pin / unpin flow uses `SidebarState.removeAnywhere` + `insert` to enforce the "exactly one bucket" invariant against any pre-state (hand-edit, migrator race) where a row lives in two buckets simultaneously. A hoisted folder is omitted from its `.folder` section entirely; `SidebarStructure` knows not to emit it.
- Auto-dismiss of the highlight onboarding card fires from two places that cover the realistic entry points. (1) The reducer handler for `.sidebarGroupingTogglesChanged` bumps `@Shared(.appStorage("highlightRelevantOnboardingDismissedAt"))` when both grouping toggles end up off; this covers any path that flips a toggle while `SidebarListView` is mounted (the `.onChange` watcher dispatches the action). (2) The menu bindings in `SidebarCommands.groupPinnedRowsToggle` / `groupActiveRowsToggle` fire the same dismiss inside their setter, mirroring `nestWorktreesToggle`, so toggling from the menu bar while the sidebar column is collapsed still dismisses the card.

## Folder (non-git) repositories

- `Repository.isGitRepository` classifies each root at load time via `Repository.isGitRepository(at:)`, which approximates git's own `is_git_directory()` check: `.bare` / `.git` root-name shortcut, then `rootURL/.git` existence (worktree root, covers primary / linked / submodule / `--separate-git-dir` layouts), then the `HEAD` + `objects` + `refs` trio at the root — with `HEAD` required to be a regular file (git rejects a `HEAD` directory) — so any git dir is recognized regardless of naming, including bare clones whose directory name does not end in `.git`. Classification runs through the injected `GitClientDependency.isGitRepository` closure so tests can override it without touching the filesystem.
- A folder-kind repository has exactly one synthesized "main" `Worktree` with `id = "folder:" + path` (see `Repository.folderWorktreeID(for:)`), `workingDirectory == rootURL`. Selection and terminal binding reuse the standard `SidebarSelection.worktree(id)` machinery — nothing git-specific runs for folders.
- The sidebar renders each folder as its own `Section` with an empty header (`header: { EmptyView() }`, kept so `.listStyle(.sidebar)` keeps a visible section break between consecutive folder repos) and a single selectable row. The context menu offers the same entries as a git worktree row, minus archive / "Copy as Branch Name", plus "Folder Settings…" (the section has no header so there is no ellipsis menu). Folders ARE pinnable: a folder synthetic worktree seeds into the `.unpinned` bucket by default and the user can pin / unpin it through the same `pinWorktree` / `unpinWorktree` actions that govern git worktrees. `reconcileSidebarState` skips the `mainID == worktreeID` prune for folder repos so a folder pin survives `.repositoriesLoaded`. The folder row's view path resolves via `Repository.folderWorktreeID(for:)` rather than the `.pinned` bucket so it stays visible across pin / unpin transitions.
- The Delete Script for a folder runs through the existing `.requestDeleteSidebarItems` → `.confirmDeleteSidebarItems` → `.deleteSidebarItemConfirmed` → `.deleteScriptCompleted` pipeline; the handlers branch inside so `gitClient.removeWorktree` is never called for a folder and the success path emits `.repositoryRemovalCompleted`, which the batch aggregator drains into a single `.repositoriesRemoved` terminal. `removingRepositoryIDs` is the source of truth for "this is a folder delete" so the intent survives a `git init` happening between confirmation and completion.
- Settings hides the Setup and Archive Script sections for folders; Delete Script and user-defined scripts stay. `openRepositorySettings` (context menu + deeplink) routes folders to `.repositoryScripts` because there is no general pane for them.
- `worktreesForInfoWatcher()` filters out folder repositories so the HEAD watcher never probes a non-git path. The command palette renders folder rows as the repo name alone instead of `Foo / Foo`, and worktree deeplinks for `.archive` and `.unarchive` reject folder targets with an explanatory alert. `.pin` and `.unpin` flow through the shared bucket machinery and are valid for folders.
- Creating new worktrees on a folder is rejected up front in `createRandomWorktreeInRepository` / `createWorktreeInRepository` and in the `.repoWorktreeNew` deeplink handler — the menu / hotkey / palette never reaches `gitClient.createWorktreeStream` for a folder target.

## Scripts (repo + global)

- A `ScriptDefinition` (`SupacodeSettingsShared/Models/ScriptDefinition.swift`) is the user-facing run target for the toolbar Script Menu, command palette, and `runScript` deeplinks. Repo scripts persist in `RepositorySettings.scripts`; user-global scripts persist in `GlobalSettings.globalScripts`.
- Globals are always `ScriptKind.custom` — enforced by `SettingsFeature.addGlobalScript` (constructor) and `GlobalSettings.init(from:)`'s decode normalization. These are the load-bearing pair against a forged `"kind": "run"` global hijacking the primary toolbar slot. `merged`'s "repo first" ordering is a semantic UX choice, not a security guard — a future reorder for UX (alphabetical, recency) must not be relied on for invariant enforcement.
- `[ScriptDefinition].merged(repo:global:)` is the canonical merge: repo first, then globals, deduped by ID with repo winning collisions. Four call sites with deliberately different inputs — `AppFeature.State.allScripts` (TCA state), `AppFeature`'s deeplink `resolveScript(scriptID:in:)` (reads `@SharedReader` pre-state-load), `WorktreeToolbarState.allScripts` (toolbar VM), and `supacodeApp.swift`'s socket query (persisted snapshot for arbitrary worktree). Don't unify them.
- `AppFeature.State.resolveScript(id:)` is the single canonical lookup helper for state-resident scripts; `runNamedScript` re-resolves through it so a stale view binding can't bypass repo-wins or run a since-deleted script.
- The toolbar `ScriptMenu` filters globals through `WorktreeToolbarState.visibleGlobalScripts` — drops globals shadowed by a repo ID and globals with empty commands, so half-configured entries don't surface in N repo toolbars.
- Removing a script does not stop running instances — the alert copy warns the user. The terminal tab cleans up on natural completion or manual close.
- Decode resilience: `KeyedDecodingContainer.decodeLossyArrayIfPresent(forKey:)` (in `Lossy.swift`) is the API — it returns `nil` on missing key (caller may run a legacy migration), `[]` on a malformed array, and `[T]` with bad elements logged and dropped. `ScriptDefinition.init(from:)` uses `try?` on `tintColor` / `systemImage` so a malformed override drops the field, not the whole entry.
- Settings deeplink: `supacode://settings/scripts` opens the Global Scripts pane. CLI: `supacode settings scripts`.

## Colors

- `RepositoryColor` (`SupacodeSettingsShared/Models/RepositoryColor.swift`) is the canonical user-customizable tint enum, used by sidebar repo headers, script icons, terminal tab tints, sidebar running-script dots, layout snapshots, and `runningScriptsByWorktreeID`. Predefined cases: `red`, `orange`, `yellow`, `green`, `teal`, `blue`, `purple`. The `.custom(hex)` case carries `#RRGGBB[AA]`.
- `ColorSwatchRow` (`SupacodeSettingsFeature/Views/ColorSwatchRow.swift`) is the shared swatch picker used by repository customization (`RepositoryCustomizationView`) and per-script color overrides. The picker binds through a `Binding<Color>(get/set)` so predefined / Default clicks set the color directly without the panel demoting them to `.custom(hex)` — only view-driven panel drags reach `set` and capture as `.custom(hex)` (intentional intent capture).
- Forward compat: `RepositoryColor.custom(_:)` encodes as `"#RRGGBB[AA]"`. Older builds (pre-`.custom`) decode tints via a String-rawValue enum and reject hex values. `TerminalLayoutSnapshot.TabSnapshot.tintColor` and `ScriptDefinition.tintColor` both lossy-decode the field on the current build, but this only protects forward (old data on new build) — a custom-hex tint persisted on this build is silently dropped on downgrade. Don't ship a downgrade-via-Sparkle path for users who may have set custom tints.

## Submodules

- `ThirdParty/ghostty` (`https://github.com/ghostty-org/ghostty`): Source dependency used to build `Frameworks/GhosttyKit.xcframework` and terminal resources. The pin tracks upstream; local changes live as out-of-tree patches in `patches/*.patch`, applied to the working tree by `scripts/build-ghostty.sh` before `zig build` and reverted on exit (the pin is never moved, no fork). On a ghostty bump a patch may stop applying and the build fails loudly: refresh the patch, and prefer upstreaming it to retire the carry cost. Run one ghostty build at a time (the apply/revert shares the submodule working tree).
- `Resources/git-wt` (`https://github.com/khoi/git-wt.git`): Bundled `wt` CLI used by Supacode Git worktree flows at runtime.

## On-disk config layout (Kage brand)

- Every path is derived from `KageBrand` (`SupacodeSettingsShared/Support/KageBrandPaths.swift`): `~/.kage` (worktree storage under `repos/`, `.backup/`, legacy config files), `~/.config/kage` (`config.json` / `routes.json` / `repos.json` / `config.ghostty`, honoring `$XDG_CONFIG_HOME`), and `<repo>/kage.json` per repository. Upstream's `~/.supacode`, `~/.config/supacode` and `<repo>/supacode.json` are named in the same file as `legacyBrand*` accessors and read only by the migration. `SupacodePaths` keeps exactly three references to the brand constants — keep it that way so the rename stays a one-file concern on an upstream sync.
- `KageBrandMigrator` runs first at launch (`supacodeApp.swift`), before `SettingsRelocationMigrator`, so the relocation only ever sees branded paths and a user arriving from any upstream build lands in the same place. It never overwrites a branded file with a legacy one (the branded copy is the live one) and is idempotent.
- Worktree storage is the one destructive step: git records absolute paths in both the worktree's `.git` file and the main repo's `worktrees/<id>/gitdir`, so each `repos/<repo>` tree is moved, `git worktree repair`ed, re-verified, and **rolled back to its legacy path when verification fails**. Only repositories that verified get their stored paths rewritten. Worktree ids *are* paths, so the rewrite covers `config.json` / `routes.json` / `repos.json` plus the `sidebarState`, `layoutsFile` and legacy order keys in UserDefaults — a missed rewrite orphans a sidebar row. Live zmx sessions whose cwd was inside a moved worktree keep a stale cwd until restarted.
- Per-repository files convert in the migration, not at read time: `RepositorySettingsKey` reads `kage.json` only. A repository added after the migration carrying just upstream's `supacode.json` is converted on the next launch (the conversion re-runs every launch over `routes.local`). A read-time fallback was tried and reverted: it costs a second disk probe per repository, which `SidebarStructureTests` pins.
- `SettingsStoreRecovery` repairs the one relocation end state the app cannot climb out of: `.relocated` stamped over a store holding nothing while the real `settings.json` sits in `.backup`. It restores the archive, drops the marker, clears the empty `sidebarState` / `layoutsFile`, and stamps `.store-repaired` so it never runs twice. The root-cause guard lives in `SettingsRelocationMigrator`: "all three files decode" is structural, so the seed re-runs and the marker is withheld while `storeLacksLegacyRepositories(...)` holds.

## Remote Kage hosts (fork feature)

- Settings → Remote Hosts lists other Macs running Kage (name + username + DNS/IP, `RemoteKageHost`), persisted in `~/.config/kage/remote-hosts.json` (`RemoteKageHostsFileKey`), never in `kage.json`. Code lives in `supacode/Features/RemoteKage/`; upstream files only carry the wiring (`SettingsSection` case + Settings row/arm, `AppFeature` state/action/scope/launch task, `SidebarSelection.remoteKage` case, one appended view in `SidebarListView`, one branch in `WorktreeDetailView`, the `host-snapshot` arm in `supacodeApp.handleQuery`, `HostCommand` in the CLI, the `bin/kage` symlink). It is separate from Remote SSH repositories: here the other Mac runs its own Kage and this Mac only views it.
- Wire contract: `HostSnapshot` (versioned by `schemaVersion`; add fields as optionals, bump only for changes an older viewer would misread). The host builds it in `HostSnapshotBuilder` (pure) + `HostSnapshotRuntime` (main-actor gathering) and answers the `host-snapshot` socket query; `kage host snapshot` prints it as one JSON line and exits 69 when Kage is not running (it never launches Kage). `kage` is a symlink alias of the `supacode` CLI; help text follows argv[0] (`CLIInvocationName`), and `CLIInstaller` manages both links.
- Polling (`RemoteKageFeature`): every host every 5 s over `ShellClient.ssh` with the shared ControlMaster (`SSHCommand.controlOptions`), at most one request in flight per host, failures back off 5/10/20/40/60 s. `RemoteKageCommandResult` classifies outcomes: ssh 255 → unreachable, old CLI → needsUpdate, exit 69 → kageNotRunning. Notifications fire on a tab's transition to awaiting input, never on a host's first snapshot and never for the tab being watched.
- Sidebar: remote rows are NOT part of `SidebarStructure` / `sidebarItems`; `RemoteKageSidebarSections` renders from `RemoteKageSidebarModel` (pure). `repositories.selection` is the single source of truth; `RemoteKageSelectionSync` forwards a remote selection into `remoteKage.select`.
- Machine groups (`Features/SidebarGroups/`): with at least one host configured the sidebar shows two persisted accordions, "This Mac" (all local sections; collapsing feeds an empty array to the sections `ForEach` via `SidebarMachineGroups.visibleLocalSections`) and "Remote Hosts" (host sections, whose workspaces collapse too). Expansion lives in `@Shared(.appStorage)` keys (`sidebarThisMacExpanded`, `sidebarRemoteHostsExpanded`, `RemoteKageSidebarExpansion` holding only what is *collapsed*), never in `SidebarStructure`. `SidebarMachineGroupsReveal` (one modifier on the sidebar `List`) opens the group / host / workspace holding any new selection or reveal request. Group and workspace headers are plain unselectable rows (no `DisclosureGroup`), so they stay valid in `List(.sidebar)`. Workspace picker placement is decided by `SidebarWorkspacePicker.placement(hostCount:)` (pure, `SidebarWorkspacePicker.swift`): with hosts the picker lives in the "This Mac" band as "This Mac · <workspace> ⌃⌄" (`SidebarWorkspaceBandMenu`, an accessory of `SidebarMachineGroupHeader`; the band still toggles, the workspace part opens the menu, long names cut to `bandTitleLimit`, collapsed band shows the bare project count) and the pinned `WorkspaceSwitcherView` strip renders nothing; both share `WorkspacePickerMenu`. No hosts: no headers, picker pinned above the list, sidebar unchanged.
- Attach: `RemoteKageAttachedSurface` owns a bare `GhosttySurfaceView` on `GhosttyRuntime` running `ssh -tt … zmx attach` inside `SSHReconnectLoop`; it never touches `LayoutFeature` / `ContentRuntime` / `WorktreeTerminalManager`. The remote script checks `zmx list` first so a vanished session is never recreated. Unmounting the view detaches; `onExit` sends `detachTab`. Two viewers on one zmx session: only the client that last typed sets the size (zmx leader), so a session shows at the host's size until the first keystroke here. Accepted for v1.
- Remote files (`Features/RemoteKage/RemoteFiles/`): `RemoteKageServeSession` (an actor, one per host, owned by `RemoteKageFileSessions`) runs `ssh -T … '<cli> host serve'` (CLI path from the host's snapshot, `RemoteKageServeCommand`) and speaks protocol v1 (`RemoteFileWire`) over its pipes: request ids with pending continuations, hello first, events fanned out to watchers, the watch set sent as the union of all watchers and only when it changes. It opens only while a visible explorer or viewer holds it (`hold()` from a view `.task`), closes 30 s after the last one leaves (stdin EOF, kill 5 s later), reconnects with the polling backoff while visible (then re-sends the watch set and emits `rescan`), and treats an old host (exit 64 / "Unexpected argument 'serve'") or a newer protocol as final: no retries until it has idle-closed. `RemoteFileSystemSource` puts it behind `FileSystemSource` (registered as `remote-kage:<host id>`) and never standardizes paths (`standardizedFileURL` consults this Mac's disk). `RemoteKageWorktreeView` shows the docked `FileExplorerPanel` (same ⌥⌘E / `fileExplorerVisible` as local) and a right-hand `RemoteKageFileViewerPane` over the local `FileViewerTabView`. All transport goes through `RemoteKageServeLauncher`, so tests run the real CLI (`RemoteKageServeEndToEndTests`) or a fake host. Measured against a mini: idle explorer + viewer is 0 CPU and no bytes on the channel; the host process exits about 30 s after the files UI closes.
- Tests that spawn processes must not block the main actor (`waitUntilExit` spins the run loop and lets the test host's SwiftUI re-enter, crashing in `ClaudeUsageSidebarPanel`'s `TimelineView`); wait through `terminationHandler` or run `nonisolated`.

## Checking the UI without disturbing the running Kage

- Never launch the plain Debug build or quit / restart `/Applications/Kage.app`: the developer (and often this agent session) is running inside it. Use `scripts/dev-sandbox-app.sh` instead: it copies the Debug build to `.build/dev-sandbox/Kage Sandbox.app` under its own bundle id (`net.ninjaapps.kage.devsandbox`, so its own UserDefaults) and launches it with its own `HOME`, `XDG_CONFIG_HOME` and `ZMX_DIR` (its own config and zmx sessions), seeded with the remote hosts and repository list only. `launch`, `snapshot <tag>`, `defaults <key> <value>` (live, e.g. `sidebarThisMacExpanded false`), `quit`, `reset`.
- Remote files can be driven without Accessibility permission: `scripts/dev-sandbox-app.sh remote <command>` (`select:<host name>|<worktree path>`, `explorer:on`, `explorer-root:<path>`, `open:<path>`, `append:<text>`, `save`, `reload`, `close`, `mark:<text>`; `RemoteKageFilesDebugCommands`, Debug + `KAGE_DEBUG_SNAPSHOT_DIR` only). `KAGE_SANDBOX_ENV="KAGE_REMOTE_CLI_PATH_OVERRIDE=/abs/path/supacode" scripts/dev-sandbox-app.sh launch` runs a CLI you copied to the host instead of the host's installed one (Debug builds only), for trying `host serve` before a host has the release. A sandbox launched in the background may come up without its main window; `open -g ".build/dev-sandbox/Kage Sandbox.app"` reopens it without taking focus.
- Privacy grants follow the bundle id: Debug builds are `net.ninjaapps.kage.debug` (`Project.swift`, pinned by `DebugBundleIdentifierTests`) and the sandbox `net.ninjaapps.kage.devsandbox`, so neither can take over the installed Kage's Screen Recording / Accessibility grant. Never give an ad-hoc build the release id `net.ninjaapps.kage`: on 2026-11-25 an allowed prompt from such a build re-bound the "Kage.app" grant to its cdhash and the installed Kage then prompted in an endless loop. Launch the sandbox once per check and `quit` it; never relaunch it in a loop. To see who asks for a permission: `log show --last 10m --predicate 'subsystem == "com.apple.TCC" AND eventMessage CONTAINS "AUTHREQ_ATTRIBUTION"'`.
- Screenshots: agent shells have no Screen Recording permission (macOS attributes the request to the `claude` binary, which changes every update), so do not run `screencapture`. `snapshot` makes the sandbox app draw its own windows (`DebugWindowSnapshot`, Debug builds only, `KAGE_DEBUG_SNAPSHOT_DIR`) into `.build/dev-sandbox/shots/`. Sidebar outline views are also written on their own (`*-outline-N.png`, transparent background, only rows on screen). Vibrant text and materials render without vibrancy and Metal terminal surfaces render blank, so judge layout and tints, not exact text colors.

## Fork operations (releases, CI, signing)

This fork's release cadence, self-hosted runner constraints, signing and
notarization secrets, and Sparkle key handling live in
[`docs/kage-fork-operations.md`](docs/kage-fork-operations.md). Read it before
cutting a release or touching `.github/workflows/`. In particular: never bump a
version unprompted, and pushes touching only workflows or docs deliberately
produce no build.

## Claude Accounts (fork feature)

- Settings → Claude Accounts runs several Claude Code logins side by side. Code lives in `supacode/Features/ClaudeAccounts/`; upstream files only carry the wiring (a `SettingsSection` case, the sidebar row and detail arm in `SettingsView`, the scoped reducer in `AppFeature`, the `environmentExtras` merge and `ClaudeAccountCommands` in `supacodeApp.swift`).
- The main account is plain `~/.claude` and is never stored. Every other account is a `CLAUDE_CONFIG_DIR` under `~/.kage/claude-accounts/<slug>`, whose shared entries (`projects/`, `skills/`, `agents/`, `commands/`, `output-styles/`, `plugins/`, `settings.json`, `CLAUDE.md`, `history.jsonl`, `keybindings.json`) are symlinks into `~/.claude` (`ClaudeAccountLayout.sharedEntries`). `.claude.json`, the Keychain login and `sessions/` stay per account. The directory path never moves and is stored without a trailing slash: Claude Code keys the Keychain entry to the exact `CLAUDE_CONFIG_DIR` string.
- Layout repair runs on every launch and never deletes: a real item where a link belongs is adopted into the hub, merged child by child, or moved under `.kage-unlinked/<timestamp>/`.
- User-scope MCP servers live in each account's `.claude.json`, so `ClaudeMCPServerSync` three-way merges them against `ClaudeAccountsFile.mcpServersBaseline` (main wins conflicts; absence is a value, so removals propagate) and writes through `claude mcp add-json` / `remove`, never by editing `.claude.json` directly.
- Session account resolution (`ClaudeAccountsFile.resolvedAccount`): tab assignment (File → New Tab with Claude Account) → repository override → default. It is applied once per surface in `ClaudeAccountEnvironment`; a running zmx session keeps the account it started with. Remote worktrees get nothing.
- Choices persist in `~/.config/kage/claude-accounts.json` (`ClaudeAccountsFileKey`), never in `kage.json`, so they are never committed.
- Usage %: `ClaudeCredentials` reads each account's OAuth token from the Keychain via `/usr/bin/security` (service `Claude Code-credentials[-<sha256(CLAUDE_CONFIG_DIR) prefix 8>]`, no prompt because Claude Code wrote it with the same tool) and calls the undocumented `api.anthropic.com/api/oauth/usage`. Read-only: never refresh the token (it rotates the refresh token and logs Claude Code out); an expired token just skips the fetch. Fetched after each logged-in status, throttled to once a minute per account, last good value kept on failure. Shown in Settings rows and as "Name — 42% weekly" in account menus.
- New tabs and splits inherit the account of the surface they were opened from (`ClaudeSurfaceAccounts.byContentID`, in memory) and persist it as a tab assignment. The tab strip's chevron menu offers "New Tab with Claude Account" via a 5-second one-shot request (`requestAccountForNextTab`) consumed by the next `.tab` surface. Stale `tabAccountIDs` are pruned at launch against the persisted layouts (skipped when that file decoded lossily).
- "Restart Tab with Claude Account" (tab context menu, File menu) swaps the tab's content for a fresh one under a new content id (`LayoutFeature.replaceTabContent`), so zmx starts a new session with the new env; `claude --continue` is typed in when the old surface had a Claude agent.
- Sidebar usage panel (`ClaudeUsageSidebarPanel`, View → Show Claude Usage in Sidebar, `@Shared(.claudeUsageSidebarPanelVisible)`, default on): one row per account with weekly %, reset time and "2d 5h 12m left". It sits in its own bottom `safeAreaInset` below `SidebarBottomCardView` and re-fetches logged-in accounts every 5 minutes only while visible (`usagePanelAppeared` / `usagePanelDisappeared`). Upstream's feature-announcement cards are filtered out there by `Slot.withoutAnnouncements`; the git-error and agent-install cards stay.
- Reminders: `claude auth status --json` (`loggedIn`, `loginExpiresAt`) is polled on launch and every 30 minutes. A notification fires at most once a day per account when its login is within 3 days of expiry, or has expired / logged out after having been logged in. A logout the user did themselves clears `loggedInAccountIDs` so it stays quiet.

## Dotfiles sync (fork feature)

- Settings → Sync keeps Claude Code, Codex and Kage settings plus per-project Claude memory in sync between machines through a user-owned private git repository. Code lives in `supacode/Features/DotfilesSync/`; upstream files only carry the wiring (a `SettingsSection` case, the sidebar row and detail arm in `SettingsView`, the scoped reducer and launch `.task` in `AppFeature`, the `WorktreeMenuSnapshot` arm).
- Files are **copied**, never symlinked: Claude Code saves `settings.json` by replacing it, which would turn a link back into a plain file. `DotfilesSyncEngine` mirrors allowlisted files (`DotfilesSyncRoot.defaults`) into a clone at `~/.kage/dotfiles`, commits, fetches + merges, copies the result home and pushes. Logins (`.claude.json`, Keychain, Codex `auth.json`), transcripts, history, caches and databases are never in the allowlist.
- Username independence: text is stored with the home folder as `{{HOME}}` (`DotfilesHomeToken`), expanded on the way out.
- Claude memory is keyed by project identity, not path: `claude-memory/<normalized origin remote>/` (`DotfilesProjectIdentity`), or `local/<root commit>` without a remote. Each machine derives its own key → `~/.claude/projects/<encoded root>/memory` map from transcripts' `cwd` and Kage's repository roots; the map is never synced (paths are local by nature). Worktrees share the main checkout's memory folder.
- Deletions compare against this machine's last pass (`.git/kage-sync-state.json`), never against the repository, so memory for a project this machine doesn't have is not read as deleted.
- Conflicts: only Claude memory and JSON reconcile on their own. `*.json -merge` forces JSON through `DotfilesJSONMerge` (three-way; arrays as ordered sets; clashing scalars keep local). Memory text goes through git's line merge, then a locked-down `claude -p` (`--tools "" --setting-sources "" --strict-mcp-config --no-session-persistence`, validated output, at most `maximumModelMergesPerPass` per pass), else local wins and the remote copy lands in `~/.kage/dotfiles-conflicts/`. Everything else that differs (skills, agents, commands, hooks, rules, CLAUDE.md, config.toml) is a `DotfilesVersionConflict` the user resolves in Settings → Sync: one choice per skill folder (`DotfilesConflictUnit`), per file otherwise. A held unit moves in neither direction until chosen (`pendingChoices` in the state file); "Use Synced" saves this Mac's copy under `dotfiles-conflicts/replaced/`. A machine's first pass holds every such unit that differs, so joining a Mac never overwrites either side.
- Each pass starts by resetting and cleaning the clone (`reset --hard HEAD`, `clean -fd`, commits kept), so a pass killed midway never commits half-written files. Progress (`DotfilesSyncProgress`, a fraction plus a step) feeds the Sync pane's progress bar.
- `DotfilesSecretScanner` holds back any file that looks like it contains a credential; the user is notified once per distinct problem set. Nested git checkouts (skills installed by `git clone`) sync as `<path>.kage-git-repo` markers holding the clone URL.
- Background commits pass `-c commit.gpgsign=false` so a signing setup never prompts every two minutes; network git runs through the login shell with prompts disabled.
