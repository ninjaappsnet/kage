# Kage fork operations

Everything in this file is specific to the `ninjaappsnet/kage` fork and does not
apply to upstream `supabitapp/supacode`. It lives in its own file so an upstream
sync never conflicts with it.

## Release cadence — what warrants what

A nightly should mean the **app** changed, not the machinery around it.

**No build at all.** `main.yml`'s `paths-ignore` covers `.github/**`,
`.claude/**`, `**/*.md`, `docs/**` and a few dotfiles. Pushes touching only those
produce nothing. On this fork every run is a full Release archive plus two
notarization round-trips on a single self-hosted Mac, serialized behind one
concurrency group — so a skipped run is real time saved.

The trade-off: a change to the pipeline is **not** exercised by merging it.
Validate those with `workflow_dispatch` on the `main` workflow.

Deliberately *not* ignored, because they change what gets built or tested:
`scripts/**` (feeds the ghostty build), `.swiftlint.yml`, `.swift-format.json`.

**Nightly (`tip` prerelease).** Automatic on any push to `main` touching app
code — `supacode/`, `Features/`, `Resources/`, `Project.swift`, `Info.plist`,
package dependencies. Never a deliberate act; just merge.

**Versioned release.** Only via `make bump-and-release VERSION=x.y.z`, and only
when a user-facing change is complete and the maintainer asks for it. Never bump
a version unprompted.

The `detect` job publishes a stable release only when `v$MARKETING_VERSION` tags
the exact pushed SHA — which is why the bump commit and its signed tag must
travel together via `--follow-tags`. It also requires the release to have zero
assets, making re-runs idempotent. Patch bumps need nothing extra; minor and
major require a `## title` + blank line + body headline that rides the tag into
both the release notes and the Sparkle appcast.

## Syncing from upstream

Run the `/pull-upstream` skill (`.claude/skills/pull-upstream/`). It fetches,
merges, re-applies the rebrand, and runs the checks in the order that matters.
The rest of this section is what the skill automates, for when you do it by hand.

Upstream writes its own name into user-facing copy — alert bodies, settings
descriptions, error messages, onboarding cards. This fork renames those to Kage,
which means every upstream edit to one of those lines conflicts on sync. That is
accepted, and it is cheap, because resolving is mechanical:

```sh
make rebrand-check   # report anything still saying Supacode; exits 1 if so
make rebrand-fix     # rewrite it
```

Take **upstream's** side on any such conflict, then re-run `make rebrand-fix`.
The script is idempotent, so running it on a clean tree is a no-op, and it also
catches copy upstream *added* since the last sync — which a conflict never
surfaces, because a new line does not conflict with anything.

This supersedes the original `scripts/rebrand.sh`, which swept a hand-maintained
list of files. A list cannot catch copy upstream *adds* to a file nobody thought
to list, and it had in fact drifted: 40 user-facing strings across 22 files were
never on it. Discovery is now automatic and the judgment lives in two small
exception lists instead.

`scripts/rebrand-strings.sh` renames the standalone word `Supacode` only inside
string literals — double-quoted runs on a line, plus `"""` blocks, whose state it
tracks across lines. Comments and identifiers (`SupacodePaths`,
`SupacodeSettingsShared`, the `supacode` CLI name, `supacode://`, `~/.supacode`
paths) are therefore structurally out of reach rather than blocklisted.

The `"""` handling is not incidental: onboarding-card copy lives in `"""` blocks,
so a line-local rule silently misses the most visible strings in the app. It did,
for three cards, until a screenshot caught it.

Two lists at the top of the script carry what that rule cannot infer:

- `GUARDED_LITERALS` — strings that carry the old name as an identifier rather
  than as prose. Currently the `Supacode Light` / `Supacode Dark` theme
  filenames, which are looked up in the bundle by name.
- `EXCLUDED_GLOBS` — the `*Content.swift` agent-integration templates. Their
  installers decide "is this file still managed by us" by comparing the file on
  disk against the template byte for byte, so editing even a comment inside one
  marks every already-installed user as outdated. Matched as a glob, because
  upstream adds an agent template every few releases and an enumerated list goes
  stale silently.

If upstream adds a resource name, persisted raw value, or on-disk template that
contains `Supacode`, add it to the right list in the same commit — and prefer a
pattern over a name. Review the `rebrand-fix` diff before committing; it is the
only check on those lists being complete.

`supacodeTests/` is deliberately **not** swept. Most of its `Supacode` mentions
are fixtures the rename would corrupt — fake `/Applications/Supacode.app` paths,
`Supacode.xcodeproj` filenames, a `NotSupacode` negative case, and an assertion
on the contents of one of the excluded templates. The handful of assertions that
mirror renamed product copy therefore fail after a sweep, which is the intended
signal: run `make test` after `make rebrand-fix` and update whatever it names.

## Signing the bump commit

`scripts/bump-version.sh` uses `git commit -S` and `git tag -s`. Git builds the
signer spec as `"Name <email>"` and hands it to gpg verbatim. If the gpg uid and
git's `user.name` differ by even one character — an accented letter, say — gpg
answers `No secret key` and the bump dies with the config already rewritten
(`git checkout -- Configurations/Project.xcconfig` to recover).

Pin the key by id so the name never matters:

```sh
git config user.signingkey <KEYID>     # or --global
```

## CI runs on self-hosted runners

The macOS jobs run on org-level self-hosted runners named `mini-1`, `mini-2`,
`mini-3`. All three are separate runner instances on a **single Mac**, under one
account. The Ubuntu jobs stay GitHub-hosted.

Consequences that are not obvious from the workflow files:

- **They share `~/.local/share/mise`.** Two jobs installing tools at once left a
  half-written binary and `mise-action` died with `spawn Unknown system error
  -88` (`EBADMACHO`). Every macOS job across both workflows is therefore in one
  `macos-runner` concurrency group. `publish-stable` is deliberately excluded: it
  never runs `setup-macos`, and a job *pending* in a group gets cancelled when a
  newer one joins — which must never be able to happen to a release publish.
- **`cancel-in-progress` must stay `false`** on that group, so a PR build can
  never cancel a release build that already holds it.
- **The runner group must allow public repositories.** kage is public; without
  that checkbox, jobs queue forever while the runners still display as Idle.
- **The runner host needs Xcode 26.3** installed alongside whatever is newer,
  because the pinned Zig 0.15.2 cannot link the macOS 26.4+ SDK. `xcodes install
  26.3` works. Verify the whole prerequisite set there with `make doctor`.

Because the repo is public and PR CI is self-hosted, untrusted code from a pull
request executes on that machine. Keep "Require approval for all outside
collaborators" enabled.

## Signing and notarization secrets

`main.yml` needs these Actions secrets on the repo:

| Secret | Notes |
| --- | --- |
| `DEVELOPER_ID_CERT_P12` | base64 of a `.p12` exported from the login keychain |
| `DEVELOPER_ID_CERT_PASSWORD` | the export password |
| `DEVELOPER_ID_IDENTITY` | full name, `Developer ID Application: … (TEAMID)` |
| `KEYCHAIN_PASSWORD` | any random value; scopes the throwaway build keychain |
| `APPLE_TEAM_ID` | |
| `APPLE_NOTARIZATION_ISSUER` | UUID from App Store Connect → **Team Keys** |
| `APPLE_NOTARIZATION_KEY_ID` | matches the `AuthKey_<KEYID>.p8` filename |
| `APPLE_NOTARIZATION_KEY` | the `.p8` contents |
| `SPARKLE_PRIVATE_KEY` | ed25519 key matching `SUPublicEDKey` in `Info.plist` |
| `GH_RELEASE_TOKEN` | optional; `main.yml` falls back to `github.token` |

Validate notarization credentials in seconds before trusting a 25-minute
pipeline to them:

```sh
xcrun notarytool history --key AuthKey_XXXXXXXXXX.p8 --key-id XXXXXXXXXX --issuer <uuid>
```

"No submission history" means they are good. An Individual API key has no issuer
and cannot be used here — it must be a Team key.

## Sparkle key rotation

`SUPublicEDKey` in `supacode/Info.plist` must match the private key in
`SPARKLE_PRIVATE_KEY`. Rotating it means every already-installed build rejects
the new appcast with *"The update is improperly signed"* and needs a one-time
manual reinstall. Verify a published appcast without shipping anything, since
ed25519 signatures are deterministic — re-signing the same zip must reproduce
the `edSignature` in `appcast.xml`:

```sh
Tuist/.build/artifacts/sparkle/Sparkle/bin/sign_update Kage.app.zip
```

## Notarize the app before it goes into the DMG

`.github/scripts/notarize.sh` handles both targets. The app is notarized and
stapled first, then the DMG is built from the stapled bundle, then the image
itself is notarized and stapled. Stapling the app *after* `create-dmg` leaves the
copy inside the image ticketless, so a user who drags it to `/Applications` gets
an app Gatekeeper can only validate over the network — which fails offline.

Verify a published DMG the way a user receives it:

```sh
gh release download <tag> --pattern '*.dmg'
xcrun stapler validate Kage.dmg
spctl -a -t open --context context:primary-signature -v Kage.dmg   # want: accepted
hdiutil attach -nobrowse -readonly Kage.dmg
xcrun stapler validate /Volumes/Kage/Kage.app                      # must also pass
```

## Tuist has no project linked to this fork

`Tuist.swift`'s `fullHandle` points at upstream's project, so `tuist auth login`
fails here. That is tolerated — `optionalAuthentication` lets generation and
building work unauthenticated, and the login step reports and continues.

Upstream's `warm` job is removed on this fork for the same reason: binary-cache
warming only pays off when a separate job can read what it produced, which needs
a remote cache, which needs a linked project. Restore the job alongside a real
`fullHandle` if this repo ever gets one.
