#!/bin/zsh
# Builds Backup Monitor.app with the Command Line Tools (no Xcode needed). Runs the tests first.
#   ./build.sh           build into build/
#   ./build.sh install   build, copy to /Applications and open it
#   ./build.sh dmg       build, then build/BackupMonitor.dmg (app + Applications shortcut) for a GitHub release
set -euo pipefail
cd "${0:A:h}"

mkdir -p build
swiftc -O Sources/Core.swift tests/main.swift -o build/tests
./build/tests

APP="build/Backup Monitor.app"
/bin/rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
# Universal: one binary for Apple Silicon and Intel Macs.
for arch in arm64 x86_64; do
  swiftc -O -parse-as-library -target $arch-apple-macos13.0 Sources/*.swift -o build/BackupMonitor-$arch
done
lipo -create build/BackupMonitor-arm64 build/BackupMonitor-x86_64 -output "$APP/Contents/MacOS/BackupMonitor"
cp Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns Resources/OzColor-*.png LICENSE "$APP/Contents/Resources/"
# Signing identity: SIGN_ID if set, else a Developer ID Application certificate (needed for other
# Macs, with notarization), else an Apple Development one, else ad hoc.
SIGN_ID="${SIGN_ID:-$(security find-identity -v -p codesigning | grep -m1 -o '"Developer ID Application: [^"]*"' | tr -d '"' || true)}"
SIGN_ID="${SIGN_ID:-$(security find-identity -v -p codesigning | grep -m1 -o '"Apple Development: [^"]*"' | tr -d '"' || true)}"
case "$SIGN_ID" in
  "Developer ID Application:"*) codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$APP" ;;
  "")                           codesign --force --sign - "$APP" ;;
  *)                            codesign --force --options runtime --sign "$SIGN_ID" "$APP" ;;
esac
echo "Built $APP, signed: ${SIGN_ID:-ad hoc}"

if [ "${1:-}" = "install" ]; then
  /usr/bin/osascript -e 'tell application id "fr.oz-color.backupmonitor" to quit' 2>/dev/null || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -x BackupMonitor >/dev/null || break; sleep 0.5; done
  /bin/rm -rf "/Applications/Backup Monitor.app"
  /usr/bin/ditto "$APP" "/Applications/Backup Monitor.app"
  open "/Applications/Backup Monitor.app"
  echo "Installed in /Applications"
fi

if [ "${1:-}" = "dmg" ]; then
  /bin/rm -rf build/dmg build/BackupMonitor.dmg
  mkdir build/dmg
  /usr/bin/ditto "$APP" "build/dmg/Backup Monitor.app"
  ln -s /Applications build/dmg/Applications
  hdiutil create -quiet -volname "Backup Monitor" -srcfolder build/dmg -fs HFS+ -format UDZO build/BackupMonitor.dmg
  /bin/rm -rf build/dmg
  # Notarized when signed with Developer ID and the notarytool login is saved under NOTARY_PROFILE
  # (once: xcrun notarytool store-credentials oz-color-notary --apple-id ... --team-id ...).
  NOTARY_PROFILE="${NOTARY_PROFILE:-oz-color-notary}"
  case "$SIGN_ID" in
    "Developer ID Application:"*)
      if xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
        codesign --force --timestamp --sign "$SIGN_ID" build/BackupMonitor.dmg
        xcrun notarytool submit build/BackupMonitor.dmg --keychain-profile "$NOTARY_PROFILE" --wait
        xcrun stapler staple build/BackupMonitor.dmg
        spctl -a -t open --context context:primary-signature -v build/BackupMonitor.dmg
      else
        echo "Not notarized: no notarytool login saved as \"$NOTARY_PROFILE\"."
      fi ;;
    *) echo "Not notarized: needs a Developer ID Application certificate." ;;
  esac
  echo "Built build/BackupMonitor.dmg (v$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Info.plist))"
fi
