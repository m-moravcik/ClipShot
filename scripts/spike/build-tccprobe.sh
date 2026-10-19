#!/bin/zsh
# build-tccprobe.sh <dest-dir> - builds an ad-hoc signed TCCProbe.app (bundle id
# sk.moravcik.clipshot.tccprobe) with a Desktop usage string. Throwaway; trash it afterwards and
# run `tccutil reset SystemPolicyDesktopFolder sk.moravcik.clipshot.tccprobe`.
set -e
dest=$1; app=$dest/TCCProbe.app
mkdir -p $app/Contents/MacOS
swiftc -O ${0:a:h}/tccprobe.swift -o $app/Contents/MacOS/tccprobe
cat > $app/Contents/Info.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>sk.moravcik.clipshot.tccprobe</string>
<key>CFBundleName</key><string>TCCProbe</string>
<key>CFBundleExecutable</key><string>tccprobe</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/>
<key>NSDesktopFolderUsageDescription</key><string>Spike: checks how Desktop access behaves.</string>
</dict></plist>
PLIST
codesign --force -s - $app
codesign -dv $app 2>&1 | grep -E 'Signature|Identifier'
