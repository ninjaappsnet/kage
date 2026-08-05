---
name: pull-upstream
description: Sync this fork from upstream supabitapp/supacode — fetch, merge, resolve conflicts under the fork's rules, re-apply the Kage rebrand, and verify. Use when the user wants to pull, sync, or merge from upstream, or asks to catch up with supacode.
---

# Pull from upstream

This repo is a fork of `supabitapp/supacode` published as Kage. Syncing is a
routine that has a specific order and two fork-specific rules that a normal
merge does not know about. Follow the phases below in order.

Read `docs/kage-fork-operations.md` and the "Minimizing Upstream Merge Conflicts"
section of `AGENTS.md` before resolving anything non-obvious.

## Phase 1 — preflight

1. Confirm the working tree is clean (`git status --short`). If it is not, stop
   and ask the user whether to stash or commit first. Never stash silently.
2. Confirm the current branch. A sync belongs on `main`; if the user is on a
   feature branch, ask before proceeding.
3. `git fetch upstream`

Report what is incoming before touching anything:

```sh
git log --oneline HEAD..upstream/main | cat
git diff --stat HEAD...upstream/main -- . ':!ThirdParty' | tail -20
```

If there is nothing incoming, say so and stop — do not create an empty merge.

## Phase 2 — merge

```sh
git merge upstream/main
```

The fork merges rather than rebases; the history is full of
`Merge remote-tracking branch 'upstream/main'` commits. Keep it that way.

If the merge is clean, go to Phase 3.

### Resolving conflicts

Classify every conflict before resolving it. There are three kinds and they have
different answers:

**1. Rebrand conflicts** — upstream edited a line whose only local change is
`Supacode` → `Kage` in user-facing copy. **Take upstream's side wholesale**, then
let Phase 3 re-apply the rename. Do not hand-merge these; that is the entire
point of the sweep script.

**2. Fork feature integration** — upstream edited a line this fork also changed
to wire in a fork feature (the file explorer, workspaces, telemetry removal).
Merge both intents by hand. `AGENTS.md` describes how these edits were kept thin
and appended precisely so this stays reviewable.

**3. `Tuist/Package.resolved`** — never hand-merge. Take upstream's and
regenerate with `tuist install`.

For anything genuinely ambiguous, invoke the `resolving-merge-conflicts` skill
rather than guessing. If a conflict implies upstream restructured something this
fork depends on, stop and tell the user what changed before resolving.

## Phase 3 — re-apply the rebrand

```sh
make rebrand-fix
```

This rewrites user-facing `Supacode` mentions to `Kage`. It is idempotent, and it
also catches copy upstream **added** — which no conflict ever surfaces, because a
new line conflicts with nothing. Run it on every sync, including a clean merge.

Review its diff. If it renamed something that is not user-facing prose — a
bundled resource name, a persisted raw value, an on-disk template — add that to
`GUARDED_LITERALS` or `EXCLUDED_FILES` at the top of
`scripts/rebrand-strings.sh` **in this same commit**, then re-run. Those two
lists are the only check on the sweep's correctness.

## Phase 4 — verify

In this order, because each is cheaper than the next:

```sh
make check       # swift-format + swiftlint
make build-app
make test
```

`supacodeTests/` is deliberately not swept — most of its `Supacode` mentions are
fixtures the rename would corrupt (fake `/Applications/Supacode.app` paths,
`Supacode.xcodeproj` filenames, a `NotSupacode` negative case, an assertion on an
excluded template). So a handful of assertions that mirror renamed product copy
will fail after a sweep. **That is the intended signal**: update the assertion to
the new copy, do not revert the product string.

Read the actual test log before declaring the suite green. A wrapper's exit code
has been wrong here before; `make: *** [test] Error 65` in the log is the truth.

## Phase 5 — commit

Commit the merge and the rebrand separately when the merge had conflicts, so the
rebrand stays reviewable on its own. Commit only files this sync touched; never
`git add .`.

Do not bump a version and do not push unless the user asks. Pushing to `main`
triggers a nightly `tip` build if any app code changed.

Report at the end: how many upstream commits landed, which conflicts were
resolved and how they were classified, how many lines the rebrand rewrote, and
the result of each verification step.
