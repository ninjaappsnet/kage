#!/usr/bin/env bash
# Rewrites user-facing "Supacode" mentions to "Kage" in Swift string literals.
#
# Upstream writes its own name into user-facing copy. This fork renames those
# mentions, which means every upstream edit to one of those lines conflicts on
# sync. That is by design and it is cheap: resolve such a conflict by taking
# upstream's side, then re-running this script. It is idempotent, so running it
# on an already-clean tree is a no-op.
#
# Usage:
#   scripts/rebrand-strings.sh            # report what would change; exit 1 if anything would
#   scripts/rebrand-strings.sh --fix      # apply the rewrite
#
# Run it after every upstream merge. See docs/kage-fork-operations.md.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

FROM="Supacode"
TO="Kage"

SEARCH_DIRS=(supacode supacode-cli SupacodeSettingsFeature SupacodeSettingsShared)

# Files whose "Supacode" mentions are NOT user-facing copy and must not move.
#
# The *Content.swift templates are written verbatim into the user's agent
# config, and their installers decide "managed by us" by comparing the file on
# disk against the template byte for byte — so editing a comment inside one
# marks every already-installed user as outdated.
EXCLUDED_FILES=(
  SupacodeSettingsShared/BusinessLogic/OmpExtensionContent.swift
  SupacodeSettingsShared/BusinessLogic/PiExtensionContent.swift
  SupacodeSettingsShared/BusinessLogic/HermesPluginContent.swift
)

# Literal strings that carry the old name as an identifier, not as prose:
# resource filenames, on-disk keys, protocol values. Matched before the rename.
GUARDED_LITERALS=(
  "Supacode Light" # Resources/ theme filename, looked up via Bundle.main.path
  "Supacode Dark"  # same
)

usage() {
  echo "usage: ${0##*/} [--fix]" >&2
  exit 2
}

mode=check
case "${1:-}" in
  "") ;;
  --fix) mode=fix ;;
  -h | --help) usage ;;
  *) usage ;;
esac

# The rename runs per line, only inside double-quoted regions, so comments and
# identifiers (SupacodePaths, SupacodeSettingsShared) are never touched. Perl
# gets the guards via the environment to keep shell quoting out of the pattern.
export REBRAND_FROM="$FROM" REBRAND_TO="$TO"
REBRAND_GUARDS="$(printf '%s\n' "${GUARDED_LITERALS[@]}")"
export REBRAND_GUARDS

rewrite="$(mktemp)"
trap 'rm -f "$rewrite"' EXIT
cat > "$rewrite" <<'PERL'
BEGIN {
  $from   = $ENV{REBRAND_FROM};
  $to     = $ENV{REBRAND_TO};
  @guards = grep { length } split /\n/, ($ENV{REBRAND_GUARDS} // '');
}
# Split the line into quoted / unquoted runs and only rename inside the quoted
# ones. \" and \\ are consumed as units so an escaped quote can't flip the state.
my ($out, $in_quote, $i, $len) = ('', 0, 0, length $_);
my $chunk = '';
while ($i < $len) {
  my $c = substr($_, $i, 1);
  if ($in_quote && $c eq '\\' && $i + 1 < $len) {
    $chunk .= substr($_, $i, 2);
    $i += 2;
    next;
  }
  if ($c eq '"') {
    $out .= $in_quote ? rename_run($chunk) : $chunk;
    $chunk = '';
    $out .= $c;
    $in_quote = !$in_quote;
    $i++;
    next;
  }
  $chunk .= $c;
  $i++;
}
# An unterminated run is a multi-line string's continuation: leave it alone.
$out .= $in_quote ? $chunk : $chunk;
$_ = $out;

sub rename_run {
  my ($s) = @_;
  # Protect the guarded literals, rename the rest, then restore.
  my @saved;
  for my $g (@guards) {
    while ((my $at = index($s, $g)) >= 0) {
      push @saved, $g;
      substr($s, $at, length($g)) = "\0" . $#saved . "\0";
    }
  }
  $s =~ s/(?<![A-Za-z0-9_])\Q$from\E(?![A-Za-z0-9_])/$to/g;
  $s =~ s/\0(\d+)\0/$saved[$1]/g;
  return $s;
}
PERL

files=()
while IFS= read -r f; do
  skip=0
  for excluded in "${EXCLUDED_FILES[@]}"; do
    [ "$f" = "$excluded" ] && skip=1 && break
  done
  [ "$skip" -eq 1 ] || files+=("$f")
done < <(grep -rl "$FROM" --include='*.swift' "${SEARCH_DIRS[@]}" 2>/dev/null | sort)

if [ "${#files[@]}" -eq 0 ]; then
  echo "no $FROM mentions found."
  exit 0
fi

changed=0
total=0
for f in "${files[@]}"; do
  after="$(perl -p "$rewrite" "$f")"
  if [ "$after" = "$(cat "$f")" ]; then
    continue
  fi
  hits="$({ diff <(cat "$f") <(printf '%s\n' "$after") || true; } | grep -c '^> ' || true)"
  changed=$((changed + 1))
  total=$((total + hits))
  if [ "$mode" = fix ]; then
    printf '%s\n' "$after" > "$f"
    echo "rewrote $f ($hits line(s))"
  else
    echo "would rewrite $f:"
    # diff exits 1 on a difference, which pipefail would turn into a fatal error.
    { diff <(cat "$f") <(printf '%s\n' "$after") || true; } | grep -E '^[<>] ' | sed 's/^/    /'
  fi
done

if [ "$changed" -eq 0 ]; then
  echo "clean: every user-facing \"$FROM\" mention is already \"$TO\"."
  exit 0
fi

if [ "$mode" = fix ]; then
  echo
  echo "rewrote $total line(s) across $changed file(s). Review the diff, then build and test."
  exit 0
fi

echo
echo "$total line(s) across $changed file(s) still say \"$FROM\"."
echo "run 'make rebrand-fix' to rewrite them."
exit 1
