#!/usr/bin/env bash
# Restructures the EncryptedApp repo (branch Fixes) into ios/ + server/.
#
# Usage (from the repo root, on a clean working tree):
#   ./restructure.sh --dry-run    # prints every command, changes nothing
#   ./restructure.sh              # does it
#
# Everything is done with `git mv` / `git rm --cached`, so history follows the
# files. No Swift code is edited, except one comment path in
# PhotoAttachmentLoader.swift. Put the new project.yml next to this script and
# it is installed as ios/project.yml.
set -euo pipefail

DRY=0
[ "${1:-}" = "--dry-run" ] && DRY=1

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="HyperChat/Sources/HyperChat"
APP="ios/HyperChat"

run() {
  if [ "$DRY" -eq 1 ]; then echo "+ $*"; else "$@"; fi
}
die() { echo "ERROR: $*" >&2; exit 1; }

# mv_swift <dest-dir> <Name> [Name...]
# Finds <Name>.swift anywhere under the old source tree (names are unique) and
# git-mv's it into <dest-dir>.
mv_swift() {
  local dest="$1"; shift
  run mkdir -p "$dest"
  local name found count
  for name in "$@"; do
    found="$(find "$SRC" -name "$name.swift" -type f)"
    count="$(printf '%s\n' "$found" | grep -c . || true)"
    [ "$count" -eq 1 ] || die "expected exactly one $name.swift under $SRC, found $count"
    run git mv "$found" "$dest/$name.swift"
  done
}

# ---------------------------------------------------------------- preflight
[ -d .git ] || die "run this from the repository root"
[ -d "$SRC" ] || die "$SRC not found (already restructured?)"
[ ! -e ios ] || die "ios/ already exists"
[ ! -e server ] || die "server/ already exists"
git diff --quiet && git diff --cached --quiet || die "working tree has uncommitted changes; commit or stash first"
echo "Branch: $(git rev-parse --abbrev-ref HEAD)"
[ "$DRY" -eq 1 ] && echo "--- DRY RUN ---"

BEFORE="$(git ls-files HyperChat HyperChatTests | grep -c '\.swift$' || true)"

# ------------------------------------------------------------------ app/ios
mv_swift "$APP/App" HyperChatApp AppDelegate AppContainer RootView

# Core: shared infrastructure
mv_swift "$APP/Core/Networking" APIClientProtocol RealAPIClient WebSocketServiceProtocol \
  RealWebSocketService SessionTokenStore NetworkConfiguration
mv_swift "$APP/Core/Persistence" DatabaseManager SyncCursorStore MediaCompositeKeyMigration \
  UserRepository SessionRepository
mv_swift "$APP/Core/Models" User SessionRecord DTOs ControlPayloads
mv_swift "$APP/Core/Crypto" CryptoService X3DH DoubleRatchet AESGCM KeychainStore \
  IdentityKeyPair CurveKeyHelper SafetyNumber
mv_swift "$APP/Core" Extensions

# Mock backend (still compiled into the app; see notes at the end)
mv_swift "$APP/Mock" MockAPIClient MockBackendStore

# Shared UI components
mv_swift "$APP/UI" AvatarView EmojiPickerView ChatBackgroundView AppScreenStyle NavigationSwipeBack

# Features
mv_swift "$APP/Features/Chat/Messaging" MessagingService PendingHandshakeStore ReceiptService PresenceService
mv_swift "$APP/Features/Chat/Models" Message MessageReaction MessagePayloads
mv_swift "$APP/Features/Chat" MessageRepository ChatViewModel ChatView MessageBubbleView MessageStatusView

mv_swift "$APP/Features/Conversations" Conversation ConversationRelationshipState ConversationRepository \
  ConversationListViewModel ConversationListView InvitationsView InvitationService

mv_swift "$APP/Features/Media" MediaItem AttachmentPolicy MediaRepository MediaEncryptionService \
  MediaCacheStore MediaExporter VoiceRecorder DecryptedMediaCache PhotoAttachmentLoader \
  AttachmentMenu MediaViews MediaMessageView VoiceMessageViews GIFPickerView TenorService

mv_swift "$APP/Features/Calls" CallModels CallService CallView ScreenShareButton ScreenShareReceiver

mv_swift "$APP/Features/Auth" AuthService AuthViewModel LoginView RegisterView VerifyIdentityView \
  AppLockService AppLockView

mv_swift "$APP/Features/Account" ProfileService RecoveryService RecoveryAPI BackupArchive \
  AccountDeletionService RestoreAccountView RecoverySettingsView

mv_swift "$APP/Features/Settings" SettingsView AppearanceSettingsView NotificationSettingsView \
  AppearanceStore ChatAppearance

mv_swift "$APP/Features/Notifications" PushService NtfyService

mv_swift "$APP/Features/Alarms" Alarm AlarmRepository AlarmService AlarmScheduler AlarmAudioService \
  AlarmListView AlarmEditView AlarmRingingView

mv_swift "$APP/Features/NotePad" NotePadItem NotePadOperation MentalTask NotePadRepository \
  NotePadService NotePadViewModel NotePadView

# Resources
run mkdir -p "$APP/Resources"
run git mv "$SRC/Info.plist" "$APP/Resources/Info.plist"
run git mv HyperChat/HyperChat.entitlements "$APP/Resources/HyperChat.entitlements"
run git mv HyperChat/Assets.xcassets "$APP/Resources/Assets.xcassets"
run git mv HyperChat/README.md ios/README.md

# Shared (compiled into app and extension) and the screen-share extension
mv_swift "ios/Shared" ScreenShareWire
run mkdir -p ios/HyperChatScreenShare
run git mv HyperChat/Sources/HyperChatScreenShare/Info.plist ios/HyperChatScreenShare/Info.plist
run git mv HyperChat/Sources/HyperChatScreenShare/ScreenShareExtension/SampleHandler.swift \
  ios/HyperChatScreenShare/SampleHandler.swift

# Tests
run mkdir -p ios/Tests
run git mv HyperChatTests ios/Tests/HyperChatTests

# project.yml and generated Xcode project
if [ -f "$SCRIPT_DIR/project.yml" ]; then
  run git rm -q project.yml
  run cp "$SCRIPT_DIR/project.yml" ios/project.yml
  run git add ios/project.yml
else
  echo "NOTE: no project.yml next to this script; moving the old one as-is (paths inside need editing)."
  run git mv project.yml ios/project.yml
fi
run git rm -r -q --cached HyperChat.xcodeproj

# Comment-only path fix
PAL="$(find ios -name PhotoAttachmentLoader.swift -type f 2>/dev/null || true)"
if [ -n "$PAL" ] && [ "$DRY" -eq 0 ]; then
  perl -pi -e 's#HyperChatServer/src/validate\.js#server/src/validate.js#' "$PAL"
fi

# ------------------------------------------------------------------- server
# Stop tracking secrets, the database and node_modules first. The files stay
# on disk; they just stop being part of the repo.
run git rm -r -q --cached HyperChatServer/node_modules HyperChatServer/data \
  HyperChatServer/.env HyperChatServer/env.env
run git mv HyperChatServer server

# .env.example: variable names only, no values.
if [ "$DRY" -eq 0 ]; then
  {
    echo "# Copy to .env and fill in. Never commit real values."
    cat server/.env server/env.env 2>/dev/null \
      | { grep -E '^[A-Za-z_][A-Za-z0-9_]*=' || true; } \
      | sed -E 's/=.*/=/' | awk '!seen[$0]++'
  } > server/.env.example
  mkdir -p server/data && : > server/data/.gitkeep
  git add server/.env.example
  git add -f server/data/.gitkeep
else
  echo "+ write server/.env.example (variable names only) and server/data/.gitkeep"
fi

# .gitignore
if [ "$DRY" -eq 0 ]; then
  cat > .gitignore <<'EOF'
# macOS / Xcode
.DS_Store
xcuserdata/
DerivedData/
build/
*.xcuserstate
ios/HyperChat.xcodeproj/
/HyperChat.xcodeproj/

# Server
server/node_modules/
server/.env
server/env.env
server/data/*
!server/data/.gitkeep
*.sqlite
*.sqlite-shm
*.sqlite-wal

# Keys and certificates
*.p8
*.pem
EOF
  git add .gitignore
else
  echo "+ write .gitignore"
fi

# ------------------------------------------------------------------- verify
if [ "$DRY" -eq 0 ]; then
  find HyperChat -type d -empty -delete 2>/dev/null || true
  LEFT="$({ find HyperChat -name '*.swift' 2>/dev/null || true; } | wc -l | tr -d ' ')"
  AFTER="$(git ls-files ios | grep -c '\.swift$' || true)"
  [ "$LEFT" -eq 0 ] || die "$LEFT .swift files are still under HyperChat/"
  [ "$BEFORE" -eq "$AFTER" ] || die "Swift file count changed: $BEFORE before, $AFTER after"
  echo "OK: $AFTER Swift files moved, none left behind."
fi

cat <<'EOF'

Next steps:
  1. cd ios && xcodegen generate && open HyperChat.xcodeproj
  2. Delete the old HyperChat.xcodeproj in the repo root (it is untracked now).
  3. server/server.js loads './env.env'. Either keep using that file name
     or change it to require('dotenv').config() so it reads .env.
  4. Rotate anything real that was ever in the committed .env/env.env or the
     database; removing the files does not remove them from git history.
  5. git commit -m "Restructure into ios/ and server/"
EOF
