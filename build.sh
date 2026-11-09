#!/bin/zsh
# Builds Silverstack Island.app next to this script. Only needs the Command Line Tools.
set -e
cd "${0:A:h}"

mkdir -p .build
swiftc -O Sources/Core.swift tests/main.swift -o .build/tests
.build/tests

app="Silverstack Island.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp Resources/AppIcon.icns "$app/Contents/Resources/"
# Universal: one binary for Apple Silicon and Intel Macs.
for arch in arm64 x86_64; do
    swiftc -O -parse-as-library -target $arch-apple-macos13.0 \
        Sources/Core.swift Sources/Database.swift Sources/Log.swift Sources/App.swift \
        -o .build/SilverstackIsland-$arch
done
lipo -create .build/SilverstackIsland-arm64 .build/SilverstackIsland-x86_64 -output "$app/Contents/MacOS/SilverstackIsland"

cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Silverstack Island</string>
    <key>CFBundleIdentifier</key><string>local.dit.silverstackisland</string>
    <key>CFBundleExecutable</key><string>SilverstackIsland</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$app"
echo "Built $app"
