#!/bin/bash
# Builds ShottyMacShotFace.app into ./build. Needs only the Command Line Tools
# (xcode-select --install), not full Xcode.
#
#   ./build.sh            release build + app bundle
#   ./build.sh test       run the unit tests
#   ./build.sh selftest   build, then render the editor/overlay/effects to build/selftest/*.png
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="ShottyMacShotFace"
APP="build/$APP_NAME.app"
# swift-testing's macro plugin ships with the Command Line Tools but isn't found automatically
# outside Xcode, so point the compiler at it.
TESTING_PLUGINS="$(xcode-select -p)/usr/lib/swift/host/plugins/testing"

if [ "${1:-}" = "test" ]; then
  if [ -d "$TESTING_PLUGINS" ]; then
    exec swift test -Xswiftc -plugin-path -Xswiftc "$TESTING_PLUGINS"
  fi
  exec swift test
fi

echo "▸ Compiling (release)…"
swift build -c release
BIN="$(swift build -c release --show-bin-path)/$APP_NAME"

echo "▸ Assembling $APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# Ad-hoc signature (the default) so macOS will run it. An ad-hoc signature changes on every build,
# and macOS ties the Screen Recording permission to the signature, so you'll be asked again after
# each rebuild. Set SIGN_IDENTITY to a code-signing certificate's name to keep the permission.
codesign --force --sign "${SIGN_IDENTITY:--}" --identifier com.darkl0ud.shottymacshotface "$APP"

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
echo "✓ Built $APP (version $VERSION)"

if [ "${1:-}" = "selftest" ]; then
  OUT="$PWD/build/selftest"
  mkdir -p "$OUT"
  echo "▸ Self-test → $OUT"
  "$APP/Contents/MacOS/$APP_NAME" --selftest "$OUT" ${SELFTEST_ARGS:-}
  exit $?
fi

echo "  Install:  cp -R $APP /Applications/ && open /Applications/$APP_NAME.app"
