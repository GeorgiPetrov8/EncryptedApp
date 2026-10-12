#!/usr/bin/env bash
# Renames HyperChat -> SecureHyperChat everywhere: folders, targets, schemes,
# module name, code, user-visible strings, server notification titles.
#
# Run from the repo root, after restructure.sh / finish-restructure.sh, on a
# clean working tree:
#   bash rename-to-securehyperchat.sh --dry-run   # shows what would change
#   bash rename-to-securehyperchat.sh
#
# New bundle ID:   com.georgipetrov.securehyperchat
# Extension ID:    com.georgipetrov.securehyperchat.SecureHyperChatScreenShare
#
# Deliberately NOT renamed (changing them would break existing data or
# compatibility, not just a name):
#   - "HyperChat X3DH v1", "HyperChat DHRatchet v1", "HyperChat SafetyNumber v1",
#     "HyperChat Conversation v1"   cryptographic domain-separation strings.
#     Changing them makes new builds incompatible with old sessions, safety
#     numbers and conversation IDs.
#   - Keychain services com.HyperChat.keys / .session / .pendingHandshakes.
#     Changing them hides the stored identity keys and login from the app.
#   - HyperChat.sqlite   the local database file name.
#   - /HyperChat.xcodeproj/ in .gitignore (the old project in the repo root).
set -euo pipefail

DRY=0
[ "${1:-}" = "--dry-run" ] && DRY=1

die() { echo "ERROR: $*" >&2; exit 1; }
run() { if [ "$DRY" -eq 1 ]; then echo "+ $*"; else "$@"; fi; }

# ---------------------------------------------------------------- preflight
[ -d .git ] || die "run this from the repository root"
[ -d ios/HyperChat ] || die "ios/HyperChat not found (run the restructure scripts first, or already renamed?)"
[ ! -e ios/SecureHyperChat ] || die "ios/SecureHyperChat already exists"
git diff --quiet && git diff --cached --quiet || die "working tree has uncommitted changes; commit or stash first"
echo "Branch: $(git rev-parse --abbrev-ref HEAD)"
[ "$DRY" -eq 1 ] && echo "--- DRY RUN ---"

# ------------------------------------------------------------ rewrite rules
PL="$(mktemp)"
trap 'rm -f "$PL"' EXIT
cat > "$PL" <<'PERL'
# Used both to rewrite (default) and, with CHECK=1, to list leftovers.
BEGIN { $check = $ENV{CHECK} ? 1 : 0; }

sub protect {
  my ($s) = @_;
  # Insert a NUL inside the word so the generic rule below skips it.
  $s =~ s/HyperChat (?=(?:DHRatchet|SafetyNumber|X3DH|Conversation) v1)/HyperCha\0t /g;
  $s =~ s/com\.HyperChat(?=\.(?:keys|session|pendingHandshakes)\b)/com.HyperCha\0t/g;
  $s =~ s/HyperChat(?=\.sqlite)/HyperCha\0t/g;
  $s =~ s/^\/HyperChat(?=\.xcodeproj\/)/\/HyperCha\0t/;
  return $s;
}

if ($check) {
  my $l = protect($_);
  print "$ARGV:$.: $_" if $l =~ /(?<!Secure)HyperChat/;
  next;   # no output of the line itself in check mode
}

# Identifiers (idempotent: works whether project.yml still has com.HyperChat.app
# or you already switched to com.georgipetrov.hyperchat).
s/bundleIdPrefix: com\.HyperChat/bundleIdPrefix: com.georgipetrov/;
s/com\.georgipetrov\.hyperchat(?![A-Za-z0-9])/com.georgipetrov.securehyperchat/g;
s/com\.HyperChat\.app/com.georgipetrov.securehyperchat/g;
s/(Logger\(subsystem: ")com\.HyperChat\.ScreenShare"/${1}com.georgipetrov.securehyperchat.screenshare"/g;
s/(Logger\(subsystem: ")com\.HyperChat"/${1}com.georgipetrov.securehyperchat"/g;

# Everything else: HyperChat -> SecureHyperChat, except protected strings.
$_ = protect($_);
s/(?<!Secure)HyperChat/SecureHyperChat/g;
s/\0//g;
PERL

# Text files that mention the old name (NUL-separated, safe for any path).
FILES_LIST="$(mktemp)"
trap 'rm -f "$PL" "$FILES_LIST"' EXIT
git ls-files -z ios server .gitignore \
  | xargs -0 grep -I -l --null -e 'HyperChat' -e 'com\.georgipetrov\.hyperchat' 2>/dev/null > "$FILES_LIST" || true

COUNT="$(tr -cd '\0' < "$FILES_LIST" | wc -c | tr -d ' ')"
echo "Files with the old name: $COUNT"

if [ "$DRY" -eq 1 ]; then
  tr '\0' '\n' < "$FILES_LIST" | sed 's/^/+ rewrite /'
elif [ "$COUNT" -gt 0 ]; then
  xargs -0 perl -pi "$PL" < "$FILES_LIST"
fi

# The apns.js comment uses a lowercase example bundle id (tests keep theirs).
if [ "$DRY" -eq 0 ] && [ -f server/src/apns.js ]; then
  perl -pi -e 's/com\.hyperchat\.app/com.georgipetrov.securehyperchat/g' server/src/apns.js
fi

# ------------------------------------------------------------------ renames
run git mv ios/HyperChat ios/SecureHyperChat
run git mv ios/HyperChatScreenShare ios/SecureHyperChatScreenShare
run git mv ios/Tests/HyperChatTests ios/Tests/SecureHyperChatTests
if [ "$DRY" -eq 1 ]; then
  echo "+ git mv ios/SecureHyperChat/App/HyperChatApp.swift ios/SecureHyperChat/App/SecureHyperChatApp.swift"
  echo "+ git mv ios/SecureHyperChat/Resources/HyperChat.entitlements ios/SecureHyperChat/Resources/SecureHyperChat.entitlements"
else
  git mv ios/SecureHyperChat/App/HyperChatApp.swift ios/SecureHyperChat/App/SecureHyperChatApp.swift
  git mv ios/SecureHyperChat/Resources/HyperChat.entitlements ios/SecureHyperChat/Resources/SecureHyperChat.entitlements
  git add -A ios server .gitignore
fi

# ------------------------------------------------------------------- verify
if [ "$DRY" -eq 0 ]; then
  echo
  echo "Remaining 'HyperChat' strings (should be only the protected ones):"
  git ls-files -z ios server .gitignore \
    | xargs -0 grep -I -l --null 'HyperChat' 2>/dev/null \
    | xargs -0 env CHECK=1 perl -n "$PL" || true
  echo "(end of list)"
  grep -q 'name: SecureHyperChat' ios/project.yml || die "ios/project.yml was not updated"
  [ -f ios/SecureHyperChat/App/SecureHyperChatApp.swift ] || die "SecureHyperChatApp.swift missing"
  echo "OK: renamed."
fi

cat <<'EOF'

Next steps:
  1. Delete the old generated project and regenerate:
       rm -rf ios/HyperChat.xcodeproj
       cd ios && xcodegen generate && open SecureHyperChat.xcodeproj
  2. In Xcode: Product -> Clean Build Folder. Delete the old app from the
     phone/simulator (new bundle ID = a different app).
  3. server/.env (or env.env): set APNS_TOPIC=com.georgipetrov.securehyperchat
  4. Keep DEVELOPMENT_TEAM in ios/project.yml (it is not touched).
  5. git commit -m "Rename HyperChat to SecureHyperChat"
EOF
