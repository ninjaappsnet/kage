#!/usr/bin/env bash
# Re-applies the Supacode -> Kage display rebrand.
#
# Why this exists: this repo is a fork that syncs from upstream supabitapp/supacode.
# After an upstream merge, accept upstream's side on any conflict in these files, then
# re-run this script to re-apply the brand. It is idempotent and safe to run repeatedly.
#
# Scope (deliberately narrow — see AGENTS.md "Kage rename"):
#   * Only the standalone display WORD "Supacode" is replaced (and "Supacode.app" paths).
#     The pattern `Supacode(?![A-Za-z0-9])` preserves every camelCase identifier
#     (SupacodePaths, SupacodeLock*, SupacodeSettings*, SupacodeCLI, SupacodeAppDelegate, ...).
#   * Lowercase functional identity is intentionally KEPT as "supacode":
#     URL scheme supacode://, the `supacode` CLI command, SUPACODE_* env vars,
#     /tmp/supacode-* sockets, ~/.ssh/supacode-%C, "# supacode-managed-*" hook markers.
#   * Bundle ids / Info.plist / Project.swift / Makefile identity are hand-maintained,
#     NOT swept here.
#
# To extend after a sync that adds new user-facing strings: add the file to FILES below.
set -euo pipefail

cd "$(dirname "$0")/.."

FILES=(
  # App shell + windows/menus
  supacode/App/WindowTitle.swift
  supacode/App/supacodeApp.swift
  supacode/App/ContentView.swift
  supacode/App/DeeplinkReferenceView.swift
  supacode/App/CLIReferenceView.swift
  # Reducers with user-facing alert/dialog copy
  supacode/Features/App/Reducer/AppFeature.swift
  supacode/Features/Repositories/Reducer/RepositoriesFeature.swift
  supacode/Features/Repositories/Reducer/RepositoriesFeature+Removal.swift
  # Views with tooltips / help text
  supacode/Features/Repositories/Views/FailedRepositoryRow.swift
  supacode/Features/Repositories/Views/RemoteConnectionFormView.swift
  supacode/Features/Repositories/Views/SidebarListView.swift
  supacode/Features/Repositories/Views/WorktreeDetailView.swift
  # Settings UI
  SupacodeSettingsFeature/Views/AppearanceSettingsView.swift
  SupacodeSettingsFeature/Reducer/SettingsFeature.swift
  SupacodeSettingsShared/BusinessLogic/CLIInstaller.swift
  SupacodeSettingsShared/BusinessLogic/CLISkillContent.swift
  # CLI help text + user-facing errors (command name `supacode` stays lowercase)
  supacode-cli/SupacodeCLI.swift
  supacode-cli/Commands/OpenCommand.swift
  supacode-cli/Commands/SettingsCommand.swift
  supacode-cli/Commands/SocketCommand.swift
  supacode-cli/Helpers/IDResolvers.swift
  supacode-cli/Transport/SocketClient.swift
  supacode-cli/Transport/Dispatcher.swift
  supacode-cli/Transport/QueryDispatcher.swift
  # Tests that assert on user-facing display copy (window title, alerts, dialogs).
  # NOTE: other test files intentionally keep "Supacode" — git-lock markers,
  # TERM_PROGRAM, hook ownership sentinels, and self-consistent app-path fixtures
  # (e.g. ZmxClientTests / RemoteSSHCommandTests echo their input path) are functional.
  supacodeTests/WindowTitleTests.swift
  supacodeTests/RepositoriesFeatureTests.swift
  supacodeTests/AppFeatureDeeplinkTests.swift
  supacodeTests/AppFeatureSystemNotificationTests.swift
)

changed=0
for f in "${FILES[@]}"; do
  if [[ ! -f "$f" ]]; then
    echo "WARN: missing (renamed upstream?): $f" >&2
    continue
  fi
  before="$(shasum "$f")"
  perl -CSD -i -pe 's/Supacode(?![A-Za-z0-9])/Kage/g' "$f"
  after="$(shasum "$f")"
  [[ "$before" != "$after" ]] && { echo "rebranded: $f"; changed=$((changed + 1)); }
done
echo "rebrand.sh: updated $changed file(s)"
